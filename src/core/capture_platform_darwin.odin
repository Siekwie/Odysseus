package core

import "core:fmt"
import "core:strings"

foreign import cg "system:CoreGraphics.framework"

// macOS backends: AVFoundation through FFmpeg by default; ScreenCaptureKit
// (macOS 12.3+, also carries system audio) when asked for with -capture.

CG_Point :: struct {
	x, y: f64,
}

CG_Size :: struct {
	width, height: f64,
}

CG_Rect :: struct {
	origin: CG_Point,
	size:   CG_Size,
}

@(default_calling_convention = "c")
foreign cg {
	CGMainDisplayID :: proc() -> u32 ---
	CGGetActiveDisplayList :: proc(max_displays: u32, displays: [^]u32, count: ^u32) -> i32 ---
	CGDisplayBounds :: proc(display: u32) -> CG_Rect ---
	CGDisplayPixelsWide :: proc(display: u32) -> uint ---
	CGDisplayPixelsHigh :: proc(display: u32) -> uint ---
}

@(private)
capture_backend_available :: proc(backend: Capture_Backend) -> bool {
	return backend == .AVFoundation || backend == .ScreenCaptureKit
}

@(private)
capture_auto_backends :: proc() -> (order: [4]Capture_Backend, n: int) {
	return {.AVFoundation, .ScreenCaptureKit, .None, .None}, 2
}

@(private)
capture_open_backend :: proc(backend: Capture_Backend, opts: Capture_Options) -> (Capture, Capture_Error) {
	#partial switch backend {
	case .AVFoundation:
		return capture_open_avdevice(.AVFoundation, opts)
	case .ScreenCaptureKit:
		return capture_open_sck(opts)
	}
	return {}, .Not_Supported
}

// Active displays in CoreGraphics order, which is also the order of
// AVFoundation's "Capture screen N" devices and of SCShareableContent.
display_ids :: proc(ids: []u32) -> int {
	count: u32
	if CGGetActiveDisplayList(u32(len(ids)), raw_data(ids), &count) != 0 {
		return 0
	}
	return int(count)
}

// list_monitors returns the displays that can be captured; free with monitors_destroy.
// Positions are in points (global display coordinates), sizes in pixels.
list_monitors :: proc() -> []Monitor_Info {
	ids: [16]u32
	n := display_ids(ids[:])
	main := CGMainDisplayID()
	list := make([]Monitor_Info, n)
	for id, i in ids[:n] {
		bounds := CGDisplayBounds(id)
		list[i] = {
			index   = i,
			name    = strings.clone(fmt.tprintf("display %d", id)),
			x       = int(bounds.origin.x),
			y       = int(bounds.origin.y),
			width   = int(CGDisplayPixelsWide(id)),
			height  = int(CGDisplayPixelsHigh(id)),
			primary = id == main,
		}
	}
	return list
}
