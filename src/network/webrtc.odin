package network

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "core:time"

import rtc "../../vendor/libdatachannel"
import "../utils"

// One WebRTC peer connection per viewer: a send-only H.264 video track and,
// when the host streams audio, a send-only Opus track in the same stream.

VIDEO_CLOCK_RATE :: 90000
AUDIO_CLOCK_RATE :: 48000
VIDEO_SSRC       :: u32(42)
AUDIO_SSRC       :: u32(43)
STREAM_ID        :: "odysseus"

Peer_Config :: struct {
	bind_address: string, // ICE bind address; "" or a wildcard means any
	video_mid:    string,
	video_pt:     int,
	video_fmtp:   string,
	audio:        bool,
	audio_mid:    string,
	audio_pt:     int,
	audio_fmtp:   string,
}

Peer :: struct {
	pc:         c.int,
	video:      c.int,
	audio:      c.int, // -1 without an audio track
	video_open: bool,  // written by libdatachannel threads
	audio_open: bool,
	media:      bool,
	state:      rtc.State,
	video_pt:   int,
	audio_pt:   int,

	video_ts_origin:     u32,
	video_ts_origin_set: bool,
	audio_ts_origin:     u32,
	audio_ts_origin_set: bool,

	// Owned C strings that must outlive the libdatachannel objects.
	strings: [dynamic]cstring,

	on_local_description: proc(peer: ^Peer, sdp, type: string),
	on_local_candidate:   proc(peer: ^Peer, candidate, mid: string),
	on_state:             proc(peer: ^Peer, state: rtc.State),
	on_video_open:        proc(peer: ^Peer),
	on_pli:               proc(peer: ^Peer), // the viewer needs an IDR
	user:                 rawptr,

	retired_at: time.Tick,
}

Peer_Error :: enum {
	None,
	Create_Failed,
	Track_Failed,
	Send_Failed,
	Not_Open,
}

// rtc_init routes libdatachannel's log into ours and preloads its global state.
rtc_init :: proc(verbose: bool) {
	rtc.rtcInitLogger(.Debug if verbose else .Warning, _on_rtc_log)
	rtc.rtcPreload()
}

// rtc_cleanup tears libdatachannel's threads down; call once on shutdown after all peers are closed.
rtc_cleanup :: proc() {
	rtc.rtcCleanup()
}

@(private)
peer_cstring :: proc(peer: ^Peer, s: string) -> cstring {
	cs := strings.clone_to_cstring(s)
	append(&peer.strings, cs)
	return cs
}

peer_create :: proc(cfg: Peer_Config) -> (peer: ^Peer, err: Peer_Error) {
	peer = new(Peer)
	peer.pc = -1
	peer.video = -1
	peer.audio = -1
	peer.state = .New
	peer.video_pt = cfg.video_pt
	peer.audio_pt = cfg.audio_pt

	conf: rtc.Configuration
	// LAN only: no STUN/TURN. Both sides use host candidates.
	conf.force_media_transport = true
	switch cfg.bind_address {
	case "", "0.0.0.0", "::", "[::]":
	case:
		conf.bind_address = peer_cstring(peer, cfg.bind_address)
	}

	pc := rtc.rtcCreatePeerConnection(&conf)
	if pc < 0 {
		peer_free(peer)
		return nil, .Create_Failed
	}
	peer.pc = pc
	rtc.rtcSetUserPointer(pc, peer)
	rtc.rtcSetLocalDescriptionCallback(pc, _on_local_description)
	rtc.rtcSetLocalCandidateCallback(pc, _on_local_candidate)
	rtc.rtcSetStateChangeCallback(pc, _on_state)

	video_init := rtc.Track_Init{
		direction    = .Sendonly,
		codec        = .H264,
		payload_type = c.int(cfg.video_pt),
		ssrc         = VIDEO_SSRC,
		mid          = peer_cstring(peer, cfg.video_mid),
		name         = STREAM_ID,
		msid         = STREAM_ID,
		track_id     = "video0",
		profile      = peer_cstring(peer, cfg.video_fmtp) if cfg.video_fmtp != "" else rtc.H264_WEBRTC_PROFILE,
	}
	peer.video = rtc.rtcAddTrackEx(pc, &video_init)
	if peer.video < 0 {
		peer_close(peer)
		return nil, .Track_Failed
	}
	peer_track_callbacks(peer, peer.video)

	if cfg.audio {
		audio_init := rtc.Track_Init{
			direction    = .Sendonly,
			codec        = .Opus,
			payload_type = c.int(cfg.audio_pt),
			ssrc         = AUDIO_SSRC,
			mid          = peer_cstring(peer, cfg.audio_mid),
			name         = STREAM_ID,
			msid         = STREAM_ID,
			track_id     = "audio0",
			profile      = peer_cstring(peer, cfg.audio_fmtp) if cfg.audio_fmtp != "" else nil,
		}
		peer.audio = rtc.rtcAddTrackEx(pc, &audio_init)
		if peer.audio < 0 {
			// Video still works without it.
			utils.log_warn("could not add the audio track; this viewer gets video only")
			peer.audio = -1
		} else {
			peer_track_callbacks(peer, peer.audio)
		}
	}
	return peer, .None
}

