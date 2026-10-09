package input

import "core:testing"

import "../core"

// Pure logic only: nothing here injects input.

@(test)
event_from_signal_kinds :: proc(t: ^testing.T) {
	Case :: struct {
		ev:   string,
		kind: Event_Kind,
		down: bool,
	}
	cases := [?]Case{
		{"move", .Move, false},
		{"down", .Button, true},
		{"up", .Button, false},
		{"wheel", .Wheel, false},
		{"key", .Key, false},
	}
	for c in cases {
		event, ok := event_from_signal(c.ev, 0.25, 0.75, 2, 3, -4, "KeyA", false)
		testing.expectf(t, ok, "ev %q rejected", c.ev)
		testing.expect_value(t, event.kind, c.kind)
		testing.expect_value(t, event.down, c.down)
		testing.expect_value(t, event.x, 0.25)
		testing.expect_value(t, event.y, 0.75)
		testing.expect_value(t, event.button, 2)
		testing.expect_value(t, event.dx, 3.0)
		testing.expect_value(t, event.dy, -4.0)
		testing.expect_value(t, event.key, "KeyA")
	}

	// A key event carries its own down flag.
	event, ok := event_from_signal("key", 0, 0, 0, 0, 0, "Enter", true)
	testing.expect(t, ok)
	testing.expect(t, event.down)
	// An up event stays up even if the client sent down = true.
	event, ok = event_from_signal("up", 0, 0, 0, 0, 0, "", true)
	testing.expect(t, ok)
	testing.expect(t, !event.down)
}

@(test)
event_from_signal_garbage :: proc(t: ^testing.T) {
	for ev in ([?]string{"", "MOVE", "click", "mouse move", "down ", "\x00", "wheel\n"}) {
		_, ok := event_from_signal(ev, 0.5, 0.5, 0, 0, 0, "", false)
		testing.expectf(t, !ok, "ev %q accepted", ev)
	}
}

@(test)
event_from_signal_clamps_position :: proc(t: ^testing.T) {
	event, _ := event_from_signal("move", -3, 7.5, 0, 0, 0, "", false)
	testing.expect_value(t, event.x, 0.0)
	testing.expect_value(t, event.y, 1.0)
	event, _ = event_from_signal("move", 1.0000001, -0.0000001, 0, 0, 0, "", false)
	testing.expect_value(t, event.x, 1.0)
	testing.expect_value(t, event.y, 0.0)
	event, _ = event_from_signal("move", 0.5, 1, 0, 0, 0, "", false)
	testing.expect_value(t, event.x, 0.5)
	testing.expect_value(t, event.y, 1.0)
}

@(test)
monitor_point_corners :: proc(t: ^testing.T) {
	// A second monitor to the left of and above the primary one.
	monitor := core.Monitor_Info{x = -1920, y = -200, width = 1920, height = 1080}
	px, py := monitor_point(monitor, 0, 0)
	testing.expect_value(t, px, -1920)
	testing.expect_value(t, py, -200)
	px, py = monitor_point(monitor, 1, 1)
	testing.expect_value(t, px, -1)  // last pixel column: x + width - 1
	testing.expect_value(t, py, 879) // last pixel row: y + height - 1
	px, py = monitor_point(monitor, 0.5, 0.5)
	testing.expect_value(t, px, -1920 + 960)
	testing.expect_value(t, py, -200 + 540)

	// A 1x1 or empty monitor must not divide or underflow.
	px, py = monitor_point(core.Monitor_Info{x = 10, y = 20, width = 1, height = 1}, 1, 1)
	testing.expect_value(t, px, 10)
	testing.expect_value(t, py, 20)
	px, py = monitor_point(core.Monitor_Info{x = 10, y = 20}, 1, 1)
	testing.expect_value(t, px, 10)
	testing.expect_value(t, py, 20)
}

