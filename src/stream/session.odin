package stream

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../audio"
import "../core"
import "../network"
import "../utils"

// The streaming session: one capture + encode pipeline shared by every
// viewer. It starts with the first viewer and stops when the last one leaves.
// The pipeline lives entirely on the session thread; other threads only flip
// flags (keyframe, monitor switch) and manage the viewer list.

Viewer :: struct {
	key:  rawptr, // signaling client that owns this viewer
	peer: ^network.Peer,
}

// Stream_Info describes what is currently being streamed.
Stream_Info :: struct {
	monitor: int,
	width:   int, // encoded size
	height:  int,
	source_width:  int, // captured size
	source_height: int,
	monitor_x:     int, // position of the captured monitor on the virtual desktop
	monitor_y:     int,
	fps:     int,
	encoder: string, // static or session-owned; valid until the next pipeline restart
	capture: string,
	audio:   bool,
}

Session :: struct {
	cfg:       utils.Config,
	on_change: proc(user: rawptr), // stream info or viewer count changed; called without locks held
	on_ended:  proc(user: rawptr), // the host refused or ended the share; called on the session thread as it exits
	user:      rawptr,

	mu:       sync.RW_Mutex, // viewers, info, headers, running, loop
	viewers:  [dynamic]^Viewer,
	running:  bool,
	loop:     ^thread.Thread,
	info:     Stream_Info,
	enc_name: [32]u8,
	headers:  []byte, // SPS/PPS of the running encoder, for the SDP fmtp

	start_mu: sync.Mutex, // serializes session_start / session_stop
	started:  sync.Sema,  // posted by the loop once the pipeline is open (or failed)
	start_ok: bool,

	joining:  int,  // callers between session_start and attach / abort (under mu)
	stopping: bool, // process is shutting down (under mu)

	monitor:    int,       // monitor the pipeline should capture
	restart:    bool,      // atomic: reopen the pipeline
	key_wanted: bool,      // atomic: next frame must be an IDR
	last_key:   time.Tick, // PLI storm throttle, under mu
	key_armed:  bool,

	denied_until: i64, // now_ns clock; no new capture attempt before this (under mu)

	start_ns: i64, // timestamp origin shared by audio and video
	audio:    ^audio.Stream,
}

@(private)
KEYFRAME_MIN_INTERVAL :: 500 * time.Millisecond

// After the host refuses or ends a share, viewers cannot trigger another
// request (and another dialog on the host's screen) for this long.
@(private)
DENIED_COOLDOWN :: 30 * time.Second

Start_Result :: enum {
	Ok,
	Failed, // capture or encoder could not be opened
	Denied, // the host refused or recently ended the share
}

session_init :: proc(
	s: ^Session,
	cfg: utils.Config,
	on_change: proc(user: rawptr) = nil,
	on_ended: proc(user: rawptr) = nil,
	user: rawptr = nil,
) {
	s.cfg = cfg
	s.monitor = cfg.monitor
	s.info.monitor = cfg.monitor
	s.on_change = on_change
	s.on_ended = on_ended
	s.user = user
}

