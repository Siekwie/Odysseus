package core

import "core:c"
import "core:dynlib"
import "core:strings"
import "core:sync"

// Xlib, XRandR and XTest loaded at run time. They are optional: a Wayland
// session without XWayland still runs (PipeWire capture, portal input), and
// the build needs no X11 development packages.

X11_Display :: distinct rawptr
X11_Window  :: c.ulong

X11_Monitor :: struct {
	name:      c.ulong, // Atom
	primary:   b32,
	automatic: b32,
	noutput:   i32,
	x:         i32,
	y:         i32,
	width:     i32,
	height:    i32,
	mwidth:    i32,
	mheight:   i32,
	outputs:   rawptr,
}

X11_Lib :: struct {
	XInitThreads:       proc "c" () -> c.int,
	XOpenDisplay:       proc "c" (name: cstring) -> X11_Display,
	XCloseDisplay:      proc "c" (dpy: X11_Display) -> c.int,
	XDefaultRootWindow: proc "c" (dpy: X11_Display) -> X11_Window,
	XDefaultScreen:     proc "c" (dpy: X11_Display) -> c.int,
	XDisplayWidth:      proc "c" (dpy: X11_Display, screen: c.int) -> c.int,
	XDisplayHeight:     proc "c" (dpy: X11_Display, screen: c.int) -> c.int,
	XGetAtomName:       proc "c" (dpy: X11_Display, atom: c.ulong) -> cstring,
	XFree:              proc "c" (data: rawptr) -> c.int,
	XFlush:             proc "c" (dpy: X11_Display) -> c.int,
	__handle:           dynlib.Library,
}

Xrandr_Lib :: struct {
	XRRGetMonitors:  proc "c" (dpy: X11_Display, window: X11_Window, get_active: b32, nmonitors: ^c.int) -> [^]X11_Monitor,
	XRRFreeMonitors: proc "c" (monitors: [^]X11_Monitor),
	__handle:        dynlib.Library,
}

Xtst_Lib :: struct {
	XTestFakeMotionEvent: proc "c" (dpy: X11_Display, screen: c.int, x, y: c.int, delay: c.ulong) -> c.int,
	XTestFakeButtonEvent: proc "c" (dpy: X11_Display, button: c.uint, is_press: b32, delay: c.ulong) -> c.int,
	XTestFakeKeyEvent:    proc "c" (dpy: X11_Display, keycode: c.uint, is_press: b32, delay: c.ulong) -> c.int,
	XTestQueryExtension:  proc "c" (dpy: X11_Display, event_base, error_base, major, minor: ^c.int) -> b32,
	__handle:             dynlib.Library,
}

x11:    X11_Lib
xrandr: Xrandr_Lib
xtst:   Xtst_Lib

@(private)
_x11_once: sync.Once
@(private)
_x11_ok, _xrandr_ok, _xtst_ok: bool

@(private)
x11_load_all :: proc() {
	_, _x11_ok = dynlib.initialize_symbols(&x11, "libX11.so.6")
	if !_x11_ok {
		return
	}
	x11.XInitThreads()
	_, _xrandr_ok = dynlib.initialize_symbols(&xrandr, "libXrandr.so.2")
	_, _xtst_ok = dynlib.initialize_symbols(&xtst, "libXtst.so.6")
}

// x11_available reports whether libX11 could be loaded.
x11_available :: proc() -> bool {
	sync.once_do(&_x11_once, x11_load_all)
	return _x11_ok
}

xrandr_available :: proc() -> bool {
	return x11_available() && _xrandr_ok
}

xtst_available :: proc() -> bool {
	return x11_available() && _xtst_ok
}

// x11_open connects to $DISPLAY; nil when there is no X server to talk to.
x11_open :: proc() -> X11_Display {
	if !x11_available() {
		return nil
	}
	return x11.XOpenDisplay(nil)
}

// Monitors as XRandR reports them, falling back to the whole X screen.
@(private)
list_monitors_x11 :: proc() -> []Monitor_Info {
	dpy := x11_open()
	if dpy == nil {
		return nil
	}
	defer x11.XCloseDisplay(dpy)

	list := make([dynamic]Monitor_Info)
	if xrandr_available() {
		count: c.int
		monitors := xrandr.XRRGetMonitors(dpy, x11.XDefaultRootWindow(dpy), true, &count)
		if monitors != nil {
			defer xrandr.XRRFreeMonitors(monitors)
			// Primary first, so that index 0 is the primary monitor like on the other platforms.
			for pass in 0 ..< 2 {
				for m in monitors[:count] {
					if bool(m.primary) != (pass == 0) {
						continue
					}
					name: string
					if atom_name := x11.XGetAtomName(dpy, m.name); atom_name != nil {
						name = strings.clone(string(atom_name))
						x11.XFree(rawptr(atom_name))
					} else {
						name = strings.clone("monitor")
					}
					append(&list, Monitor_Info{
						index   = len(list),
						name    = name,
						x       = int(m.x),
						y       = int(m.y),
						width   = int(m.width),
						height  = int(m.height),
						primary = bool(m.primary),
					})
				}
			}
		}
	}
	if len(list) > 0 && !list[0].primary {
		// No output is marked primary (common on virtual servers): the first one is.
		list[0].primary = true
	}
	if len(list) == 0 {
		screen := x11.XDefaultScreen(dpy)
		append(&list, Monitor_Info{
			index   = 0,
			name    = strings.clone("screen"),
			width   = int(x11.XDisplayWidth(dpy, screen)),
			height  = int(x11.XDisplayHeight(dpy, screen)),
			primary = true,
		})
	}
	return list[:]
}
