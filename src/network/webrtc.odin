package network

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import rtc "../../vendor/libdatachannel"
import "../core"
import "../utils"

VIDEO_CLOCK_RATE           :: 90000
VIDEO_PAYLOAD_TYPE_DEFAULT :: 108
VIDEO_SSRC                 :: u32(42)
VIDEO_MID                  :: "0"

Peer :: struct {
	pc:    c.int,
	track: c.int,
	open:  bool,
	media: bool,
	state: rtc.State,
	bind:    cstring, // owned; must outlive rtcCreatePeerConnection
	profile: cstring, // owned H264 fmtp for rtcAddTrackEx
	payload_type:  int,
	ts_origin:     u32,
	ts_origin_set: bool,

	on_local_description: proc(peer: ^Peer, sdp, type: string),
	on_local_candidate:   proc(peer: ^Peer, candidate, mid: string),
	on_state:             proc(peer: ^Peer, state: rtc.State),
	on_pli:               proc(peer: ^Peer), // encoder should emit an IDR
	user:                 rawptr,
}

Peer_Error :: enum {
	None,
	Create_Failed,
	Track_Failed,
	Packetizer_Failed,
	Send_Failed,
	Avcc_Failed,
	Prepare_Failed,
	Rtp_Failed,
	Stub_Libs,
	Not_Open,
}

peer_init_logger :: proc(level: rtc.Log_Level = .Warning) {
	rtc.rtcInitLogger(level, _on_rtc_log)
	rtc.rtcPreload()
}

peer_create :: proc(bind_address := "", h264_profile: string = "", payload_type: int = VIDEO_PAYLOAD_TYPE_DEFAULT) -> (peer: ^Peer, err: Peer_Error) {
	when rtc.STUB_LIBS {
		return nil, .Stub_Libs
	}

	peer = new(Peer)
	peer.pc = -1
	peer.track = -1
	peer.state = .New
	peer.payload_type = payload_type if payload_type > 0 else VIDEO_PAYLOAD_TYPE_DEFAULT

	cfg: rtc.Configuration
	// LAN-only: no STUN/TURN. Browser ICE will use host candidates.
	cfg.force_media_transport = true
	if bind_address != "" && bind_address != "0.0.0.0" && bind_address != "::" && bind_address != "[::]" {
		peer.bind = strings.clone_to_cstring(bind_address)
		cfg.bind_address = peer.bind
	}

	pc := rtc.rtcCreatePeerConnection(&cfg)
	if pc < 0 {
		if peer.bind != nil {
			delete(peer.bind)
		}
		free(peer)
		return nil, .Create_Failed
	}
	peer.pc = pc
	rtc.rtcSetUserPointer(pc, peer)

	rtc.rtcSetLocalDescriptionCallback(pc, _on_local_description)
	rtc.rtcSetLocalCandidateCallback(pc, _on_local_candidate)
	rtc.rtcSetStateChangeCallback(pc, _on_state)
	rtc.rtcSetIceStateChangeCallback(pc, _on_ice_state)

	profile_c: cstring = rtc.H264_WEBRTC_PROFILE
	if h264_profile != "" {
		peer.profile = strings.clone_to_cstring(h264_profile)
		profile_c = peer.profile
	}

	track_init := rtc.Track_Init{
		direction    = .Sendonly,
		codec        = .H264,
		payload_type = c.int(peer.payload_type),
		ssrc         = VIDEO_SSRC,
		mid          = VIDEO_MID,
		name         = "video",
		msid         = "odysseus",
		track_id     = "video0",
		profile      = profile_c,
	}
	tr := rtc.rtcAddTrackEx(pc, &track_init)
	if tr < 0 {
		peer_close(peer)
		return nil, .Track_Failed
	}
	peer.track = tr
	rtc.rtcSetUserPointer(tr, peer)

	rtc.rtcSetOpenCallback(tr, _on_track_open)
	rtc.rtcSetClosedCallback(tr, _on_track_closed)
	rtc.rtcSetMessageCallback(tr, _on_track_message)
	rtc.rtcSetErrorCallback(tr, _on_error)

	return peer, .None
}

peer_close :: proc(peer: ^Peer) {
	if peer == nil {
		return
	}
	if peer.track >= 0 {
		rtc.rtcDeleteTrack(peer.track)
		peer.track = -1
	}
	if peer.pc >= 0 {
		rtc.rtcDeletePeerConnection(peer.pc)
		peer.pc = -1
	}
	if peer.bind != nil {
		delete(peer.bind)
		peer.bind = nil
	}
	if peer.profile != nil {
		delete(peer.profile)
		peer.profile = nil
	}
	free(peer)
}

peer_set_remote_description :: proc(peer: ^Peer, sdp, type: string) -> c.int {
	sdp_c := strings.clone_to_cstring(sdp)
	type_c := strings.clone_to_cstring(type)
	defer delete(sdp_c)
	defer delete(type_c)
	result := rtc.rtcSetRemoteDescription(peer.pc, sdp_c, type_c)
	if result < 0 {
		return result
	}
	if !peer_setup_media(peer) {
		return -1
	}
	return result
}

