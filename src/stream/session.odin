package stream

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../core"
import "../network"
import "../utils"

Pending_Ice :: struct {
	candidate: string,
	mid:       string,
}

Viewer :: struct {
	sock:    net.TCP_Socket,
	peer:    ^network.Peer,
	pending: [dynamic]Pending_Ice,
}

Session :: struct {
	cfg:      utils.Config,
	cap:      core.Capture,
	enc:      core.Encoder,
	enc_hw:   core.Encoder_HW,
	use_gpu:  bool,
	viewers:  [dynamic]^Viewer,
	mu:       sync.RW_Mutex,
	start_mu: sync.Mutex,
	running:  bool,
	started:  time.Tick,
	loop:     ^thread.Thread,
	last_key: time.Tick,
	key_armed: bool,
}

session_start :: proc(s: ^Session, cfg: utils.Config) -> bool {
	sync.lock(&s.start_mu)
	defer sync.unlock(&s.start_mu)

	sync.lock(&s.mu)
	if s.running {
		sync.unlock(&s.mu)
		return true
	}
	leftover := s.loop
	s.loop = nil
	sync.unlock(&s.mu)

	if leftover != nil {
		thread.join(leftover)
		thread.destroy(leftover)
	}

	cap, cerr := core.capture_open(cfg.monitor, cfg.cursor, true)
	if cerr != .None {
		fmt.eprintln("capture_open:", cerr)
		return false
	}

	enc_cfg := cfg
	if enc_cfg.width <= 0 { enc_cfg.width = cap.width }
	if enc_cfg.height <= 0 { enc_cfg.height = cap.height }

	use_gpu := false
	enc_hw: core.Encoder_HW
	enc: core.Encoder
	hw_err: core.Encoder_Error

	if core.capture_uses_gpu(&cap) && core.capture_d3d11_nvenc_ok(&cap) {
		if dev, imm, ok := core.capture_d3d11(&cap); ok {
			gpu_cfg := enc_cfg
			// Zero-copy requires encoder pool size to match the GPU capture texture.
			if gpu_cfg.width != cap.width || gpu_cfg.height != cap.height {
				fmt.printf("D3D11 encode at native %dx%d (config %dx%d needs GPU scale; not implemented yet)\n",
					cap.width, cap.height, enc_cfg.width, enc_cfg.height)
				gpu_cfg.width = cap.width
				gpu_cfg.height = cap.height
			}
			// Must use `=`: `:=` would shadow enc_hw and leave s.enc_hw zeroed (nil ctx).
			enc_hw, hw_err = core.encoder_open_d3d11(gpu_cfg, dev, imm)
			if hw_err == .None {
				use_gpu = true
				enc = enc_hw.base
				enc_cfg.width = int(enc.width)
				enc_cfg.height = int(enc.height)
			} else {
				fmt.eprintln("encoder_open_d3d11:", hw_err, "(falling back to CPU capture+encode)")
				core.capture_close(&cap)
				cap, cerr = core.capture_open(cfg.monitor, cfg.cursor, false)
				if cerr != .None {
					fmt.eprintln("capture_open (CPU fallback):", cerr)
					return false
				}
			}
		}
	} else if core.capture_uses_gpu(&cap) {
		vendor := core.capture_adapter_vendor(&cap)
		switch vendor {
		case core.GPU_VENDOR_INTEL:
			fmt.println("D3D11 zero-copy NVENC skipped (monitor on Intel GPU; using CPU capture + NVENC on NVIDIA)")
		case core.GPU_VENDOR_AMD:
			fmt.println("D3D11 zero-copy NVENC skipped (monitor on AMD GPU; using CPU capture + NVENC on NVIDIA)")
		case:
			fmt.printf("D3D11 zero-copy NVENC skipped (capture adapter vendor 0x%04x; using CPU capture+encode)\n", vendor)
		}
		core.capture_close(&cap)
		cap, cerr = core.capture_open(cfg.monitor, cfg.cursor, false)
		if cerr != .None {
			fmt.eprintln("capture_open (CPU fallback):", cerr)
			return false
		}
	}
	if !use_gpu {
		enc, hw_err = core.encoder_open(enc_cfg)
		if hw_err != .None {
			fmt.eprintln("encoder_open:", hw_err)
			core.capture_close(&cap)
			return false
		}
	}

	sync.lock(&s.mu)
	s.cfg = enc_cfg
	s.cap = cap
	s.enc = enc
	s.enc_hw = enc_hw
	s.use_gpu = use_gpu
	s.running = true
	s.started = time.tick_now()
	s.key_armed = false
	s.loop = thread.create_and_start_with_poly_data(s, session_loop)
	sync.unlock(&s.mu)
	if use_gpu {
		fmt.printf("capture+encode started (capture %dx%d, encode %dx%d %s, D3D11 zero-copy) plid=%s\n",
			cap.width, cap.height, enc.width, enc.height, enc.name, enc.profile_level_id)
	} else if enc.width != i32(cap.width) || enc.height != i32(cap.height) {
		fmt.printf("capture+encode started (capture %dx%d, encode %dx%d %s) plid=%s\n",
			cap.width, cap.height, enc.width, enc.height, enc.name, enc.profile_level_id)
	} else {
		fmt.printf("capture+encode started (%dx%d %s) plid=%s\n",
			cap.width, cap.height, enc.name, enc.profile_level_id)
	}
	return true
}

