package core

import "core:os"
import "core:strings"

// Linux backends: PipeWire through the desktop portal (Wayland, and X11
// desktops that ship a portal) and x11grab for plain X11.

@(private)
capture_backend_available :: proc(backend: Capture_Backend) -> bool {
	return backend == .X11 || backend == .PipeWire
}

// is_wayland_session reports whether the desktop session is a Wayland one.
is_wayland_session :: proc() -> bool {
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
		return true
	}
	return os.get_env("XDG_SESSION_TYPE", context.temp_allocator) == "wayland"
}

@(private)
capture_auto_backends :: proc() -> (order: [4]Capture_Backend, n: int) {
	// x11grab only sees XWayland windows under Wayland, so the portal goes first there.
	if is_wayland_session() {
		return {.PipeWire, .X11, .None, .None}, 2
	}
	return {.X11, .PipeWire, .None, .None}, 2
}

@(private)
capture_open_backend :: proc(backend: Capture_Backend, opts: Capture_Options) -> (Capture, Capture_Error) {
	#partial switch backend {
	case .X11:
		if os.get_env("DISPLAY", context.temp_allocator) == "" {
			return {}, .Not_Supported
		}
		return capture_open_avdevice(.X11, opts)
	case .PipeWire:
		return capture_open_pipewire(opts)
	}
	return {}, .Not_Supported
}

// list_monitors returns the displays that can be captured; free with monitors_destroy.
// On Wayland without XWayland the portal dialog picks the screen, so a single
// placeholder entry is reported.
list_monitors :: proc() -> []Monitor_Info {
	if list := list_monitors_x11(); len(list) > 0 {
		return list
	}
	list := make([]Monitor_Info, 1)
	list[0] = {index = 0, name = strings.clone("portal"), primary = true}
	return list
}