@(private)
peer_setup_media :: proc(peer: ^Peer) -> bool {
	if peer.media {
		return true
	}

	pt := peer.payload_type
	utils.log_line(fmt.tprintf("negotiated H264 PT=%d", pt))

	packetizer := rtc.Packetizer_Init{
		ssrc              = VIDEO_SSRC,
		cname             = "video",
		payload_type      = u8(pt),
		clock_rate        = VIDEO_CLOCK_RATE,
		nal_separator     = .Length,
		max_fragment_size = 1200,
	}
	if rtc.rtcSetH264Packetizer(peer.track, &packetizer) < 0 {
		utils.log_error("rtcSetH264Packetizer failed")
		return false
	}
	rtc.rtcChainRtcpSrReporter(peer.track)
	rtc.rtcChainRtcpNackResponder(peer.track, 512)
	rtc.rtcChainPliHandler(peer.track, _on_pli)
	peer.media = true
	return true
}

peer_add_ice_candidate :: proc(peer: ^Peer, candidate, mid: string) -> c.int {
	cand_c := strings.clone_to_cstring(candidate)
	mid_c: cstring
	if mid != "" {
		mid_c = strings.clone_to_cstring(mid)
	}
	result := rtc.rtcAddRemoteCandidate(peer.pc, cand_c, mid_c)
	delete(cand_c)
	if mid_c != nil {
		delete(mid_c)
	}
	return result
}

peer_send_h264 :: proc(peer: ^Peer, data: []byte, timestamp_seconds: f64, is_keyframe: bool) -> Peer_Error {
	if peer == nil || peer.track < 0 {
		return .Send_Failed
	}
	if !peer.open {
		return .Not_Open
	}

	avcc := core.h264_to_avcc(data)
	if len(avcc) == 0 {
		return .Avcc_Failed
	}
	defer delete(avcc)

	webrtc := core.h264_avcc_prepare_for_webrtc(avcc, is_keyframe)
	if len(webrtc) == 0 {
		return .Prepare_Failed
	}
	defer delete(webrtc)

	ts_offset: u32
	if rtc.rtcTransformSecondsToTimestamp(peer.track, timestamp_seconds, &ts_offset) == rtc.ERR_SUCCESS {
		if !peer.ts_origin_set {
			cur: u32
			if rtc.rtcGetCurrentTrackTimestamp(peer.track, &cur) == rtc.ERR_SUCCESS {
				peer.ts_origin = cur
			}
			peer.ts_origin_set = true
		}
		rtc.rtcSetTrackRtpTimestamp(peer.track, peer.ts_origin + ts_offset)
	}

	n := c.int(len(webrtc))
	if rtc.rtcSendMessage(peer.track, raw_data(webrtc), n) < 0 {
		return .Rtp_Failed
	}
	return .None
}

@(private)
_on_rtc_log :: proc "c" (level: rtc.Log_Level, message: cstring) {
	context = runtime.default_context()
	utils.log_line(fmt.tprintf("[rtc %v] %s", level, message))
}

@(private)
_from_ptr :: proc(ptr: rawptr) -> ^Peer {
	return (^Peer)(ptr)
}

@(private)
_on_local_description :: proc "c" (pc: c.int, sdp, type: cstring, ptr: rawptr) {
	context = runtime.default_context()
	peer := _from_ptr(ptr)
	if peer == nil || peer.on_local_description == nil {
		return
	}
	peer.on_local_description(peer, string(sdp), string(type))
}

@(private)
_on_local_candidate :: proc "c" (pc: c.int, cand, mid: cstring, ptr: rawptr) {
	context = runtime.default_context()
	peer := _from_ptr(ptr)
	if peer == nil || peer.on_local_candidate == nil {
		return
	}
	peer.on_local_candidate(peer, string(cand), string(mid))
}

@(private)
_on_state :: proc "c" (pc: c.int, state: rtc.State, ptr: rawptr) {
	context = runtime.default_context()
	peer := _from_ptr(ptr)
	if peer == nil {
		return
	}
	peer.state = state
	if state != .Connecting {
		utils.log_line(fmt.tprintf("webrtc state: %v", state))
	}
	if peer.on_state != nil {
		peer.on_state(peer, state)
	}
}

@(private)
_on_ice_state :: proc "c" (pc: c.int, state: rtc.Ice_State, ptr: rawptr) {
	context = runtime.default_context()
	if state == .Failed || state == .Disconnected {
		utils.log_line(fmt.tprintf("ice state: %v", state))
	}
	_ = pc
	_ = ptr
}

@(private)
_on_error :: proc "c" (id: c.int, error: cstring, ptr: rawptr) {
	context = runtime.default_context()
	fmt.eprintln("webrtc error:", error)
	utils.log_error(fmt.tprintf("webrtc error: %s", error))
	_ = id
	_ = ptr
}

@(private)
_on_pli :: proc "c" (tr: c.int, ptr: rawptr) {
	context = runtime.default_context()
	peer := _from_ptr(ptr)
	if peer != nil && peer.on_pli != nil {
		peer.on_pli(peer)
	}
}

@(private)
_on_track_open :: proc "c" (id: c.int, ptr: rawptr) {
	context = runtime.default_context()
	peer := _from_ptr(ptr)
	if peer != nil {
		peer.open = true
		utils.log_line("video track open")
	}
}

@(private)
_on_track_closed :: proc "c" (id: c.int, ptr: rawptr) {
	context = runtime.default_context()
	peer := _from_ptr(ptr)
	if peer != nil {
		peer.open = false
	}
}

@(private)
_on_track_message :: proc "c" (id: c.int, message: cstring, size: c.int, ptr: rawptr) {
	// Required so libdatachannel does not warn; RTCP is handled internally.
}
