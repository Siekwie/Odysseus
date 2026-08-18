package utils

// Planned configuration from the README. Flags use Odin style: -port:8080

Config :: struct {
	port:        int    `args:"name=port" usage:"HTTP listen port."`,
	bind:        string `args:"name=bind" usage:"Listen and ICE bind address. Empty or 0.0.0.0 is all IPv4 interfaces."`,
	fps:         int    `args:"name=fps" usage:"Capture and encode frames per second."`,
	width:       int    `args:"name=width" usage:"Output width. 0 keeps the capture size."`,
	height:      int    `args:"name=height" usage:"Output height. 0 keeps the capture size."`,
	bitrate:     int    `args:"name=bitrate" usage:"Target video bitrate in kbps."`,
	encoder:     string `args:"name=encoder" usage:"FFmpeg encoder name, e.g. h264_nvenc or libx264."`,
	monitor:     int    `args:"name=monitor" usage:"Monitor index to capture. 0 is the primary."`,
	max_http:    int    `args:"name=max-http" usage:"Max concurrent HTTP connections. 0 is unlimited."`,
	max_viewers: int    `args:"name=max-viewers" usage:"Max concurrent WebRTC viewers. 0 is unlimited."`,
	cursor:      bool   `args:"name=cursor" usage:"Draw the mouse cursor into the stream."`,
}

config_default :: proc() -> Config {
	return {
		port        = 8080,
		bind        = "",
		fps         = 30,
		width       = 1920,
		height      = 1080,
		bitrate     = 8000,
		encoder     = "h264",
		monitor     = 0,
		max_http    = 64,
		max_viewers = 8,
		cursor      = true,
	}
}
