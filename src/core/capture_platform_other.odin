#+build !windows
#+build !linux
#+build !darwin
package core

// Platforms without a native backend (the BSDs): X11 through FFmpeg only.

import "core:strings"

@(private)
capture_backend_available :: proc(backend: Capture_Backend) -> bool {
	return backend == .X11
}

@(private)
capture_auto_backends :: proc() -> (order: [4]Capture_Backend, n: int) {
	return {.X11, .None, .None, .None}, 1
}

@(private)
capture_open_backend :: proc(backend: Capture_Backend, opts: Capture_Options) -> (Capture, Capture_Error) {
	if backend == .X11 {
		return capture_open_avdevice(.X11, opts)
	}
	return {}, .Not_Supported
}

// list_monitors has no display enumeration here; the whole X screen is one entry
// whose size x11grab determines.
list_monitors :: proc() -> []Monitor_Info {
	list := make([]Monitor_Info, 1)
	list[0] = {index = 0, name = strings.clone("screen"), primary = true}
	return list
}