// session_start makes sure the pipeline is running. It blocks until the
// capture and encoder are open (which can include the host answering a
// screen-share dialog).
//
// A successful call reserves the session for the caller: it will not be
// stopped for being empty until the caller either attaches its peer
// (session_attach_peer) or gives up (session_join_abort).
session_start :: proc(s: ^Session) -> Start_Result {
	sync.lock(&s.start_mu)
	defer sync.unlock(&s.start_mu)

	sync.lock(&s.mu)
	if s.stopping {
		sync.unlock(&s.mu)
		return .Failed
	}
	if s.running {
		s.joining += 1
		sync.unlock(&s.mu)
		return .Ok
	}
	if core.now_ns() < s.denied_until {
		sync.unlock(&s.mu)
		return .Denied
	}
	leftover := s.loop
	s.loop = nil
	sync.unlock(&s.mu)
	if leftover != nil {
		thread.join(leftover)
		thread.destroy(leftover)
	}

	sync.lock(&s.mu)
	s.running = true
	s.start_ok = false
	s.key_armed = false
	s.start_ns = core.now_ns()
	sync.atomic_store(&s.restart, false)
	sync.atomic_store(&s.key_wanted, true)
	s.loop = thread.create_and_start_with_poly_data(s, session_loop)
	sync.unlock(&s.mu)

	sync.sema_wait(&s.started)
	if !s.start_ok {
		sync.lock(&s.mu)
		failed := s.loop
		s.loop = nil
		s.running = false
		denied := core.now_ns() < s.denied_until
		sync.unlock(&s.mu)
		if failed != nil {
			thread.join(failed)
			thread.destroy(failed)
		}
		return .Denied if denied else .Failed
	}

	if s.cfg.audio {
		s.audio = audio.start({device = s.cfg.audio_device, bitrate_kbps = s.cfg.audio_bitrate}, session_audio_packet, s)
	}
	sync.lock(&s.mu)
	s.info.audio = s.audio != nil
	s.joining += 1
	sync.unlock(&s.mu)
	return .Ok
}

// session_join_abort gives up a reservation made by session_start.
session_join_abort :: proc(s: ^Session) {
	sync.lock(&s.mu)
	s.joining = max(s.joining - 1, 0)
	sync.unlock(&s.mu)
}

// session_stop ends the pipeline and disconnects every viewer.
session_stop :: proc(s: ^Session) {
	sync.lock(&s.start_mu)
	defer sync.unlock(&s.start_mu)
	stop_locked(s)
}

// session_stop_if_idle stops the pipeline when nobody is watching and nobody
// is in the middle of joining. The check and the stop are one step, so a
// viewer that is just connecting cannot end up attached to a stopped session.
session_stop_if_idle :: proc(s: ^Session) {
	sync.lock(&s.start_mu)
	defer sync.unlock(&s.start_mu)

	sync.shared_lock(&s.mu)
	idle := len(s.viewers) == 0 && s.joining == 0
	sync.shared_unlock(&s.mu)
	// start_mu keeps new joiners out between the check and the stop.
	if idle {
		stop_locked(s)
	}
}

// session_shutdown stops the session for good; later session_start calls fail.
session_shutdown :: proc(s: ^Session) {
	sync.lock(&s.mu)
	s.stopping = true
	sync.unlock(&s.mu)
	session_stop(s)
}

// Caller holds start_mu.
@(private)
stop_locked :: proc(s: ^Session) {
	if s.audio != nil {
		audio.stop(s.audio)
		s.audio = nil
	}

	sync.lock(&s.mu)
	s.running = false
	loop := s.loop
	s.loop = nil
	viewers := s.viewers
	s.viewers = {}
	s.info.audio = false
	sync.unlock(&s.mu)

	for v in viewers {
		viewer_destroy(v)
	}
	delete(viewers)

	if loop != nil {
		thread.join(loop)
		thread.destroy(loop)
	}
}

// session_audio_available reports whether viewers should be offered an audio track.
session_audio_available :: proc(s: ^Session) -> bool {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	return s.info.audio
}

// session_info returns a snapshot; its strings are temp-allocated copies.
session_info :: proc(s: ^Session) -> Stream_Info {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	info := s.info
	info.encoder = strings.clone(s.info.encoder, context.temp_allocator)
	return info
}

// session_video_fmtp builds the H.264 fmtp of the SDP answer for the running encoder.
session_video_fmtp :: proc(s: ^Session, allocator := context.allocator) -> string {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	return core.h264_fmtp(s.info.width, s.info.height, s.info.fps, s.headers, allocator)
}

session_viewer_count :: proc(s: ^Session) -> int {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	return len(s.viewers)
}

session_has_viewer :: proc(s: ^Session, key: rawptr) -> bool {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	return viewer_index(s, key) >= 0
}

Attach_Result :: enum {
	Ok,
	Full,        // max_viewers reached
	Not_Running, // the session stopped (host ended the share, shutdown) since session_start
}

