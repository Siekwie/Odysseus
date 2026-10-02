package utils

import "core:fmt"

VERSION :: "1.0.0"

MAX_DIMENSION :: 8192 // largest encoded width or height

// Command-line configuration. Flags use Odin style: -port:8080

Config :: struct {
	port:          int    `args:"name=port" usage:"HTTP listen port."`,
	bind:          string `args:"name=bind" usage:"Listen and ICE bind address. Empty or 0.0.0.0 is all IPv4 interfaces."`,
	fps:           int    `args:"name=fps" usage:"Capture and encode frames per second."`,
	width:         int    `args:"name=width" usage:"Output width. 0 keeps the capture size (or follows -height)."`,
	height:        int    `args:"name=height" usage:"Output height. 0 keeps the capture size (or follows -width)."`,
	bitrate:       int    `args:"name=bitrate" usage:"Target video bitrate in kbps."`,
	encoder:       string `args:"name=encoder" usage:"FFmpeg encoder name, e.g. h264_nvenc or libx264. 'h264' picks the best one that works."`,
	capture:       string `args:"name=capture" usage:"Capture backend: auto, dxgi, gdigrab, x11, pipewire, avfoundation, screencapturekit."`,
	monitor:       int    `args:"name=monitor" usage:"Monitor index to capture. 0 is the first one listed by -list-monitors."`,
	cursor:        bool   `args:"name=cursor" usage:"Draw the mouse cursor into the stream."`,
	audio:         bool   `args:"name=audio" usage:"Stream system audio (Opus)."`,
	audio_device:  string `args:"name=audio-device" usage:"Audio capture device name (substring). Empty picks the system output loopback."`,
	audio_bitrate: int    `args:"name=audio-bitrate" usage:"Audio bitrate in kbps."`,
	input:         bool   `args:"name=input" usage:"Allow viewers to control mouse and keyboard (protected by -password or a generated PIN)."`,
	password:      string `args:"name=password" usage:"Require this password to view the stream."`,
	host_name:     string `args:"name=host-name" usage:"Extra host names viewers may use in the URL, comma separated (IP addresses, localhost and this machine's name always work)."`,
	max_http:      int    `args:"name=max-http" usage:"Max concurrent HTTP connections. 0 is unlimited."`,
	max_viewers:   int    `args:"name=max-viewers" usage:"Max concurrent WebRTC viewers. 0 is unlimited."`,
	log:           string `args:"name=log" usage:"Log file path. Empty writes odysseus.log next to the executable; 'none' disables it."`,
	verbose:       bool   `args:"name=verbose" usage:"Log debug output, including FFmpeg and WebRTC library messages."`,
	list_monitors: bool   `args:"name=list-monitors" usage:"Print the monitors that can be captured and exit."`,
	list_encoders: bool   `args:"name=list-encoders" usage:"Print the H.264 encoders that work on this machine and exit."`,
	version:       bool   `args:"name=version" usage:"Print the version and exit."`,
}

config_default :: proc() -> Config {
	return {
		port          = 8080,
		bind          = "",
		fps           = 30,
		width         = 0,
		height        = 0,
		bitrate       = 8000,
		encoder       = "h264",
		capture       = "auto",
		monitor       = 0,
		cursor        = true,
		audio         = true,
		audio_bitrate = 128,
		max_http      = 64,
		max_viewers   = 8,
	}
}

// config_validate returns a message describing the first invalid setting, or "" when the config is usable.
config_validate :: proc(cfg: ^Config) -> string {
	if cfg.port < 1 || cfg.port > 65535 {
		return fmt.tprintf("-port must be between 1 and 65535 (got %d)", cfg.port)
	}
	if cfg.fps < 1 || cfg.fps > 240 {
		return fmt.tprintf("-fps must be between 1 and 240 (got %d)", cfg.fps)
	}
	if cfg.bitrate < 100 || cfg.bitrate > 500_000 {
		return fmt.tprintf("-bitrate must be between 100 and 500000 kbps (got %d)", cfg.bitrate)
	}
	if cfg.audio_bitrate < 16 || cfg.audio_bitrate > 510 {
		return fmt.tprintf("-audio-bitrate must be between 16 and 510 kbps (got %d)", cfg.audio_bitrate)
	}
	if cfg.width < 0 || cfg.height < 0 || cfg.width > MAX_DIMENSION || cfg.height > MAX_DIMENSION {
		return fmt.tprintf("-width and -height must be between 0 and 8192 (got %dx%d)", cfg.width, cfg.height)
	}
	if (cfg.width != 0 && cfg.width < 64) || (cfg.height != 0 && cfg.height < 64) {
		return fmt.tprintf("-width and -height must be 0 or at least 64 (got %dx%d)", cfg.width, cfg.height)
	}
	if cfg.monitor < 0 {
		return fmt.tprintf("-monitor must not be negative (got %d)", cfg.monitor)
	}
	if cfg.max_http < 0 || cfg.max_viewers < 0 {
		return "-max-http and -max-viewers must not be negative"
	}
	switch cfg.capture {
	case "", "auto", "dxgi", "gdigrab", "x11", "pipewire", "avfoundation", "screencapturekit":
	case:
		return fmt.tprintf("unknown -capture backend '%s'", cfg.capture)
	}
	if cfg.capture == "" {
		cfg.capture = "auto"
	}
	if cfg.encoder == "" {
		cfg.encoder = "h264"
	}
	return ""
}

// scaled_size resolves the configured output size against the captured size:
// 0x0 keeps the source, one zero dimension follows the aspect ratio, and the
// result is even (4:2:0 chroma needs even dimensions).
scaled_size :: proc(cfg_w, cfg_h, src_w, src_h: int) -> (w, h: int) {
	// Round what was asked for to even first, so the derived side follows the rounded value.
	w = max(cfg_w &~ 1, 2) if cfg_w > 0 else 0
	h = max(cfg_h &~ 1, 2) if cfg_h > 0 else 0
	if src_w > 0 && src_h > 0 {
		switch {
		case w == 0 && h == 0:
			w, h = src_w, src_h
		case w == 0:
			w = (h * src_w + src_h / 2) / src_h
		case h == 0:
			h = (w * src_h + src_w / 2) / src_w
		}
		// A derived side can leave the supported range on extreme aspect ratios; shrink to fit.
		if w > MAX_DIMENSION {
			h = h * MAX_DIMENSION / w
			w = MAX_DIMENSION
		}
		if h > MAX_DIMENSION {
			w = w * MAX_DIMENSION / h
			h = MAX_DIMENSION
		}
	}
	w = max(w &~ 1, 2)
	h = max(h &~ 1, 2)
	return
}

// Loopback and link-local (169.254/16) addresses are not reachable from other devices.
lan_address_usable :: proc(ip: [4]u8) -> bool {
	return ip[0] != 127 && !(ip[0] == 169 && ip[1] == 254) && ip != {0, 0, 0, 0}
}
