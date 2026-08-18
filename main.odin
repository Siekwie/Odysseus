package main

import "core:fmt"
import "core:os"

import "src/core"
import "src/network"
import "src/server"
import "src/stream"
import "src/utils"

import ffmpeg "./vendor/ffmpeg"
import rtc    "./vendor/libdatachannel"

App :: struct {
	cfg:     utils.Config,
	session: stream.Session,
}

Peer_User :: struct {
	app:    ^App,
	client: ^server.Client,
}

main :: proc() {
	app := new(App)
	app.cfg = utils.parse_args()
	utils.install_crash_log()
	utils.log_line("Odysseus build 2026-08-18")

	when ffmpeg.STUB_LIBS || rtc.STUB_LIBS {
		fmt.println("C libraries are still stubbed. Run scripts/fetch-libs.ps1 and rebuild.")
	} else {
		found := core.detect_encoders()
		defer delete(found)
		fmt.println("FFmpeg H.264 encoders found:", found)
		network.peer_init_logger(.Warning)
	}

	bind := app.cfg.bind if app.cfg.bind != "" else "0.0.0.0"
	fmt.printf("config: bind=%s port=%d fps=%d %dx%d bitrate=%d kbps encoder=%s monitor=%d cursor=%v max_viewers=%d max_http=%d\n",
		bind, app.cfg.port, app.cfg.fps, app.cfg.width, app.cfg.height, app.cfg.bitrate, app.cfg.encoder, app.cfg.monitor, app.cfg.cursor, app.cfg.max_viewers, app.cfg.max_http)

	hooks := server.Hooks{
		user         = app,
		on_offer     = on_offer,
		on_candidate = on_candidate,
		on_close     = on_close,
		on_keyframe  = on_keyframe,
	}
	if err := server.listen_and_serve(app.cfg, hooks); err != nil {
		fmt.eprintf("server: %v\n", err)
		os.exit(1)
	}
}

on_offer :: proc(user: rawptr, client: ^server.Client, sdp: string) {
	app := (^App)(user)

	if !stream.session_has_viewer(&app.session, client.sock) {
		n := stream.session_viewer_count(&app.session)
		if app.cfg.max_viewers > 0 && n >= app.cfg.max_viewers {
			reject_viewer(app, client, "too many viewers")
			return
		}
	}

	if !stream.session_start(&app.session, app.cfg) {
		fmt.eprintln("could not start capture/encoder")
		reject_viewer(app, client, "could not start capture")
		return
	}

	pt, offer_fmtp, ok := network.h264_select_from_offer(sdp)
	if !ok {
		utils.log_error("offer has no H.264 payload type")
		reject_viewer(app, client, "no H.264 in offer")
		return
	}
	enc_profile := stream.session_h264_profile(&app.session)
	profile := network.h264_answer_profile(offer_fmtp, enc_profile)
	utils.log_line(fmt.tprintf("selected H264 PT=%d fmtp=%s", pt, profile))

	peer, err := network.peer_create(app.cfg.bind, profile, pt)
	if err != .None {
		fmt.eprintln("peer_create:", err)
		reject_viewer(app, client, "could not create peer")
		return
	}
	peer.user = new(Peer_User)
	(^Peer_User)(peer.user).app = app
	(^Peer_User)(peer.user).client = client
	peer.on_local_description = on_local_description
	peer.on_local_candidate = on_local_candidate
	peer.on_pli = on_pli

	if network.peer_set_remote_description(peer, sdp, "offer") < 0 {
		fmt.eprintln("set remote offer failed")
		close_peer(peer)
		stop_if_empty(app)
		return
	}

	pending, attached := stream.session_attach_peer(&app.session, client.sock, peer, app.cfg.max_viewers)
	defer delete(pending)
	if !attached {
		close_peer(peer)
		reject_viewer(app, client, "too many viewers")
		return
	}
	for p in pending {
		if p.candidate != "" {
			network.peer_add_ice_candidate(peer, p.candidate, p.mid)
		}
		delete(p.candidate)
		delete(p.mid)
	}
	stream.session_request_keyframe(&app.session)
}

on_candidate :: proc(user: rawptr, client: ^server.Client, candidate, mid: string) {
	app := (^App)(user)
	if peer := stream.session_peer_for(&app.session, client.sock); peer != nil {
		if candidate != "" {
			network.peer_add_ice_candidate(peer, candidate, mid)
		}
		return
	}
	stream.session_queue_ice(&app.session, client.sock, candidate, mid, app.cfg.max_viewers)
}

on_close :: proc(user: rawptr, client: ^server.Client) {
	app := (^App)(user)
	remaining, _ := stream.session_remove_viewer(&app.session, client.sock)
	if remaining == 0 {
		stream.session_stop(&app.session)
	}
}

on_keyframe :: proc(user: rawptr, client: ^server.Client) {
	app := (^App)(user)
	_ = client
	stream.session_request_keyframe(&app.session)
}

on_local_description :: proc(peer: ^network.Peer, sdp, type: string) {
	ctx := (^Peer_User)(peer.user)
	if ctx == nil || ctx.client == nil {
		return
	}
	kind := type if type != "" else "answer"
	server.client_send_json(ctx.client, network.Signal_Message{type = kind, sdp = sdp})
}

on_local_candidate :: proc(peer: ^network.Peer, candidate, mid: string) {
	ctx := (^Peer_User)(peer.user)
	if ctx == nil || ctx.client == nil {
		return
	}
	server.client_send_json(ctx.client, network.Signal_Message{
		type      = "candidate",
		candidate = candidate,
		mid       = mid,
	})
}

on_pli :: proc(peer: ^network.Peer) {
	ctx := (^Peer_User)(peer.user)
	if ctx != nil {
		stream.session_request_keyframe(&ctx.app.session)
	}
}

@(private)
stop_if_empty :: proc(app: ^App) {
	if stream.session_viewer_count(&app.session) == 0 {
		stream.session_stop(&app.session)
	}
}

// reject_viewer sends a signaling error and stops the session if this leaves no viewers.
@(private)
reject_viewer :: proc(app: ^App, client: ^server.Client, message: string) {
	server.client_send_json(client, network.Signal_Message{
		type    = "error",
		message = message,
	})
	stop_if_empty(app)
}

// close_peer releases a peer's user pointer and connection.
@(private)
close_peer :: proc(peer: ^network.Peer) {
	if peer.user != nil {
		free(peer.user)
		peer.user = nil
	}
	network.peer_close(peer)
}