session_stop :: proc(s: ^Session) {
	sync.lock(&s.start_mu)
	defer sync.unlock(&s.start_mu)

	sync.lock(&s.mu)
	s.running = false
	leftover := s.loop
	s.loop = nil
	extras := s.viewers
	s.viewers = {}
	sync.unlock(&s.mu)

	for v in extras {
		viewer_destroy(v)
	}
	delete(extras)

	if leftover != nil {
		thread.join(leftover)
		thread.destroy(leftover)
	}
}

session_h264_profile :: proc(s: ^Session) -> string {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	w := s.enc.width
	h := s.enc.height
	hdr := s.enc.headers
	fps := i32(s.cfg.fps)
	if s.use_gpu {
		w = s.enc_hw.base.width
		h = s.enc_hw.base.height
		hdr = s.enc_hw.base.headers
	}
	if fps <= 0 {
		fps = 30
	}
	plid := core.h264_profile_level_id(w, h, fps)
	return core.h264_webrtc_profile(hdr, plid)
}

session_viewer_count :: proc(s: ^Session) -> int {
	sync.shared_lock(&s.mu)
	n := len(s.viewers)
	sync.shared_unlock(&s.mu)
	return n
}

session_has_viewer :: proc(s: ^Session, sock: net.TCP_Socket) -> bool {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	return viewer_index(s, sock) >= 0
}

session_peer_for :: proc(s: ^Session, sock: net.TCP_Socket) -> ^network.Peer {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	i := viewer_index(s, sock)
	if i < 0 {
		return nil
	}
	return s.viewers[i].peer
}

// Attach peer to this signaling socket. Replaces a previous peer on the same
// socket. Rejects a new socket when max_viewers > 0 and the list is full.
session_attach_peer :: proc(s: ^Session, sock: net.TCP_Socket, peer: ^network.Peer, max_viewers: int) -> (pending: [dynamic]Pending_Ice, ok: bool) {
	old: ^network.Peer

	sync.lock(&s.mu)
	i := viewer_index(s, sock)
	v: ^Viewer
	if i >= 0 {
		v = s.viewers[i]
	} else {
		if max_viewers > 0 && len(s.viewers) >= max_viewers {
			sync.unlock(&s.mu)
			return {}, false
		}
		v = new(Viewer)
		v.sock = sock
		append(&s.viewers, v)
	}
	old = v.peer
	v.peer = peer
	pending = v.pending
	v.pending = {}
	n := len(s.viewers)
	sync.unlock(&s.mu)

	if old != nil && old != peer {
		close_peer(old)
	}
	fmt.printf("viewer attached (n=%d)\n", n)
	return pending, true
}

session_queue_ice :: proc(s: ^Session, sock: net.TCP_Socket, candidate, mid: string, max_viewers: int) {
	if candidate == "" {
		return
	}

	sync.lock(&s.mu)
	i := viewer_index(s, sock)
	v: ^Viewer
	if i >= 0 {
		v = s.viewers[i]
	} else if max_viewers > 0 && len(s.viewers) >= max_viewers {
		sync.unlock(&s.mu)
		return
	} else {
		v = new(Viewer)
		v.sock = sock
		append(&s.viewers, v)
	}
	if v.peer != nil {
		peer := v.peer
		sync.unlock(&s.mu)
		network.peer_add_ice_candidate(peer, candidate, mid)
		return
	}
	append(&v.pending, Pending_Ice{
		candidate = strings.clone(candidate),
		mid       = strings.clone(mid),
	})
	sync.unlock(&s.mu)
}

session_remove_viewer :: proc(s: ^Session, sock: net.TCP_Socket) -> (remaining: int, found: bool) {
	v: ^Viewer

	sync.lock(&s.mu)
	i := viewer_index(s, sock)
	if i >= 0 {
		v = s.viewers[i]
		unordered_remove(&s.viewers, i)
		found = true
	}
	remaining = len(s.viewers)
	sync.unlock(&s.mu)

	if found {
		viewer_destroy(v)
		fmt.printf("viewer removed (n=%d)\n", remaining)
	}
	return remaining, found
}

