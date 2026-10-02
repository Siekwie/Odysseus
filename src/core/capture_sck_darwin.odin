package core

import "core:c"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

// macOS screen capture through ScreenCaptureKit (macOS 12.3+). The Objective-C
// side lives in src/native/sck_capture.m and is only linked when the build
// passes -define:ODYSSEUS_SCK=true; without it the backend reports
// .Not_Supported like any other missing backend.

ODYSSEUS_SCK :: #config(ODYSSEUS_SCK, false)

when ODYSSEUS_SCK {

foreign import sck_native "system:odysseus_native"

@(private)
SCK_Handle :: distinct rawptr

@(private)
SCK_Frame :: struct {
	width:  c.int,
	height: c.int,
	stride: c.int,
	data:   [^]u8,
}

@(private, default_calling_convention = "c")
foreign sck_native {
	ody_sck_open :: proc(display_index, fps, cursor: c.int, err: [^]u8, err_len: c.int) -> SCK_Handle ---
	ody_sck_size :: proc(s: SCK_Handle, width, height: ^c.int) ---
	ody_sck_read :: proc(s: SCK_Handle, timeout_ms: c.int, out: ^SCK_Frame) -> c.int ---
	ody_sck_close :: proc(s: SCK_Handle) ---
}

Capture_SCK :: struct {
	handle:   SCK_Handle,
	width:    int,
	height:   int,
	previous: Frame, // last delivered frame; its pixels stay valid until the next new one
}

capture_open_sck :: proc(opts: Capture_Options) -> (cap: Capture, err: Capture_Error) {
	ids: [16]u32
	if opts.monitor < 0 || opts.monitor >= display_ids(ids[:]) {
		return {}, .No_Output
	}

	fps := opts.fps if opts.fps > 0 else 30
	reason: [256]u8
	handle := ody_sck_open(c.int(opts.monitor), c.int(fps), 1 if opts.cursor else 0, raw_data(reason[:]), len(reason))
	if handle == nil {
		reason[len(reason) - 1] = 0
		utils.log_info("ScreenCaptureKit: %s", string(cstring(raw_data(reason[:]))))
		return {}, .Failed
	}
	w, h: c.int
	ody_sck_size(handle, &w, &h)
	if w <= 0 || h <= 0 {
		ody_sck_close(handle)
		return {}, .Failed
	}

	impl := new(Capture_SCK)
	impl.handle = handle
	impl.width = int(w)
	impl.height = int(h)

	return Capture{
		width      = int(w),
		height     = int(h),
		self_paced = true,
		impl       = impl,
		frame_proc = capture_frame_sck,
		close_proc = capture_close_sck,
	}, .None
}

@(private)
capture_close_sck :: proc(cap: ^Capture) {
	impl := (^Capture_SCK)(cap.impl)
	ody_sck_close(impl.handle)
	free(impl)
	cap.impl = nil
}

@(private)
capture_frame_sck :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	impl := (^Capture_SCK)(cap.impl)

	raw: SCK_Frame
	switch ody_sck_read(impl.handle, 100, &raw) {
	case 1:
		if int(raw.width) != impl.width || int(raw.height) != impl.height || raw.data == nil {
			out^ = {}
			return .Device_Lost
		}
		frame := Frame{
			width        = impl.width,
			height       = impl.height,
			format       = ffmpeg.pix_fmt("bgra"),
			timestamp_ns = now_ns(),
		}
		frame.planes[0] = raw.data
		frame.strides[0] = raw.stride
		impl.previous = frame
		out^ = frame
		return .None
	case 0:
		// Static screen. The shim only swaps buffers on a new frame, so the
		// previous pixels are still intact and can be encoded again.
		out^ = impl.previous
		return .Timeout
	}
	out^ = {}
	return .Device_Lost
}

} else {

capture_open_sck :: proc(opts: Capture_Options) -> (cap: Capture, err: Capture_Error) {
	return {}, .Not_Supported
}

}