// session_attach_peer binds a peer to its signaling client, replacing the
// client's previous peer, and ends the reservation made by session_start.
session_attach_peer :: proc(s: ^Session, key: rawptr, peer: ^network.Peer, max_viewers: int) -> Attach_Result {
	sync.lock(&s.mu)
	s.joining = max(s.joining - 1, 0)
	if !s.running {
		sync.unlock(&s.mu)
		return .Not_Running
	}
	v: ^Viewer
	if i := viewer_index(s, key); i >= 0 {
		v = s.viewers[i]
	} else {
		if max_viewers > 0 && len(s.viewers) >= max_viewers {
			sync.unlock(&s.mu)
			return .Full
		}
		v = new(Viewer)
		v.key = key
		append(&s.viewers, v)
	}
	old := v.peer
	v.peer = peer
	count := len(s.viewers)
	sync.unlock(&s.mu)

	if old != nil && old != peer {
		network.peer_close(old)
	}
	utils.log_info("viewer connected (%d watching)", count)
	notify(s)
	return .Ok
}

// Longest ICE candidate line accepted from a viewer.
@(private)
MAX_CANDIDATE_LENGTH :: 1024

// session_add_ice hands a remote candidate to the client's peer. Browsers
// send candidates only after their offer, which the same connection thread
// has already handled; a candidate without a peer belongs to a failed offer
// and is dropped.
session_add_ice :: proc(s: ^Session, key: rawptr, candidate, mid: string) {
	if candidate == "" || len(candidate) > MAX_CANDIDATE_LENGTH || len(mid) > 64 {
		return
	}
	peer: ^network.Peer
	sync.shared_lock(&s.mu)
	if i := viewer_index(s, key); i >= 0 {
		peer = s.viewers[i].peer
	}
	sync.shared_unlock(&s.mu)
	// Outside the lock: libdatachannel may call back into the session.
	if peer != nil {
		network.peer_add_ice_candidate(peer, candidate, mid)
	}
}

// session_remove_viewer drops a client's viewer and returns how many remain.
session_remove_viewer :: proc(s: ^Session, key: rawptr) -> (remaining: int) {
	v: ^Viewer
	sync.lock(&s.mu)
	if i := viewer_index(s, key); i >= 0 {
		v = s.viewers[i]
		unordered_remove(&s.viewers, i)
	}
	remaining = len(s.viewers)
	sync.unlock(&s.mu)

	if v != nil {
		viewer_destroy(v)
		utils.log_info("viewer disconnected (%d watching)", remaining)
		notify(s)
	}
	return
}

// session_request_keyframe asks for an IDR. Requests closer together than
// KEYFRAME_MIN_INTERVAL collapse into one (browsers repeat PLI until the
// keyframe arrives) unless `force` is set, which a viewer's track opening
// uses: that viewer cannot decode anything sent before.
session_request_keyframe :: proc(s: ^Session, force := false) {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if !s.running {
		return
	}
	if !force && s.key_armed && time.tick_since(s.last_key) < KEYFRAME_MIN_INTERVAL {
		return
	}
	s.last_key = time.tick_now()
	s.key_armed = true
	sync.atomic_store(&s.key_wanted, true)
}

// session_set_monitor switches the captured monitor. The pipeline restarts on
// the session thread; on_change fires once the new stream is up.
session_set_monitor :: proc(s: ^Session, index: int) -> bool {
	if index < 0 {
		return false
	}
	if _, ok := core.monitor_by_index(index); !ok {
		return false
	}
	sync.lock(&s.mu)
	changed := s.monitor != index
	s.monitor = index
	if !s.running {
		s.info.monitor = index
	}
	sync.unlock(&s.mu)
	if changed {
		sync.atomic_store(&s.restart, true)
		notify(s)
	}
	return true
}

// session_input_target describes the monitor being streamed, for mapping
// remote input: its position on the virtual desktop and its size in pixels.
// ok is false while nothing is streamed.
session_input_target :: proc(s: ^Session) -> (target: core.Monitor_Info, ok: bool) {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	if !s.running || s.info.source_width <= 0 {
		return {}, false
	}
	return {
		index  = s.info.monitor,
		x      = s.info.monitor_x,
		y      = s.info.monitor_y,
		width  = s.info.source_width,
		height = s.info.source_height,
	}, true
}