session_request_keyframe :: proc(s: ^Session) {
	sync.lock(&s.mu)
	running := s.running
	use_gpu := s.use_gpu
	if running && s.key_armed && time.tick_since(s.last_key) < 500 * time.Millisecond {
		sync.unlock(&s.mu)
		return
	}
	if running {
		s.last_key = time.tick_now()
		s.key_armed = true
	}
	sync.unlock(&s.mu)
	if !running {
		return
	}
	if use_gpu {
		core.encoder_hw_request_keyframe(&s.enc_hw)
	} else {
		core.encoder_request_keyframe(&s.enc)
	}
}

@(private)
viewer_index :: proc(s: ^Session, sock: net.TCP_Socket) -> int {
	for v, i in s.viewers {
		if v.sock == sock {
			return i
		}
	}
	return -1
}

@(private)
close_peer :: proc(peer: ^network.Peer) {
	if peer == nil {
		return
	}
	if peer.user != nil {
		free(peer.user)
		peer.user = nil
	}
	network.peer_close(peer)
}

@(private)
viewer_destroy :: proc(v: ^Viewer) {
	if v == nil {
		return
	}
	close_peer(v.peer)
	for p in v.pending {
		delete(p.candidate)
		delete(p.mid)
	}
	delete(v.pending)
	free(v)
}

@(private)
session_loop :: proc(s: ^Session) {
	packets: [dynamic]core.Encoded_AU
	defer delete(packets)
	frame: core.Frame

	fps := s.cfg.fps
	if fps <= 0 {
		fps = 30
	}
	frame_ns := i64(1_000_000_000) / i64(fps)
	next_frame_ns := time.to_unix_nanoseconds(time.now())

	for {
		sync.shared_lock(&s.mu)
		running := s.running
		use_gpu := s.use_gpu
		sync.shared_unlock(&s.mu)
		if !running {
			break
		}

		now_ns := time.to_unix_nanoseconds(time.now())

		// Drop when more than three frame periods behind (avoid starving the encoder).
		if now_ns > next_frame_ns + 3 * frame_ns {
			skip := (now_ns - next_frame_ns) / frame_ns
			next_frame_ns += skip * frame_ns
			continue
		}

		if now_ns + 500_000 < next_frame_ns {
			remaining := next_frame_ns - now_ns
			if remaining > 2_000_000 {
				time.sleep(time.Duration(remaining - 1_000_000))
			} else {
				time.sleep(500 * time.Microsecond)
			}
			continue
		}
		next_frame_ns += frame_ns

		cerr := core.capture_frame(&s.cap, &frame)
		if cerr == .Timeout {
			continue
		}
		if cerr == .Device_Lost {
			fmt.eprintln("DXGI duplication lost; recreating")
			core.capture_close(&s.cap)
			cap, err := core.capture_open(s.cfg.monitor, s.cfg.cursor, use_gpu)
			if err != .None {
				fmt.eprintln("capture recreate failed:", err)
				break
			}
			sync.lock(&s.mu)
			s.cap = cap
			sync.unlock(&s.mu)
			continue
		}
		if cerr != .None {
			time.sleep(5 * time.Millisecond)
			continue
		}

		clear(&packets)
		encode_err: core.Encoder_Error
		if use_gpu && frame.gpu && frame.texture != nil {
			encode_err = core.encoder_encode_d3d11(&s.enc_hw, frame.texture, &packets)
		} else if len(frame.data) > 0 {
			encode_err = core.encoder_encode_bgra(&s.enc, frame.data, frame.width, frame.height, frame.stride, &packets)
		} else {
			continue
		}
		if encode_err != .None {
			if use_gpu {
				fmt.eprintf("d3d11 encode: %v\n", encode_err)
			}
			continue
		}
		if len(packets) == 0 {
			continue
		}

		if sync.shared_guard(&s.mu) {
			for v in s.viewers {
				if v.peer == nil {
					continue
				}
				for au in packets {
					ts_seconds := f64(au.pts) / f64(fps)
					err := network.peer_send_h264(v.peer, au.data, ts_seconds, au.is_keyframe)
					if err != .None && err != .Not_Open {
						fmt.eprintf("h264 send failed: %v (%d bytes)\n", err, len(au.data))
					}
				}
			}
		}
		for au in packets {
			delete(au.data)
		}
	}

	sync.lock(&s.mu)
	use_gpu := s.use_gpu
	sync.unlock(&s.mu)
	if use_gpu {
		core.encoder_hw_close(&s.enc_hw)
	} else {
		core.encoder_close(&s.enc)
	}
	core.capture_close(&s.cap)
	fmt.println("capture+encode stopped")
}
