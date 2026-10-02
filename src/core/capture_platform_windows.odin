package core

// Windows backends: Desktop Duplication first, GDI (FFmpeg gdigrab) when
// duplication is unavailable (remote sessions, rotated monitors, old drivers).

@(private)
capture_backend_available :: proc(backend: Capture_Backend) -> bool {
	return backend == .DXGI || backend == .GDI
}

@(private)
capture_auto_backends :: proc() -> (order: [4]Capture_Backend, n: int) {
	return {.DXGI, .GDI, .None, .None}, 2
}

@(private)
capture_open_backend :: proc(backend: Capture_Backend, opts: Capture_Options) -> (Capture, Capture_Error) {
	#partial switch backend {
	case .DXGI:
		return capture_open_dxgi(opts)
	case .GDI:
		return capture_open_avdevice(.GDI, opts)
	}
	return {}, .Not_Supported
}

// list_monitors returns the displays that can be captured; free with monitors_destroy.
list_monitors :: proc() -> []Monitor_Info {
	return list_monitors_dxgi()
}
