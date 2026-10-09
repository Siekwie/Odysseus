#+build darwin
package input

import "core:time"

import "../core"
import "../utils"

foreign import cg_lib "system:CoreGraphics.framework"
foreign import cf_lib "system:CoreFoundation.framework"
foreign import ax_lib "system:ApplicationServices.framework"

// Quartz events posted at the HID level. macOS only honors them once the
// program has been granted the Accessibility permission (System Settings >
// Privacy & Security); without it the events are dropped silently.

@(private = "file")
CG_Event :: distinct rawptr

@(default_calling_convention = "c")
foreign cg_lib {
	CGEventCreateMouseEvent :: proc(source: rawptr, type: u32, position: core.CG_Point, button: u32) -> CG_Event ---
	CGEventCreateKeyboardEvent :: proc(source: rawptr, key: u16, down: bool) -> CG_Event ---
	// The non-variadic form of CGEventCreateScrollWheelEvent (macOS 10.13+).
	CGEventCreateScrollWheelEvent2 :: proc(source: rawptr, units: u32, wheel_count: u32, wheel1, wheel2, wheel3: i32) -> CG_Event ---
	CGEventPost :: proc(tap: u32, event: CG_Event) ---
	CGEventSetFlags :: proc(event: CG_Event, flags: u64) ---
	CGEventSetIntegerValueField :: proc(event: CG_Event, field: u32, value: i64) ---
}

@(default_calling_convention = "c")
foreign cf_lib {
	CFRelease :: proc(object: rawptr) ---
}

@(default_calling_convention = "c")
foreign ax_lib {
	AXIsProcessTrusted :: proc() -> bool ---
}

// CGEventType
@(private = "file")
LEFT_MOUSE_DOWN, LEFT_MOUSE_UP, RIGHT_MOUSE_DOWN, RIGHT_MOUSE_UP, MOUSE_MOVED, LEFT_MOUSE_DRAGGED, RIGHT_MOUSE_DRAGGED :: 1, 2, 3, 4, 5, 6, 7
@(private = "file")
OTHER_MOUSE_DOWN, OTHER_MOUSE_UP, OTHER_MOUSE_DRAGGED :: 25, 26, 27

// CGEventField
@(private = "file")
MOUSE_EVENT_CLICK_STATE    :: 1
@(private = "file")
MOUSE_EVENT_BUTTON_NUMBER  :: 3
@(private = "file")
MOUSE_EVENT_DELTA_X        :: 4
@(private = "file")
MOUSE_EVENT_DELTA_Y        :: 5

@(private = "file")
HID_EVENT_TAP :: 0 // kCGHIDEventTap
@(private = "file")
SCROLL_UNIT_PIXEL :: 0 // kCGScrollEventUnitPixel

// CGEventFlags device-independent modifier masks.
@(private = "file")
FLAG_SHIFT   :: 1 << 17
@(private = "file")
FLAG_CONTROL :: 1 << 18
@(private = "file")
FLAG_OPTION  :: 1 << 19
@(private = "file")
FLAG_COMMAND :: 1 << 20

// A second click within this time and distance of the first is a double click.
@(private = "file")
DOUBLE_CLICK_TIME :: 500 * time.Millisecond
@(private = "file")
DOUBLE_CLICK_DISTANCE :: 5.0 // points

@(private = "file")
pointer: core.CG_Point // where the last event left the pointer, global points
@(private = "file")
click_count: i64
@(private = "file")
click_button: int = -1
@(private = "file")
click_time: time.Tick
@(private = "file")
click_point: core.CG_Point

@(private)
backend_init :: proc() -> bool {
	if AXIsProcessTrusted() {
		utils.log_info("remote input: macOS Accessibility permission is granted")
	} else {
		utils.log_warn("remote input: macOS needs the Accessibility permission for this program (System Settings > Privacy & Security > Accessibility); events are ignored until it is granted")
	}
	return true
}

@(private)
backend_shutdown :: proc() {
}