@(test)
keymap_letters_and_digits :: proc(t: ^testing.T) {
	key, ok := key_lookup("KeyA")
	testing.expect(t, ok)
	testing.expect_value(t, key.evdev, 30)
	testing.expect_value(t, key.scan, 0x1E)
	testing.expect_value(t, key.ext, false)
	testing.expect_value(t, key.mac, 0x00)

	// The famously unordered ones on macOS.
	key, _ = key_lookup("KeyZ")
	testing.expect_value(t, key.mac, 0x06)
	key, _ = key_lookup("Digit6")
	testing.expect_value(t, key.mac, 0x16)
	testing.expect_value(t, key.evdev, 7)
	key, _ = key_lookup("Digit0")
	testing.expect_value(t, key.evdev, 11)
	testing.expect_value(t, key.scan, 0x0B)
	key, _ = key_lookup("Backquote")
	testing.expect_value(t, key.mac, 0x32)
	testing.expect_value(t, key.scan, 0x29)
}

@(test)
keymap_enter_and_numpad_enter :: proc(t: ^testing.T) {
	enter, ok := key_lookup("Enter")
	testing.expect(t, ok)
	testing.expect_value(t, enter.evdev, 28)
	testing.expect_value(t, enter.scan, 0x1C)
	testing.expect_value(t, enter.ext, false)
	testing.expect_value(t, enter.mac, 0x24)

	kp, ok2 := key_lookup("NumpadEnter")
	testing.expect(t, ok2)
	testing.expect_value(t, kp.evdev, 96)
	testing.expect_value(t, kp.scan, 0x1C) // same scan code as Enter, told apart by E0
	testing.expect_value(t, kp.ext, true)
	testing.expect_value(t, kp.mac, 0x4C)
}

@(test)
keymap_arrows_are_extended :: proc(t: ^testing.T) {
	left, ok := key_lookup("ArrowLeft")
	testing.expect(t, ok)
	testing.expect_value(t, left.evdev, 105)
	testing.expect_value(t, left.scan, 0x4B)
	testing.expect(t, left.ext)
	testing.expect_value(t, left.mac, 0x7B)

	// Every arrow, navigation key, right Ctrl/Alt, Meta and NumpadDivide needs E0 on Windows.
	for code in ([?]string{
		"ArrowUp", "ArrowDown", "ArrowRight", "Insert", "Delete", "Home", "End", "PageUp", "PageDown",
		"ControlRight", "AltRight", "MetaLeft", "MetaRight", "ContextMenu", "NumpadDivide", "NumpadEnter",
	}) {
		key, found := key_lookup(code)
		testing.expectf(t, found, "%s missing", code)
		testing.expectf(t, key.ext, "%s should be extended", code)
	}
	// ... and their left-hand / main-block counterparts do not.
	for code in ([?]string{"ControlLeft", "AltLeft", "ShiftLeft", "ShiftRight", "Enter", "Numpad7", "NumpadMultiply", "NumLock"}) {
		key, found := key_lookup(code)
		testing.expectf(t, found, "%s missing", code)
		testing.expectf(t, !key.ext, "%s should not be extended", code)
	}
}

@(test)
keymap_meta_and_modifiers :: proc(t: ^testing.T) {
	meta, ok := key_lookup("MetaLeft")
	testing.expect(t, ok)
	testing.expect_value(t, meta.evdev, 125)
	testing.expect_value(t, meta.scan, 0x5B)
	testing.expect(t, meta.ext)
	testing.expect_value(t, meta.mac, 0x37) // Command

	meta, _ = key_lookup("MetaRight")
	testing.expect_value(t, meta.evdev, 126)
	testing.expect_value(t, meta.scan, 0x5C)
	testing.expect_value(t, meta.mac, 0x36)

	shift, _ := key_lookup("ShiftRight")
	testing.expect_value(t, shift.evdev, 54)
	testing.expect_value(t, shift.scan, 0x36)
	testing.expect_value(t, shift.mac, 0x3C)
}

