package core

// CPU BGRA frame produced by a capture backend. Encoder converts this to YUV.

Pixel_Format :: enum {
	BGRA,
}

Frame :: struct {
	width:        int,
	height:       int,
	stride:       int, // bytes per row, may be > width * 4
	format:       Pixel_Format,
	data:         []byte,
	timestamp_ns: i64,
}

Capture :: struct {
	width:   int,
	height:  int,
	monitor: int,
	impl:    rawptr,
}

Capture_Error :: enum {
	None,
	Not_Implemented,
	No_Output,
	Device_Lost,
	Timeout,
	Failed,
}

capture_open :: proc(monitor: int, draw_cursor := true) -> (cap: Capture, err: Capture_Error) {
	when ODIN_OS == .Windows {
		return capture_open_dxgi(monitor, draw_cursor)
	} else {
		return {}, .Not_Implemented
	}
}

capture_close :: proc(cap: ^Capture) {
	when ODIN_OS == .Windows {
		capture_close_dxgi(cap)
	}
}

// Grab the next desktop frame into `out`. Returns .Device_Lost if DXGI duplication
// must be recreated. `out.data` is valid until the next capture_frame or capture_close.
capture_frame :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	when ODIN_OS == .Windows {
		return capture_frame_dxgi(cap, out)
	} else {
		return .Not_Implemented
	}
}