session_monitor :: proc(s: ^Session) -> int {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	return s.monitor
}

@(private)
notify :: proc(s: ^Session) {
	if s.on_change != nil {
		s.on_change(s.user)
	}
}

@(private)
viewer_index :: proc(s: ^Session, key: rawptr) -> int {
	for v, i in s.viewers {
		if v.key == key {
			return i
		}
	}
	return -1
}

@(private)
viewer_destroy :: proc(v: ^Viewer) {
	network.peer_close(v.peer)
	free(v)
}

// Audio capture thread: fan one Opus packet out to every viewer.
@(private)
session_audio_packet :: proc(user: rawptr, packet: []byte, capture_ns: i64) {
	s := (^Session)(user)
	seconds := f64(max(capture_ns - s.start_ns, 0)) / 1e9
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	for v in s.viewers {
		if v.peer != nil {
			network.peer_send_audio(v.peer, packet, seconds)
		}
	}
}

// ---------------------------------------------------------------------------
// Pipeline (session thread only)

@(private)
Pipeline :: struct {
	cap:      core.Capture,
	enc:      ^core.Encoder,
	bad:      [dynamic]string, // encoders that opened but then failed to encode
	failures: int,             // consecutive encode errors
	denied:   bool,            // the last open was refused by the host
	reopened: time.Tick,       // when the pipeline was last reopened
}

@(private)
ENCODE_FAILURE_LIMIT :: 10

@(private)
pipeline_close :: proc(p: ^Pipeline) {
	if p.enc != nil {
		core.encoder_close(p.enc)
		p.enc = nil
	}
	core.capture_close(&p.cap)
}

@(private)
pipeline_open :: proc(s: ^Session, p: ^Pipeline) -> bool {
	cfg := &s.cfg
	sync.shared_lock(&s.mu)
	monitor := s.monitor
	sync.shared_unlock(&s.mu)

	capture_opts := core.Capture_Options{
		backend    = cfg.capture,
		monitor    = monitor,
		cursor     = cfg.cursor,
		fps        = cfg.fps,
		prefer_gpu = true,
		input      = cfg.input,
	}
	requested_monitor := monitor
	cap, cerr := core.capture_open(capture_opts)
	if cerr == .No_Output && monitor != 0 {
		utils.log_warn("monitor %d does not exist; capturing monitor 0", monitor)
		monitor = 0
		capture_opts.monitor = 0
		cap, cerr = core.capture_open(capture_opts)
	}
	p.denied = cerr == .Denied
	if cerr == .Denied {
		utils.log_info("the host did not allow screen sharing")
		return false
	}
	if cerr != .None {
		utils.log_error("screen capture could not be started: %v", cerr)
		return false
	}

	w, h := utils.scaled_size(cfg.width, cfg.height, cap.width, cap.height)
	enc_opts := core.Encoder_Options{width = w, height = h, fps = cfg.fps, bitrate_kbps = cfg.bitrate}

	// GPU-fed encoders first (the frame never leaves the GPU), then CPU-fed
	// ones, which need the capture reopened in system-memory mode.
	enc: ^core.Encoder
	eerr := core.Encoder_Error.Codec_Not_Found
	zero_copy := false
	requested := cfg.encoder
	if cap.gpu {
		enc, eerr = core.encoder_open_zero_copy(requested, &cap, enc_opts, p.bad[:])
		if eerr != .None && !core.encoder_is_auto(requested) && !core.encoder_exists_working(requested, enc_opts, p.bad[:]) {
			// The requested encoder does not work at all: fall back to the automatic choice.
			utils.log_warn("encoder %s is not usable here; picking one automatically", requested)
			requested = "h264"
			enc, eerr = core.encoder_open_zero_copy(requested, &cap, enc_opts, p.bad[:])
		}
		zero_copy = eerr == .None
		if !zero_copy {
			core.capture_close(&cap)
			capture_opts.prefer_gpu = false
			cap, cerr = core.capture_open(capture_opts)
			if cerr != .None {
				p.denied = cerr == .Denied
				utils.log_error("screen capture could not be started: %v", cerr)
				return false
			}
		}
	}
	if enc == nil {
		enc, eerr = core.encoder_open_best(requested, enc_opts, p.bad[:])
	}
	if eerr != .None {
		utils.log_error("no usable H.264 encoder (%v); try -list-encoders", eerr)
		core.capture_close(&cap)
		return false
	}

	p.cap = cap
	p.enc = enc
	p.failures = 0

	// Looked up once per pipeline: input events are mapped through it.
	geometry, _ := core.monitor_by_index(monitor)

	sync.lock(&s.mu)
	delete(s.headers)
	s.headers = nil
	n := copy(s.enc_name[:], core.encoder_name(enc))
	if monitor != requested_monitor && s.monitor == requested_monitor {
		// Fell back to monitor 0. A switch requested meanwhile stays in place
		// (its restart flag is already set).
		s.monitor = monitor
	}
	s.info.monitor = monitor
	s.info.monitor_x = geometry.x
	s.info.monitor_y = geometry.y
	s.info.width = w
	s.info.height = h
	s.info.source_width = cap.width
	s.info.source_height = cap.height
	s.info.fps = cfg.fps
	s.info.encoder = string(s.enc_name[:n])
	s.info.capture = core.BACKEND_NAME[cap.backend]
	sync.unlock(&s.mu)
	sync.atomic_store(&s.key_wanted, true)

	utils.log_info("streaming monitor %d: %dx%d -> %dx%d @ %d fps, %s capture, %s%s, %d kbps",
		monitor, cap.width, cap.height, w, h, cfg.fps,
		core.BACKEND_NAME[cap.backend], core.encoder_name(enc), " (zero-copy)" if zero_copy else "", cfg.bitrate)
	return true
}

