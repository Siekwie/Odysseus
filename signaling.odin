package main

import "core:crypto"
import "core:encoding/json"
import "core:net"
import "core:thread"
import "core:time"

import "src/core"
import "src/input"
import "src/network"
import "src/server"
import "src/stream"
import "src/utils"

// Signaling: what the server does with each WebSocket message. These run on
// the connection threads; the session and server do their own locking.

@(private)
AUTH_FAILURE_LIMIT :: 5
@(private)
AUTH_FAILURE_DELAY :: 750 * time.Millisecond

on_client_open :: proc(user: rawptr, client: ^server.Client) {
	client.authorized = app.cfg.password == ""
	client.control = false
	send_hello(client)
}

on_client_close :: proc(user: rawptr, client: ^server.Client) {
	if client.control {
		// A viewer that vanishes mid-keystroke must not leave keys held on the host.
		input.release_all()
	}
	if stream.session_remove_viewer(&app.session, client) == 0 {
		stream.session_stop(&app.session)
	}
}

on_client_message :: proc(user: rawptr, client: ^server.Client, msg: ^network.Signal_Message) {
	if msg.type == "auth" {
		handle_auth(client, msg.password)
		return
	}
	if !client.authorized {
		server.client_send_error(client, "auth", "password required")
		return
	}

	switch msg.type {
	case "offer":
		handle_offer(client, msg.sdp)
	case "candidate":
		stream.session_add_ice(&app.session, client, msg.candidate, msg.mid, app.cfg.max_viewers)
	case "keyframe", "viewer-ready":
		stream.session_request_keyframe(&app.session)
	case "monitor":
		if !stream.session_set_monitor(&app.session, msg.index) {
			server.client_send_error(client, "monitor", "no such monitor")
		}
	case "input":
		handle_input(client, msg)
	}
}

// GET /api/status
on_status :: proc(user: rawptr, allocator := context.allocator) -> string {
	data, err := json.marshal(state_message(), allocator = allocator)
	if err != nil {
		return "{}"
	}
	return string(data)
}

// The stream changed (viewer count, monitor, encoder): tell every viewer.
on_stream_change :: proc(user: rawptr) {
	state := state_message()
	server.broadcast(&state, proc(user: rawptr, client: ^server.Client) {
		if client.authorized {
			server.client_send(client, (^network.State_Message)(user)^)
		}
	})
}

// The host refused or ended the share (session thread, about to exit):
// tell the viewers and finish the teardown from a thread that may join it.
on_stream_ended :: proc(user: rawptr) {
	server.broadcast(nil, proc(user: rawptr, client: ^server.Client) {
		if client.authorized {
			server.client_send_error(client, "denied", "the host is not sharing its screen")
		}
	})
	thread.create_and_start(proc() {
		stream.session_stop(&app.session)
	}, self_cleanup = true)
}

@(private)
state_message :: proc() -> network.State_Message {
	info := stream.session_info(&app.session)
	return {
		type    = "state",
		monitor = stream.session_monitor(&app.session),
		width   = info.width,
		height  = info.height,
		fps     = info.fps,
		encoder = info.encoder,
		capture = info.capture,
		viewers = stream.session_viewer_count(&app.session),
	}
}

@(private)
send_hello :: proc(client: ^server.Client) {
	cfg := &app.cfg
	hello := network.Hello_Message{
		type        = "hello",
		version     = utils.VERSION,
		authorized  = client.authorized,
		audio       = cfg.audio,
		input       = cfg.input,
		control     = client.control,
		control_pin = cfg.input && client.authorized && !client.control,
		cursor      = cfg.cursor,
		monitor     = stream.session_monitor(&app.session),
	}

	// Monitor names and geometry are only shown to viewers that may watch.
	monitors: []core.Monitor_Info
	if client.authorized {
		monitors = core.list_monitors()
		hello.monitors = make([]network.Monitor_Message, len(monitors), context.temp_allocator)
		for m, i in monitors {
			hello.monitors[i] = {index = m.index, name = m.name, width = m.width, height = m.height, primary = m.primary}
		}
	}
	defer core.monitors_destroy(monitors)
	server.client_send(client, hello)
}

@(private)
secret_matches :: proc(given, secret: string) -> bool {
	if secret == "" || len(given) != len(secret) {
		return false
	}
	return crypto.compare_constant_time(transmute([]byte)given, transmute([]byte)secret) == 1
}