@(private)
peer_track_callbacks :: proc(peer: ^Peer, track: c.int) {
	rtc.rtcSetUserPointer(track, peer)
	rtc.rtcSetOpenCallback(track, _on_track_open)
	rtc.rtcSetClosedCallback(track, _on_track_closed)
	rtc.rtcSetMessageCallback(track, _on_track_message)
	rtc.rtcSetErrorCallback(track, _on_error)
}

// Peers are freed a little after they are closed: a libdatachannel callback
// that was already running when the connection was deleted may still hold the pointer.
@(private)
RETIRE_DELAY :: 10 * time.Second
@(private)
_retired: [dynamic]^Peer
@(private)
_retired_mu: sync.Mutex

@(private)
peer_free :: proc(peer: ^Peer) {
	for s in peer.strings {
		delete(s)
	}
	delete(peer.strings)
	free(peer)
}

// peer_close deletes the connection and its tracks. The Peer must not be used afterwards.
peer_close :: proc(peer: ^Peer) {
	if peer == nil {
		return
	}
	peer.on_local_description = nil
	peer.on_local_candidate = nil
	peer.on_state = nil
	peer.on_video_open = nil
	peer.on_pli = nil
	peer.user = nil
	peer.video_open = false
	peer.audio_open = false

	if peer.audio >= 0 {
		rtc.rtcDeleteTrack(peer.audio)
		peer.audio = -1
	}
	if peer.video >= 0 {
		rtc.rtcDeleteTrack(peer.video)
		peer.video = -1
	}
	if peer.pc >= 0 {
		rtc.rtcDeletePeerConnection(peer.pc)
		peer.pc = -1
	}

	sync.mutex_lock(&_retired_mu)
	peer.retired_at = time.tick_now()
	append(&_retired, peer)
	for len(_retired) > 0 && time.tick_since(_retired[0].retired_at) > RETIRE_DELAY {
		peer_free(_retired[0])
		ordered_remove(&_retired, 0)
	}
	sync.mutex_unlock(&_retired_mu)
}

// peer_set_remote_offer applies the browser's offer; libdatachannel answers through on_local_description.
peer_set_remote_offer :: proc(peer: ^Peer, sdp: string) -> bool {
	sdp_c := strings.clone_to_cstring(sdp, context.temp_allocator)
	if rtc.rtcSetRemoteDescription(peer.pc, sdp_c, "offer") < 0 {
		return false
	}
	return peer_setup_media(peer)
}

@(private)
peer_setup_media :: proc(peer: ^Peer) -> bool {
	if peer.media {
		return true
	}

	video := rtc.Packetizer_Init{
		ssrc              = VIDEO_SSRC,
		cname             = STREAM_ID,
		payload_type      = u8(peer.video_pt),
		clock_rate        = VIDEO_CLOCK_RATE,
		nal_separator     = .Length,
		max_fragment_size = 1200,
	}
	if rtc.rtcSetH264Packetizer(peer.video, &video) < 0 {
		utils.log_error("rtcSetH264Packetizer failed")
		return false
	}
	rtc.rtcChainRtcpSrReporter(peer.video)
	rtc.rtcChainRtcpNackResponder(peer.video, 512)
	rtc.rtcChainPliHandler(peer.video, _on_pli)

	if peer.audio >= 0 {
		audio := rtc.Packetizer_Init{
			ssrc         = AUDIO_SSRC,
			cname        = STREAM_ID,
			payload_type = u8(peer.audio_pt),
			clock_rate   = AUDIO_CLOCK_RATE,
		}
		if rtc.rtcSetOpusPacketizer(peer.audio, &audio) < 0 {
			utils.log_warn("rtcSetOpusPacketizer failed; this viewer gets video only")
			rtc.rtcDeleteTrack(peer.audio)
			peer.audio = -1
		} else {
			rtc.rtcChainRtcpSrReporter(peer.audio)
		}
	}
	peer.media = true
	return true
}

peer_add_ice_candidate :: proc(peer: ^Peer, candidate, mid: string) -> bool {
	if candidate == "" {
		return true // end-of-candidates marker
	}
	cand_c := strings.clone_to_cstring(candidate, context.temp_allocator)
	mid_c: cstring
	if mid != "" {
		mid_c = strings.clone_to_cstring(mid, context.temp_allocator)
	}
	return rtc.rtcAddRemoteCandidate(peer.pc, cand_c, mid_c) >= 0
}

