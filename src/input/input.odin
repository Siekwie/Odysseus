package input

import "core:math"
import "core:sync"

import "../core"

// Remote input: mouse and keyboard events from a viewer are injected into the
// host's desktop. Off unless the host starts with -input. Each platform
// implements `init`, `shutdown` and `inject` (see input_*.odin).

Event_Kind :: enum {
	Move,   // pointer to (x, y)
	Button, // mouse button `button` pressed (down) or released, at (x, y)
	Wheel,  // scroll by (dx, dy) CSS pixels; positive dy scrolls down
	Key,    // keyboard key `key` pressed (down) or released
}

Event :: struct {
	kind:   Event_Kind,
	x:      f64,    // 0..1 across the captured monitor
	y:      f64,
	button: int,    // MouseEvent.button: 0 left, 1 middle, 2 right, 3 back, 4 forward
	down:   bool,
	dx:     f64,
	dy:     f64,
	key:    string, // KeyboardEvent.code, e.g. "KeyA", "Enter", "ShiftLeft"
}

// event_from_signal converts the fields of a signaling "input" message.
// ok is false for an unknown `ev`.
event_from_signal :: proc(ev: string, x, y: f64, button: int, dx, dy: f64, key: string, down: bool) -> (event: Event, ok: bool) {
	event = Event{
		x      = clamp(x, 0, 1),
		y      = clamp(y, 0, 1),
		button = button,
		down   = down,
		dx     = dx,
		dy     = dy,
		key    = key,
	}
	switch ev {
	case "move":
		event.kind = .Move
	case "down":
		event.kind = .Button
		event.down = true
	case "up":
		event.kind = .Button
		event.down = false
	case "wheel":
		event.kind = .Wheel
	case "key":
		event.kind = .Key
	case:
		return {}, false
	}
	return event, true
}

// monitor_point maps a normalized position to virtual-desktop pixels on monitor.
monitor_point :: proc(monitor: core.Monitor_Info, x, y: f64) -> (px, py: int) {
	px = monitor.x + int(x * f64(max(monitor.width - 1, 0)) + 0.5)
	py = monitor.y + int(y * f64(max(monitor.height - 1, 0)) + 0.5)
	return
}

// Number of mouse buttons the protocol knows (MouseEvent.button 0..4).
BUTTON_COUNT :: 5

// Browsers report about this many CSS pixels per mouse wheel notch.
WHEEL_PX_PER_NOTCH :: 100.0

// One event never scrolls more than this many pixels, so a corrupt or hostile
// message cannot spin the wheel for minutes.
MAX_WHEEL_PX :: 2000.0

// Each platform provides these (input_*.odin). They run with `mu` held, so
// they need no locking of their own.
//
//   backend_init     false when input cannot work at all on this system
//   backend_move     pointer to a normalized position on the monitor
//   backend_button   button (0..4, MouseEvent numbering) at the pointer
//   backend_wheel    raw CSS-pixel deltas; the backend scales them (wheel_rem
//                    carries what a step could not use)
//   backend_key      key down/up; `held_keys` already includes the change
//
// The shared state below tells backends what is held: macOS needs it for
// drag events and modifier flags.

@(private)
mu: sync.Mutex
@(private)
active: bool
@(private)
held_keys: [len(KEYS)]bool
@(private)
held_buttons: bit_set[0 ..< BUTTON_COUNT]
@(private)
wheel_rem: [2]f64 // x, y

// init prepares the platform backend. False when input cannot be injected here.
init :: proc() -> bool {
	sync.guard(&mu)
	held_keys = {}
	held_buttons = {}
	wheel_rem = {}
	active = backend_init()
	return active
}

// shutdown releases everything still held and closes the backend.
shutdown :: proc() {
	sync.guard(&mu)
	release_all_locked()
	if active {
		backend_shutdown()
	}
	active = false
}

// inject performs one event on the host. Safe to call from any thread.
inject :: proc(event: Event, monitor: core.Monitor_Info) {
	sync.guard(&mu)
	if !active {
		return
	}
	switch event.kind {
	case .Move:
		backend_move(monitor, event.x, event.y)
	case .Button:
		if event.button < 0 || event.button >= BUTTON_COUNT {
			return
		}
		// Move first so the click lands where the viewer's pointer is, and so
		// that a move before the release still counts as a drag.
		backend_move(monitor, event.x, event.y)
		backend_button(event.button, event.down)
		if event.down {
			held_buttons += {event.button}
		} else {
			held_buttons -= {event.button}
		}
	case .Wheel:
		backend_wheel(clamp(event.dx, -MAX_WHEEL_PX, MAX_WHEEL_PX), clamp(event.dy, -MAX_WHEEL_PX, MAX_WHEEL_PX))
	case .Key:
		i := key_index(event.key)
		if i < 0 {
			return
		}
		held_keys[i] = event.down
		backend_key(KEYS[i], event.down)
	}
}

// release_all lets go of every key and button pressed through inject, so a
// viewer that disconnects mid-keystroke does not leave the host's keyboard stuck.
release_all :: proc() {
	sync.guard(&mu)
	if active {
		release_all_locked()
	}
}

@(private)
release_all_locked :: proc() {
	if !active {
		return
	}
	for held, i in held_keys {
		if held {
			held_keys[i] = false
			backend_key(KEYS[i], false)
		}
	}
	for button in held_buttons {
		backend_button(button, false)
	}
	held_buttons = {}
}

// wheel_steps converts delta into whole steps of per_step, keeping the
// fraction in rem for the next call so that slow trackpad scrolling adds up
// instead of being rounded away. Truncates toward zero (give or take float
// noise), so a reversal of direction first works off the pending remainder.
wheel_steps :: proc(rem: ^f64, delta, per_step: f64) -> int {
	rem^ += delta / per_step
	steps := int(rem^ + math.copy_sign(1e-9, rem^)) // tolerates float noise at exact multiples
	rem^ -= f64(steps)
	return steps
}

// absolute_coord maps pixel p of a span (origin, size span) to the 0..65535
// range of absolute mouse input. The middle of the pixel's slice is used so
// that either rounding rule of the receiver lands on p.
absolute_coord :: proc(p, origin, span: int) -> int {
	extent := max(span, 1)
	return clamp(((2 * (p - origin) + 1) * 65536) / (2 * extent), 0, 65535)
}
