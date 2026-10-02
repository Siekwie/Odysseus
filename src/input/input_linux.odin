#+build linux
package input

import "../core"
import "../utils"

// Two ways in: the RemoteDesktop portal when its session is running (the only
// way on Wayland), otherwise the XTest extension of the X server.

// Linux evdev button codes, indexed by MouseEvent.button.
@(private = "file")
EVDEV_BUTTONS := [BUTTON_COUNT]i32{0x110, 0x112, 0x111, 0x113, 0x114} // left, middle, right, side (back), extra (forward)

// X11 pointer button numbers, indexed by MouseEvent.button.
@(private = "file")
X_BUTTONS := [BUTTON_COUNT]u32{1, 2, 3, 8, 9}

// X11 reports wheel notches as clicks of buttons 4/5 (vertical) and 6/7 (horizontal).
@(private = "file")
X_WHEEL_UP, X_WHEEL_DOWN, X_WHEEL_LEFT, X_WHEEL_RIGHT :: 4, 5, 6, 7

@(private = "file")
dpy: core.X11_Display

@(private)
backend_init :: proc() -> bool {
	if core.xtst_available() {
		dpy = core.x11_open()
		if dpy != nil {
			event_base, error_base, major, minor: i32
			if !core.xtst.XTestQueryExtension(dpy, &event_base, &error_base, &major, &minor) {
				core.x11.XCloseDisplay(dpy)
				dpy = nil
			}
		}
	}
	if dpy != nil {
		return true
	}
	// A Wayland session brings its portal session up with the capture, which
	// happens after this runs.
	if core.is_wayland_session() {
		utils.log_info("remote input: waiting for the portal session (no XTest on this display)")
		return true
	}
	utils.log_warn("remote input unavailable: no X server with the XTest extension")
	return false
}

@(private)
backend_shutdown :: proc() {
	if dpy != nil {
		core.x11.XCloseDisplay(dpy)
		dpy = nil
	}
}

@(private)
backend_move :: proc(monitor: core.Monitor_Info, x, y: f64) {
	if core.portal_remote_active() {
		// The portal positions the pointer inside the captured stream.
		core.portal_pointer_motion(x * f64(max(monitor.width - 1, 0)), y * f64(max(monitor.height - 1, 0)))
		return
	}
	if dpy == nil {
		return
	}
	px, py := monitor_point(monitor, x, y)
	core.xtst.XTestFakeMotionEvent(dpy, -1, i32(px), i32(py), 0) // -1: the screen the pointer is on
	core.x11.XFlush(dpy)
}

@(private)
backend_button :: proc(button: int, down: bool) {
	if button < 0 || button >= BUTTON_COUNT {
		return
	}
	if core.portal_remote_active() {
		core.portal_pointer_button(EVDEV_BUTTONS[button], down)
		return
	}
	if dpy == nil {
		return
	}
	core.xtst.XTestFakeButtonEvent(dpy, X_BUTTONS[button], b32(down), 0)
	core.x11.XFlush(dpy)
}

@(private)
backend_wheel :: proc(dx, dy: f64) {
	if core.portal_remote_active() {
		core.portal_pointer_axis(dx, dy)
		return
	}
	if dpy == nil {
		return
	}
	// One click per notch; the remainder keeps slow scrolling alive.
	click(&wheel_rem[1], dy, X_WHEEL_UP, X_WHEEL_DOWN)
	click(&wheel_rem[0], dx, X_WHEEL_LEFT, X_WHEEL_RIGHT)
	core.x11.XFlush(dpy)
}

@(private)
backend_key :: proc(key: Key, down: bool) {
	if key.evdev < 0 {
		return
	}
	if core.portal_remote_active() {
		core.portal_keyboard_key(key.evdev, down)
		return
	}
	if dpy == nil {
		return
	}
	// X keycodes are evdev codes shifted by 8.
	core.xtst.XTestFakeKeyEvent(dpy, u32(key.evdev + 8), b32(down), 0)
	core.x11.XFlush(dpy)
}

// click presses and releases the wheel button for each whole notch in delta
// (negative: `negative` button, positive: `positive` button).
@(private = "file")
click :: proc(rem: ^f64, delta: f64, negative, positive: u32) {
	steps := wheel_steps(rem, delta, WHEEL_PX_PER_NOTCH)
	button := positive if steps > 0 else negative
	for _ in 0 ..< abs(steps) {
		core.xtst.XTestFakeButtonEvent(dpy, button, true, 0)
		core.xtst.XTestFakeButtonEvent(dpy, button, false, 0)
	}
}