// Reopens the pipeline until it works or the session stops.
@(private)
pipeline_reopen :: proc(s: ^Session, p: ^Pipeline, frame: ^core.Frame) -> bool {
	// The frame's pixels (or texture) belong to the capture being closed.
	frame^ = {}
	pipeline_close(p)
	// A capture that opens and is lost again at once (a display that keeps
	// changing mode) must not turn this into a busy loop.
	if time.tick_since(p.reopened) < time.Second {
		time.sleep(250 * time.Millisecond)
	}
	p.reopened = time.tick_now()
	delay := 100 * time.Millisecond
	for session_running(s) {
		if pipeline_open(s, p) {
			notify(s)
			return true
		}
		if p.denied {
			session_end_denied(s)
			return false
		}
		time.sleep(delay)
		delay = min(delay * 2, 2 * time.Second)
	}
	return false
}

// The host refused or ended the share: stop serving and keep viewers from
// re-triggering the request for a while. Runs on the session thread; the
// owner finishes the teardown (session_stop) from on_ended.
@(private)
session_end_denied :: proc(s: ^Session) {
	sync.lock(&s.mu)
	s.denied_until = core.now_ns() + i64(DENIED_COOLDOWN)
	was_running := s.running
	s.running = false
	sync.unlock(&s.mu)
	if was_running && s.on_ended != nil {
		s.on_ended(s.user)
	}
}

@(private)
session_running :: proc(s: ^Session) -> bool {
	sync.shared_lock(&s.mu)
	defer sync.shared_unlock(&s.mu)
	return s.running
}

