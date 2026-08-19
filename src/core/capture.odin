package core

// CPU BGRA or GPU D3D11 frame produced by a capture backend.

import d3d11 "vendor:directx/d3d11"

Pixel_Format :: enum {
	BGRA,
}

Frame :: struct {
	width:        int,
	height:       int,
	stride:       int, // bytes per row for CPU frames
	format:       Pixel_Format,
	data:         []byte,
	timestamp_ns: i64,
	gpu:          bool,
	texture:      ^d3d11.ITexture2D, // valid when gpu == true
}

Capture :: struct {
	width:   int,
	height:  int,
	monitor: int,
	impl:    rawptr,
	gpu:     bool,
}

Capture_Error :: enum {
	None,
	Not_Implemented,
	No_Output,
	Device_Lost,
	Timeout,
	Failed,
}

capture_open :: proc(monitor: int, draw_cursor := true, prefer_gpu := true) -> (cap: Capture, err: Capture_Error) {
	when ODIN_OS == .Windows {
		return capture_open_dxgi(monitor, draw_cursor, prefer_gpu)
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
// must be recreated. CPU `out.data` is valid until the next capture_frame or capture_close.
// GPU `out.texture` is owned by capture until the next capture_frame or capture_close.
capture_frame :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	when ODIN_OS == .Windows {
		return capture_frame_dxgi(cap, out)
	} else {
		return .Not_Implemented
	}
}

capture_d3d11 :: proc(cap: ^Capture) -> (device: ^d3d11.IDevice, imm: ^d3d11.IDeviceContext, ok: bool) {
	when ODIN_OS == .Windows {
		return capture_d3d11_dxgi(cap)
	}
	return nil, nil, false
}

capture_uses_gpu :: proc(cap: ^Capture) -> bool {
	return cap.gpu
}

// True when DXGI capture can feed h264_nvenc through D3D11 textures (NVIDIA adapter only).
capture_d3d11_nvenc_ok :: proc(cap: ^Capture) -> bool {
	when ODIN_OS == .Windows {
		return capture_d3d11_nvenc_ok_dxgi(cap)
	}
	return false
}

capture_adapter_vendor :: proc(cap: ^Capture) -> u32 {
	when ODIN_OS == .Windows {
		return capture_adapter_vendor_dxgi(cap)
	}
	return 0
}