@(private)
backend_move :: proc(monitor: core.Monitor_Info, x, y: f64) {
	// CGEvent positions are global points. Monitor_Info mixes points (origin)
	// with pixels (size), so take the display's bounds in points instead.
	ids: [16]u32
	n := core.display_ids(ids[:])
	if monitor.index < 0 || monitor.index >= n {
		return
	}
	bounds := core.CGDisplayBounds(ids[monitor.index])
	target := core.CG_Point{
		bounds.origin.x + x * max(bounds.size.width - 1, 0),
		bounds.origin.y + y * max(bounds.size.height - 1, 0),
	}

	// A move with a button held is a drag, which is a different event type.
	type: u32 = MOUSE_MOVED
	button: u32
	switch {
	case 0 in held_buttons:
		type, button = LEFT_MOUSE_DRAGGED, 0
	case 2 in held_buttons:
		type, button = RIGHT_MOUSE_DRAGGED, 1
	case held_buttons != {}:
		for b in 1 ..< BUTTON_COUNT {
			if b in held_buttons {
				type, button = OTHER_MOUSE_DRAGGED, mac_button(b)
				break
			}
		}
	}

	event := CGEventCreateMouseEvent(nil, type, target, button)
	if event == nil {
		return
	}
	defer CFRelease(event)
	if type == OTHER_MOUSE_DRAGGED {
		CGEventSetIntegerValueField(event, MOUSE_EVENT_BUTTON_NUMBER, i64(button))
	}
	if type != MOUSE_MOVED {
		CGEventSetIntegerValueField(event, MOUSE_EVENT_CLICK_STATE, max(click_count, 1))
	}
	// Games and some toolkits read the deltas, not the position.
	CGEventSetIntegerValueField(event, MOUSE_EVENT_DELTA_X, i64(target.x - pointer.x))
	CGEventSetIntegerValueField(event, MOUSE_EVENT_DELTA_Y, i64(target.y - pointer.y))
	CGEventSetFlags(event, modifier_flags())
	CGEventPost(HID_EVENT_TAP, event)
	pointer = target
}

@(private)
backend_button :: proc(button: int, down: bool) {
	type: u32
	switch button {
	case 0:
		type = LEFT_MOUSE_DOWN if down else LEFT_MOUSE_UP
	case 2:
		type = RIGHT_MOUSE_DOWN if down else RIGHT_MOUSE_UP
	case 1, 3, 4:
		type = OTHER_MOUSE_DOWN if down else OTHER_MOUSE_UP
	case:
		return
	}

	if down {
		now := time.tick_now()
		near := abs(pointer.x - click_point.x) <= DOUBLE_CLICK_DISTANCE && abs(pointer.y - click_point.y) <= DOUBLE_CLICK_DISTANCE
		if click_button == button && near && time.tick_diff(click_time, now) <= DOUBLE_CLICK_TIME {
			click_count += 1
		} else {
			click_count = 1
		}
		click_button, click_time, click_point = button, now, pointer
	}

	event := CGEventCreateMouseEvent(nil, type, pointer, mac_button(button))
	if event == nil {
		return
	}
	defer CFRelease(event)
	if type == OTHER_MOUSE_DOWN || type == OTHER_MOUSE_UP {
		CGEventSetIntegerValueField(event, MOUSE_EVENT_BUTTON_NUMBER, i64(mac_button(button)))
	}
	CGEventSetIntegerValueField(event, MOUSE_EVENT_CLICK_STATE, max(click_count, 1))
	CGEventSetFlags(event, modifier_flags())
	CGEventPost(HID_EVENT_TAP, event)
}

@(private)
backend_wheel :: proc(dx, dy: f64) {
	// Pixel units, so one browser pixel is one point. Positive wheel values
	// scroll up/left in Quartz, the opposite of the browser's deltas.
	vertical := wheel_steps(&wheel_rem[1], -dy, 1)
	horizontal := wheel_steps(&wheel_rem[0], -dx, 1)
	if vertical == 0 && horizontal == 0 {
		return
	}
	event := CGEventCreateScrollWheelEvent2(nil, SCROLL_UNIT_PIXEL, 2, i32(vertical), i32(horizontal), 0)
	if event == nil {
		return
	}
	defer CFRelease(event)
	CGEventSetFlags(event, modifier_flags())
	CGEventPost(HID_EVENT_TAP, event)
}

@(private)
backend_key :: proc(key: Key, down: bool) {
	if key.mac < 0 {
		return
	}
	event := CGEventCreateKeyboardEvent(nil, u16(key.mac), down)
	if event == nil {
		return
	}
	defer CFRelease(event)
	// Posting a bare modifier key does not reliably change the flags of the
	// events that follow, so state them explicitly (held_keys is up to date).
	CGEventSetFlags(event, modifier_flags())
	CGEventPost(HID_EVENT_TAP, event)
}

// MouseEvent.button (left, middle, right, back, forward) to CGMouseButton
// (left, right, center, then the numbered "other" buttons).
@(private = "file")
mac_button :: proc(button: int) -> u32 {
	switch button {
	case 0:
		return 0
	case 1:
		return 2
	case 2:
		return 1
	}
	return u32(button)
}

// The modifier mask of the keys held through inject.
@(private = "file")
modifier_flags :: proc() -> (flags: u64) {
	for held, i in held_keys {
		if !held {
			continue
		}
		switch KEYS[i].mac {
		case 0x38, 0x3C:
			flags |= FLAG_SHIFT
		case 0x3B, 0x3E:
			flags |= FLAG_CONTROL
		case 0x3A, 0x3D:
			flags |= FLAG_OPTION
		case 0x37, 0x36:
			flags |= FLAG_COMMAND
		}
	}
	return
}