@(test)
keymap_missing_platform_entries :: proc(t: ^testing.T) {
	pause, ok := key_lookup("Pause")
	testing.expect(t, ok)
	testing.expect_value(t, pause.evdev, 119)
	testing.expect_value(t, pause.scan, NONE)
	testing.expect_value(t, pause.vk, 0x13) // VK_PAUSE: the scan code is a multi-byte sequence

	print, _ := key_lookup("PrintScreen")
	testing.expect_value(t, print.vk, 0x2C) // VK_SNAPSHOT

	f24, _ := key_lookup("F24")
	testing.expect_value(t, f24.mac, NONE)
	testing.expect_value(t, f24.vk, 0x87)
}

@(test)
keymap_unknown_code :: proc(t: ^testing.T) {
	for code in ([?]string{"", "keya", "KeyAA", "Key A", "Unidentified", "Dead", "LaunchMail"}) {
		_, ok := key_lookup(code)
		testing.expectf(t, !ok, "%q should be unknown", code)
		testing.expect_value(t, key_index(code), -1)
	}
}

@(test)
keymap_table_is_consistent :: proc(t: ^testing.T) {
	for a, i in KEYS {
		testing.expectf(t, a.code != "", "row %d has no code", i)
		// A key must be reachable on at least one platform.
		reachable := a.evdev >= 0 || a.scan >= 0 || a.vk != 0 || a.mac >= 0
		testing.expectf(t, reachable, "%s has no platform code at all", a.code)
		// X11 keycodes are 8..255.
		testing.expectf(t, a.evdev < 0 || a.evdev + 8 <= 255, "%s: X keycode out of range", a.code)
		testing.expectf(t, a.scan <= 0xFF, "%s: scan code out of range", a.code)
		testing.expectf(t, a.mac <= 0x7F, "%s: macOS key code out of range", a.code)

		// Two different physical keys must not share a code on one platform
		// (macOS is exempt: the table folds PC keys onto Mac F-keys on purpose).
		for b, j in KEYS[i + 1:] {
			testing.expectf(t, a.code != b.code, "duplicate code %q (rows %d and %d)", a.code, i, i + 1 + j)
			testing.expectf(t, a.evdev < 0 || a.evdev != b.evdev, "%s and %s share evdev %d", a.code, b.code, a.evdev)
			if a.scan >= 0 && a.vk == 0 && b.vk == 0 {
				testing.expectf(t, !(a.scan == b.scan && a.ext == b.ext), "%s and %s share scan %#x", a.code, b.code, a.scan)
			}
			if a.vk != 0 {
				testing.expectf(t, a.vk != b.vk, "%s and %s share vk %#x", a.code, b.code, a.vk)
			}
		}
	}
}

@(test)
keymap_covers_us_keyboard :: proc(t: ^testing.T) {
	// Everything the browser names for a 104-key US keyboard, plus a few extras.
	codes := [?]string{
		"Backquote", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Digit0", "Minus", "Equal", "Backspace",
		"Tab", "KeyQ", "KeyW", "KeyE", "KeyR", "KeyT", "KeyY", "KeyU", "KeyI", "KeyO", "KeyP", "BracketLeft", "BracketRight", "Backslash",
		"CapsLock", "KeyA", "KeyS", "KeyD", "KeyF", "KeyG", "KeyH", "KeyJ", "KeyK", "KeyL", "Semicolon", "Quote", "Enter",
		"ShiftLeft", "KeyZ", "KeyX", "KeyC", "KeyV", "KeyB", "KeyN", "KeyM", "Comma", "Period", "Slash", "ShiftRight",
		"ControlLeft", "MetaLeft", "AltLeft", "Space", "AltRight", "MetaRight", "ContextMenu", "ControlRight",
		"Escape", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
		"PrintScreen", "ScrollLock", "Pause", "Insert", "Home", "PageUp", "Delete", "End", "PageDown",
		"ArrowUp", "ArrowLeft", "ArrowDown", "ArrowRight",
		"NumLock", "NumpadDivide", "NumpadMultiply", "NumpadSubtract", "NumpadAdd", "NumpadEnter", "NumpadDecimal",
		"Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9",
		"IntlBackslash", "F13", "F24", "AudioVolumeUp", "AudioVolumeDown", "AudioVolumeMute",
	}
	for code in codes {
		key, ok := key_lookup(code)
		testing.expectf(t, ok, "%s missing from the keymap", code)
		testing.expectf(t, key.evdev > 0, "%s has no evdev code", code)
		testing.expectf(t, key.scan >= 0 || key.vk != 0, "%s has no Windows code", code)
	}
}