// "auth" carries the viewing password, which also unlocks remote control, or
// the generated control PIN when viewing itself is open.
@(private)
handle_auth :: proc(client: ^server.Client, given: string) {
	cfg := &app.cfg
	ok := false
	switch {
	case cfg.password != "":
		if secret_matches(given, cfg.password) {
			client.authorized = true
			client.control = cfg.input
			ok = true
		}
	case cfg.input:
		if secret_matches(given, app.pin) {
			client.control = true
			ok = true
		}
	case:
		ok = true // nothing to unlock
	}

	if !ok {
		client.auth_failures += 1
		utils.log_warn("failed auth attempt from %v", client.remote.address)
		time.sleep(AUTH_FAILURE_DELAY) // slows guessing down
		server.client_send_error(client, "auth", "wrong password")
		if client.auth_failures >= AUTH_FAILURE_LIMIT {
			net.shutdown(client.sock, .Both)
		}
		return
	}
	send_hello(client)
}

@(private)
handle_input :: proc(client: ^server.Client, msg: ^network.Signal_Message) {
	if !app.cfg.input || !client.control {
		return
	}
	event, ok := input.event_from_signal(msg.ev, msg.x, msg.y, msg.button, msg.dx, msg.dy, msg.key, msg.down)
	if !ok {
		return
	}
	monitor, found := core.monitor_by_index(stream.session_monitor(&app.session))
	if !found {
		return
	}
	if monitor.width <= 0 || monitor.height <= 0 {
		// No display enumeration (Wayland portal): the captured stream is the monitor.
		info := stream.session_info(&app.session)
		monitor.width = info.source_width
		monitor.height = info.source_height
	}
	input.inject(event, monitor)
}

@(private)
handle_offer :: proc(client: ^server.Client, sdp: string) {
	cfg := &app.cfg
	session := &app.session

	offer := network.parse_offer(sdp)
	if !offer.video.found {
		server.client_send_error(client, "codec", "this browser did not offer H.264")
		return
	}
	if !stream.session_has_viewer(session, client) && cfg.max_viewers > 0 &&
	   stream.session_viewer_count(session) >= cfg.max_viewers {
		server.client_send_error(client, "busy", "too many viewers")
		return
	}
	switch stream.session_start(session) {
	case .Ok:
	case .Denied:
		server.client_send_error(client, "denied", "the host is not sharing its screen")
		stop_if_empty()
		return
	case .Failed:
		server.client_send_error(client, "capture", "the host could not start screen capture")
		stop_if_empty()
		return
	}

	peer, err := network.peer_create({
		bind_address = cfg.bind,
		video_mid    = offer.video.mid,
		video_pt     = offer.video.pt,
		video_fmtp   = stream.session_video_fmtp(session, context.temp_allocator),
		audio        = offer.audio.found && stream.session_audio_available(session),
		audio_mid    = offer.audio.mid,
		audio_pt     = offer.audio.pt,
		audio_fmtp   = "minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1",
	})
	if err != .None {
		utils.log_error("could not create a peer connection: %v", err)
		server.client_send_error(client, "peer", "the host could not create a WebRTC connection")
		stop_if_empty()
		return
	}
	peer.user = client
	peer.on_local_description = on_local_description
	peer.on_local_candidate = on_local_candidate
	peer.on_video_open = on_peer_video_open
	peer.on_pli = on_peer_pli

	if !network.peer_set_remote_offer(peer, sdp) {
		network.peer_close(peer)
		server.client_send_error(client, "peer", "the host rejected the offer")
		stop_if_empty()
		return
	}

	pending, attached := stream.session_attach_peer(session, client, peer, cfg.max_viewers)
	if !attached {
		network.peer_close(peer)
		server.client_send_error(client, "busy", "too many viewers")
		return
	}
	for p in pending {
		network.peer_add_ice_candidate(peer, p.candidate, p.mid)
		delete(p.candidate)
		delete(p.mid)
	}
	delete(pending)
}

@(private)
stop_if_empty :: proc() {
	if stream.session_viewer_count(&app.session) == 0 {
		stream.session_stop(&app.session)
	}
}

// libdatachannel threads below.

@(private)
on_local_description :: proc(peer: ^network.Peer, sdp, type: string) {
	client := (^server.Client)(peer.user)
	if client == nil {
		return
	}
	server.client_send(client, network.Answer_Message{type = type if type != "" else "answer", sdp = sdp})
}

@(private)
on_local_candidate :: proc(peer: ^network.Peer, candidate, mid: string) {
	client := (^server.Client)(peer.user)
	if client == nil {
		return
	}
	server.client_send(client, network.Candidate_Message{type = "candidate", candidate = candidate, mid = mid})
}

@(private)
on_peer_pli :: proc(peer: ^network.Peer) {
	utils.log_debug("PLI from viewer")
	stream.session_request_keyframe(&app.session)
}

@(private)
on_peer_video_open :: proc(peer: ^network.Peer) {
	// Nothing sent before the track opened reached this viewer.
	stream.session_request_keyframe(&app.session, force = true)
}
