#+build windows
package input

import win32 "core:sys/windows"

import "../core"
import "../utils"

// SendInput. Absolute mouse positions, scan-code keyboard events: the target
// application sees what a real mouse and keyboard would produce. Windows
// blocks injection into elevated windows (UIPI) and the secure desktop
// unless the host runs elevated too.

KEYEVENTF_EXTENDEDKEY :: 0x0001
KEYEVENTF_KEYUP       :: 0x0002
KEYEVENTF_SCANCODE    :: 0x0008

// Wheel units a notch is made of (WHEEL_DELTA).
@(private = "file")
WHEEL_DELTA :: 120

@(private = "file")
warned: bool

@(private)
backend_init :: proc() -> bool {
	// Per-monitor awareness, so GetSystemMetrics reports the same physical
	// pixels the capture works in. Fails harmlessly when the process is
	// already aware (manifest) or Windows predates the V2 context.
	win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	return true
}

@(private)
backend_shutdown :: proc() {
}

@(private)
backend_move :: proc(monitor: core.Monitor_Info, x, y: f64) {
	px, py := monitor_point(monitor, x, y)
	// The virtual screen spans all monitors, so one normalized range covers them.
	vx := int(win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN))
	vy := int(win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN))
	vw := int(win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN))
	vh := int(win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN))
	send_mouse(
		win32.MOUSEEVENTF_MOVE | win32.MOUSEEVENTF_ABSOLUTE | win32.MOUSEEVENTF_VIRTUALDESK,
		dx = i32(absolute_coord(px, vx, vw)),
		dy = i32(absolute_coord(py, vy, vh)),
	)
}

@(private)
backend_button :: proc(button: int, down: bool) {
	flags: u32
	data: u32
	switch button {
	case 0:
		flags = win32.MOUSEEVENTF_LEFTDOWN if down else win32.MOUSEEVENTF_LEFTUP
	case 1:
		flags = win32.MOUSEEVENTF_MIDDLEDOWN if down else win32.MOUSEEVENTF_MIDDLEUP
	case 2:
		flags = win32.MOUSEEVENTF_RIGHTDOWN if down else win32.MOUSEEVENTF_RIGHTUP
	case 3:
		flags = win32.MOUSEEVENTF_XDOWN if down else win32.MOUSEEVENTF_XUP
		data = win32.XBUTTON1
	case 4:
		flags = win32.MOUSEEVENTF_XDOWN if down else win32.MOUSEEVENTF_XUP
		data = win32.XBUTTON2
	case:
		return
	}
	send_mouse(flags, data)
}

@(private)
backend_wheel :: proc(dx, dy: f64) {
	per_unit := WHEEL_PX_PER_NOTCH / WHEEL_DELTA
	// Scrolling down is a negative wheel rotation, scrolling right a positive one.
	if units := wheel_steps(&wheel_rem[1], -dy, per_unit); units != 0 {
		send_mouse(win32.MOUSEEVENTF_WHEEL, u32(i32(units)))
	}
	if units := wheel_steps(&wheel_rem[0], dx, per_unit); units != 0 {
		send_mouse(win32.MOUSEEVENTF_HWHEEL, u32(i32(units)))
	}
}

@(private)
backend_key :: proc(key: Key, down: bool) {
	input := win32.INPUT{type = .KEYBOARD}
	flags: u32 = 0 if down else KEYEVENTF_KEYUP
	if key.ext {
		flags |= KEYEVENTF_EXTENDEDKEY
	}
	if key.vk != 0 {
		input.ki = {wVk = win32.WORD(key.vk), dwFlags = flags}
	} else if key.scan >= 0 {
		input.ki = {wScan = win32.WORD(key.scan), dwFlags = flags | KEYEVENTF_SCANCODE}
	} else {
		return
	}
	send(&input)
}

@(private = "file")
send_mouse :: proc(flags: u32, data: u32 = 0, dx: i32 = 0, dy: i32 = 0) {
	input := win32.INPUT{type = .MOUSE}
	input.mi = {dx = dx, dy = dy, mouseData = data, dwFlags = flags}
	send(&input)
}

@(private = "file")
send :: proc(input: ^win32.INPUT) {
	if win32.SendInput(1, input, size_of(win32.INPUT)) == 0 && !warned {
		warned = true
		utils.log_warn("remote input blocked (error %d): elevated windows and the lock screen ignore injected input", win32.GetLastError())
	}
}
