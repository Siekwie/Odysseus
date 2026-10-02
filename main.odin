package main

import "core:crypto"
import "core:fmt"
import "core:os"

import "src/core"
import "src/input"
import "src/network"
import "src/server"
import "src/stream"
import "src/utils"

import ffmpeg "./vendor/ffmpeg"

App :: struct {
	cfg:     utils.Config,
	session: stream.Session,
	pin:     string, // remote-control PIN, generated when -input is set without -password
}

app: App

main :: proc() {
	app.cfg = utils.parse_args()
	cfg := &app.cfg

	if cfg.version {
		fmt.println("odysseus", utils.VERSION)
		return
	}

	utils.log_set_verbose(cfg.verbose)
	listing := cfg.list_monitors || cfg.list_encoders
	if !listing {
		utils.log_open(cfg.log)
	}
	utils.install_crash_handler()

	v := ffmpeg.versions()
	if !ffmpeg.supported() {
		utils.log_error("unsupported FFmpeg (libavutil %d, libavformat %d); Odysseus needs FFmpeg 6 to 9", v.avutil, v.avformat)
		os.exit(1)
	}
	ffmpeg.av_log_set_level(ffmpeg.AV_LOG_INFO if cfg.verbose else ffmpeg.AV_LOG_ERROR)

	if cfg.list_monitors {
		print_monitors()
		return
	}
	if cfg.list_encoders {
		print_encoders()
		return
	}

	utils.log_info("Odysseus %s (libavcodec %d, libavutil %d)", utils.VERSION, v.avcodec, v.avutil)
	network.rtc_init(cfg.verbose)

	if cfg.input {
		if input.init() {
			if cfg.password == "" {
				app.pin = generate_pin()
			}
		} else {
			utils.log_warn("remote input is not available on this system; -input ignored")
			cfg.input = false
		}
	}

	stream.session_init(&app.session, cfg^, on_stream_change, on_stream_ended)
	utils.install_shutdown_handler(on_shutdown)

	print_banner()

	hooks := server.Hooks{
		on_open    = on_client_open,
		on_message = on_client_message,
		on_close   = on_client_close,
		status     = on_status,
	}
	if err := server.listen_and_serve(cfg^, hooks); err != nil {
		utils.log_error("could not listen on port %d: %v", cfg.port, err)
		os.exit(1)
	}
}

// Runs once when the process is asked to stop.
on_shutdown :: proc() {
	utils.log_info("shutting down")
	server.shutdown()
	stream.session_stop(&app.session)
	if app.cfg.input {
		input.shutdown()
	}
	network.rtc_cleanup()
	utils.log_close()
}

@(private)
generate_pin :: proc() -> string {
	raw: [4]byte
	crypto.rand_bytes(raw[:])
	n := (u32(raw[0]) | u32(raw[1]) << 8 | u32(raw[2]) << 16 | u32(raw[3]) << 24) % 1_000_000
	return fmt.aprintf("%06d", n)
}

@(private)
print_monitors :: proc() {
	monitors := core.list_monitors()
	defer core.monitors_destroy(monitors)
	if len(monitors) == 0 {
		fmt.println("no monitors found")
		return
	}
	for m in monitors {
		size := fmt.tprintf("%dx%d", m.width, m.height)
		fmt.printf("%d  %-16s %-11s at %d,%d%s\n", m.index, m.name, size, m.x, m.y, "  (primary)" if m.primary else "")
	}
}

@(private)
print_encoders :: proc() {
	working := core.probe_encoders()
	defer delete(working)
	for name in core.AUTO_ENCODERS {
		state := "not in this FFmpeg build"
		if core.encoder_exists(name) {
			state = "present, but does not open on this machine"
			for w in working {
				if w == name {
					state = "ok"
				}
			}
		}
		fmt.printf("%-20s %s\n", name, state)
	}
	if len(working) > 0 {
		fmt.printf("\n-encoder:h264 will use %s\n", working[0])
	} else {
		fmt.println("\nno usable H.264 encoder found")
	}
}

@(private)
print_banner :: proc() {
	cfg := &app.cfg
	w, h := cfg.width, cfg.height
	utils.log_info("config: %d fps, %d kbps, size %s, encoder %s, capture %s, monitor %d, cursor %v, audio %v, input %v",
		cfg.fps, cfg.bitrate,
		fmt.tprintf("%dx%d", w, h) if w > 0 || h > 0 else "native",
		cfg.encoder, cfg.capture, cfg.monitor, cfg.cursor, cfg.audio, cfg.input)

	switch cfg.bind {
	case "", "0.0.0.0", "::", "[::]":
		addresses: [16][4]u8
		count := utils.lan_addresses(addresses[:])
		for ip in addresses[:count] {
			utils.log_info("open http://%d.%d.%d.%d:%d/odysseus", ip[0], ip[1], ip[2], ip[3], cfg.port)
		}
		if count == 0 {
			utils.log_info("open http://localhost:%d/odysseus", cfg.port)
		}
	case:
		utils.log_info("open http://%s:%d/odysseus", cfg.bind, cfg.port)
	}

	if cfg.password != "" {
		utils.log_info("viewers need the password%s", " (it also unlocks remote control)" if cfg.input else "")
	} else if cfg.input {
		utils.log_info("remote control PIN: %s", app.pin)
	}
	free_all(context.temp_allocator)
}