@(test)
wheel_steps_accumulates_fractions :: proc(t: ^testing.T) {
	rem: f64

	// Slow trackpad ticks of 15 px at 100 px per step: the 7th tick completes the first step.
	total := 0
	for i in 1 ..= 10 {
		n := wheel_steps(&rem, 15, 100)
		if i < 7 {
			testing.expect_value(t, n, 0)
		}
		total += n
	}
	testing.expect_value(t, total, 1)
	testing.expect(t, abs(rem - 0.5) < 1e-9)

	// Whole notches at once.
	rem = 0
	testing.expect_value(t, wheel_steps(&rem, 100, 100), 1)
	testing.expect(t, abs(rem) < 1e-9)
	testing.expect_value(t, wheel_steps(&rem, 250, 100), 2)
	testing.expect(t, abs(rem - 0.5) < 1e-9)
}

@(test)
wheel_steps_handles_direction :: proc(t: ^testing.T) {
	rem: f64
	// Negative deltas truncate toward zero as well, and the remainder carries its sign.
	testing.expect_value(t, wheel_steps(&rem, -250, 100), -2)
	testing.expect(t, abs(rem + 0.5) < 1e-9)
	// Reversing first works off the pending -0.5.
	testing.expect_value(t, wheel_steps(&rem, 30, 100), 0)
	testing.expect(t, abs(rem + 0.2) < 1e-9)
	testing.expect_value(t, wheel_steps(&rem, 130, 100), 1)
	testing.expect(t, abs(rem - 0.1) < 1e-9)

	// Windows scale: a notch is 100 px and 120 wheel units, so exact multiples must not lose a unit to float noise.
	rem = 0
	per_unit :: WHEEL_PX_PER_NOTCH / 120
	testing.expect_value(t, wheel_steps(&rem, 100, per_unit), 120)
	testing.expect_value(t, wheel_steps(&rem, -100, per_unit), -120)
	testing.expect_value(t, wheel_steps(&rem, 1, per_unit), 1)
	testing.expect_value(t, wheel_steps(&rem, 0, per_unit), 0)
}

@(test)
absolute_coord_hits_the_pixel :: proc(t: ^testing.T) {
	// Windows resolves absolute n to pixel n * extent / 65536 (floor or round);
	// every pixel must come back from the middle of its slice under both rules.
	for extent in ([?]int{1, 800, 1920, 2560, 3840, 7680}) {
		for origin in ([?]int{0, -1920}) {
			for p in ([?]int{origin, origin + 1, origin + extent / 2, origin + extent - 2, origin + extent - 1}) {
				if p < origin || p >= origin + extent {
					continue
				}
				n := absolute_coord(p, origin, extent)
				testing.expectf(t, n >= 0 && n <= 65535, "n=%d out of range", n)
				floor_px := origin + n * extent / 65536
				round_px := origin + (n * extent + 32768) / 65536
				testing.expectf(t, floor_px == p, "p=%d origin=%d extent=%d n=%d floor -> %d", p, origin, extent, n, floor_px)
				testing.expectf(t, abs(round_px - p) <= 1, "p=%d origin=%d extent=%d n=%d round -> %d", p, origin, extent, n, round_px)
			}
		}
	}
	// Out-of-range pixels are clamped, and a zero extent does not divide by zero.
	testing.expect_value(t, absolute_coord(-50, 0, 1920), 0)
	testing.expect_value(t, absolute_coord(99999, 0, 1920), 65535)
	testing.expect_value(t, absolute_coord(0, 0, 0), 32768)
}