@(private)
session_loop :: proc(s: ^Session) {
	pipe: Pipeline
	defer {
		for name in pipe.bad {
			delete(name)
		}
		delete(pipe.bad)
	}

	s.start_ok = pipeline_open(s, &pipe)
	if !s.start_ok && pipe.denied {
		sync.lock(&s.mu)
		s.denied_until = core.now_ns() + i64(DENIED_COOLDOWN)
		sync.unlock(&s.mu)
	}
	sync.sema_post(&s.started)
	if !s.start_ok {
		return
	}
	defer {
		pipeline_close(&pipe)
		utils.log_info("capture stopped")
	}

	packets: [dynamic]core.Encoded_AU
	defer delete(packets)
	frame: core.Frame

	frame_ns := i64(time.Second) / i64(max(s.cfg.fps, 1))
	next_frame_ns := core.now_ns()
	last_change_ns := next_frame_ns // last time the desktop actually changed
	last_sent_ns := i64(0)
	capture_failures := 0

	for session_running(s) {
		free_all(context.temp_allocator)

		if sync.atomic_exchange(&s.restart, false) {
			if !pipeline_reopen(s, &pipe, &frame) {
				break
			}
			next_frame_ns = core.now_ns()
		}

		if !pipe.cap.self_paced {
			now := core.now_ns()
			if now > next_frame_ns + 3 * frame_ns {
				// Far behind (the capture blocked): resynchronize instead of bursting.
				next_frame_ns = now
			}
			if wait := next_frame_ns - now; wait > 500_000 {
				time.sleep(time.Duration(min(wait, 20_000_000)))
				continue
			}
			next_frame_ns += frame_ns
		}

		cerr := core.capture_frame(&pipe.cap, &frame)
		now := core.now_ns()
		#partial switch cerr {
		case .None:
			capture_failures = 0
			last_change_ns = now
		case .Timeout:
			// Nothing changed on screen. Re-encode the previous frame when a
			// viewer needs a keyframe, for a moment after the last change (so
			// the still image sharpens), and once a second as a keepalive.
			if frame.width == 0 {
				continue
			}
			idle := now - last_change_ns
			if !sync.atomic_load(&s.key_wanted) && idle > i64(time.Second) && now - last_sent_ns < i64(time.Second) {
				continue
			}
			frame.timestamp_ns = now
		case .Denied:
			session_end_denied(s)
			return
		case .Device_Lost:
			utils.log_info("capture device lost (mode change or secure desktop); reopening")
			if !pipeline_reopen(s, &pipe, &frame) {
				return
			}
			capture_failures = 0
			continue
		case:
			capture_failures += 1
			if capture_failures >= 50 {
				utils.log_warn("capture keeps failing (%v); reopening", cerr)
				if !pipeline_reopen(s, &pipe, &frame) {
					return
				}
				capture_failures = 0
			} else {
				time.sleep(5 * time.Millisecond)
			}
			continue
		}

		if sync.atomic_exchange(&s.key_wanted, false) {
			core.encoder_request_keyframe(pipe.enc)
		}

		clear(&packets)
		if eerr := core.encoder_encode(pipe.enc, &frame, &packets); eerr != .None {
			for au in packets {
				delete(au.data)
			}
			pipe.failures += 1
			if pipe.failures >= ENCODE_FAILURE_LIMIT {
				name := strings.clone(core.encoder_name(pipe.enc))
				utils.log_warn("encoder %s keeps failing (%v); switching encoder", name, eerr)
				append(&pipe.bad, name)
				if !pipeline_reopen(s, &pipe, &frame) {
					return
				}
			}
			continue
		}
		pipe.failures = 0
		if len(packets) == 0 {
			continue
		}
		if utils.log_is_verbose() {
			for au in packets {
				if au.is_keyframe {
					utils.log_debug("keyframe: %d bytes", len(au.data))
				}
			}
		}

		seconds := f64(max(frame.timestamp_ns - s.start_ns, 0)) / 1e9
		sync.shared_lock(&s.mu)
		need_headers := s.headers == nil && pipe.enc.headers != nil
		for v in s.viewers {
			if v.peer == nil {
				continue
			}
			for au in packets {
				if err := network.peer_send_video(v.peer, au.data, seconds); err == .Send_Failed {
					utils.log_debug("video send failed (%d bytes)", len(au.data))
				}
			}
		}
		sync.shared_unlock(&s.mu)
		last_sent_ns = now

		if need_headers {
			sync.lock(&s.mu)
			if s.headers == nil {
				s.headers = make([]byte, len(pipe.enc.headers))
				copy(s.headers, pipe.enc.headers)
			}
			sync.unlock(&s.mu)
		}
		for au in packets {
			delete(au.data)
		}
	}
}