// peer_send_video sends one WebRTC-ready AVCC access unit captured `seconds` into the stream.
peer_send_video :: proc(peer: ^Peer, data: []byte, seconds: f64) -> Peer_Error {
	if peer == nil || peer.video < 0 || len(data) == 0 {
		return .Send_Failed
	}
	if !peer.video_open {
		return .Not_Open
	}
	if !peer.video_ts_origin_set {
		rtc.rtcGetCurrentTrackTimestamp(peer.video, &peer.video_ts_origin)
		peer.video_ts_origin_set = true
	}
	offset := u32(u64(seconds * VIDEO_CLOCK_RATE))
	rtc.rtcSetTrackRtpTimestamp(peer.video, peer.video_ts_origin + offset)
	if rtc.rtcSendMessage(peer.video, raw_data(data), c.int(len(data))) < 0 {
		return .Send_Failed
	}
	return .None
}

// peer_send_audio sends one Opus packet whose first sample was captured `seconds` into the stream.
peer_send_audio :: proc(peer: ^Peer, data: []byte, seconds: f64) -> Peer_Error {
	if peer == nil || peer.audio < 0 || len(data) == 0 {
		return .Send_Failed
	}
	if !peer.audio_open {
		return .Not_Open
	}
	if !peer.audio_ts_origin_set {
		rtc.rtcGetCurrentTrackTimestamp(peer.audio, &peer.audio_ts_origin)
		peer.audio_ts_origin_set = true
	}
	offset := u32(u64(seconds * AUDIO_CLOCK_RATE))
	rtc.rtcSetTrackRtpTimestamp(peer.audio, peer.audio_ts_origin + offset)
	if rtc.rtcSendMessage(peer.audio, raw_data(data), c.int(len(data))) < 0 {
		return .Send_Failed
	}
	return .None
}

@(private)
_on_rtc_log :: proc "c" (level: rtc.Log_Level, message: cstring) {
	context = runtime.default_context()
	#partial switch level {
	case .Fatal, .Error:
		utils.log_error("[rtc] %s", message)
	case .Warning:
		utils.log_warn("[rtc] %s", message)
	case:
		utils.log_debug("[rtc] %s", message)
	}
}

@(private)
_on_local_description :: proc "c" (pc: c.int, sdp, type: cstring, ptr: rawptr) {
	context = runtime.default_context()
	peer := (^Peer)(ptr)
	if peer == nil {
		return
	}
	if cb := peer.on_local_description; cb != nil {
		cb(peer, string(sdp), string(type))
	}
}

@(private)
_on_local_candidate :: proc "c" (pc: c.int, cand, mid: cstring, ptr: rawptr) {
	context = runtime.default_context()
	peer := (^Peer)(ptr)
	if peer == nil {
		return
	}
	if cb := peer.on_local_candidate; cb != nil {
		cb(peer, string(cand), string(mid))
	}
}

@(private)
_on_state :: proc "c" (pc: c.int, state: rtc.State, ptr: rawptr) {
	context = runtime.default_context()
	peer := (^Peer)(ptr)
	if peer == nil {
		return
	}
	peer.state = state
	utils.log_debug("webrtc state: %v", state)
	if cb := peer.on_state; cb != nil {
		cb(peer, state)
	}
}

@(private)
_on_error :: proc "c" (id: c.int, error: cstring, ptr: rawptr) {
	context = runtime.default_context()
	utils.log_warn("webrtc track error: %s", error)
}

@(private)
_on_pli :: proc "c" (tr: c.int, ptr: rawptr) {
	context = runtime.default_context()
	peer := (^Peer)(ptr)
	if peer == nil {
		return
	}
	if cb := peer.on_pli; cb != nil {
		cb(peer)
	}
}

@(private)
_on_track_open :: proc "c" (id: c.int, ptr: rawptr) {
	context = runtime.default_context()
	peer := (^Peer)(ptr)
	if peer == nil {
		return
	}
	if id == peer.video {
		peer.video_open = true
		utils.log_debug("video track open")
		if cb := peer.on_video_open; cb != nil {
			cb(peer)
		}
	} else if id == peer.audio {
		peer.audio_open = true
		utils.log_debug("audio track open")
	}
}

@(private)
_on_track_closed :: proc "c" (id: c.int, ptr: rawptr) {
	peer := (^Peer)(ptr)
	if peer == nil {
		return
	}
	if id == peer.video {
		peer.video_open = false
	} else if id == peer.audio {
		peer.audio_open = false
	}
}

@(private)
_on_track_message :: proc "c" (id: c.int, message: cstring, size: c.int, ptr: rawptr) {
	// Incoming RTCP is handled by the chained handlers; registering a callback keeps libdatachannel from queueing it.
}
