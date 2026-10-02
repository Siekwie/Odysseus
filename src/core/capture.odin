package core

import "core:time"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

// Screen capture front end. Each platform contributes one or more backends
// (see capture_*.odin); capture_open tries them in order of preference.

// Frame is one captured desktop image. CPU frames describe their pixels with
// an FFmpeg pixel format plus plane pointers so any backend layout (BGRA,
// bottom-up BMP, NV12, ...) can be fed to swscale without a copy. GPU frames
// carry a texture instead and leave the planes empty.
Frame :: struct {
	width:        int,
	height:       int,
	format:       ffmpeg.Pixel_Format,
	planes:       [4][^]u8,
	strides:      [4]i32, // negative for bottom-up images
	timestamp_ns: i64,    // monotonic capture time
	texture:      rawptr, // ^d3d11.ITexture2D when the capture runs on the GPU
}

Capture_Backend :: enum {
	None,
	DXGI,             // Windows Desktop Duplication
	GDI,              // Windows GDI via FFmpeg gdigrab
	X11,              // X11 via FFmpeg x11grab
	PipeWire,         // Wayland / X11 via xdg-desktop-portal + PipeWire
	AVFoundation,     // macOS via FFmpeg avfoundation
	ScreenCaptureKit, // macOS 12.3+
}

BACKEND_NAME := [Capture_Backend]string {
	.None             = "none",
	.DXGI             = "dxgi",
	.GDI              = "gdigrab",
	.X11              = "x11",
	.PipeWire         = "pipewire",
	.AVFoundation     = "avfoundation",
	.ScreenCaptureKit = "screencapturekit",
}

Capture_Error :: enum {
	None,
	Not_Supported, // backend does not exist on this platform or cannot handle this setup
	No_Output,     // monitor index out of range
	Device_Lost,   // backend must be reopened (mode change, secure desktop, ...)
	Timeout,       // no new frame yet
	Denied,        // the user refused or ended the share (desktop portal); do not retry on your own
	Failed,
}

Capture_Options :: struct {
	backend:    string, // "auto" or one of BACKEND_NAME
	monitor:    int,
	cursor:     bool,
	fps:        int,
	prefer_gpu: bool,   // hand out GPU textures when the backend can
	input:      bool,   // remote input is enabled (PipeWire then asks the portal for a RemoteDesktop session)
}

Capture :: struct {
	width:      int,
	height:     int,
	monitor:    int,
	backend:    Capture_Backend,
	gpu:        bool, // frames are GPU textures
	self_paced: bool, // capture_frame blocks or polls at the device frame rate
	impl:       rawptr,
	frame_proc: proc(cap: ^Capture, out: ^Frame) -> Capture_Error,
	close_proc: proc(cap: ^Capture),
}

// Monitor_Info describes one capturable display in virtual-desktop coordinates.
Monitor_Info :: struct {
	index:   int,
	name:    string,
	x:       int,
	y:       int,
	width:   int,
	height:  int,
	primary: bool,
}

monitors_destroy :: proc(monitors: []Monitor_Info) {
	for m in monitors {
		delete(m.name)
	}
	delete(monitors)
}

// monitor_by_index returns a copy of one entry of list_monitors; the name is not owned.
monitor_by_index :: proc(index: int) -> (info: Monitor_Info, ok: bool) {
	monitors := list_monitors()
	defer monitors_destroy(monitors)
	if index < 0 || index >= len(monitors) {
		return {}, false
	}
	info = monitors[index]
	info.name = ""
	return info, true
}

now_ns :: proc() -> i64 {
	return time.tick_now()._nsec
}

// capture_open opens the requested backend, or the first working one for "auto".
capture_open :: proc(opts: Capture_Options) -> (cap: Capture, err: Capture_Error) {
	order, count := capture_backend_order(opts)
	if count == 0 {
		utils.log_error("capture backend '%s' is not available on this platform", opts.backend)
		return {}, .Not_Supported
	}
	err = .Not_Supported
	for backend in order[:count] {
		cap, err = capture_open_backend(backend, opts)
		if err == .None {
			cap.backend = backend
			cap.monitor = opts.monitor
			return cap, .None
		}
		utils.log_debug("capture backend %s: %v", BACKEND_NAME[backend], err)
		if err == .Denied {
			// Falling back to another backend would capture what the user just refused to share.
			break
		}
	}
	return {}, err
}

capture_close :: proc(cap: ^Capture) {
	if cap.close_proc != nil && cap.impl != nil {
		cap.close_proc(cap)
	}
	cap^ = {}
}

// capture_frame grabs the next desktop frame into `out`. The frame's pixels
// (or texture) stay valid until the next capture_frame or capture_close on
// the same capture. On .Timeout `out` holds the previous frame again when the
// backend still has it, and is zeroed (width == 0) otherwise.
capture_frame :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	if cap.frame_proc == nil || cap.impl == nil {
		return .Failed
	}
	return cap.frame_proc(cap, out)
}

@(private)
capture_backend_order :: proc(opts: Capture_Options) -> (order: [4]Capture_Backend, n: int) {
	want := opts.backend if opts.backend != "" else "auto"
	if want == "auto" {
		return capture_auto_backends()
	}
	for name, backend in BACKEND_NAME {
		if name == want && backend != .None && capture_backend_available(backend) {
			order[0] = backend
			return order, 1
		}
	}
	return order, 0
}
