#+build !windows
#+build !linux
#+build !darwin
package input

import "../core"

// No injection backend on this platform: init reports it and the rest is never reached.

@(private)
backend_init :: proc() -> bool {
	return false
}

@(private)
backend_shutdown :: proc() {
}

@(private)
backend_move :: proc(monitor: core.Monitor_Info, x, y: f64) {
}

@(private)
backend_button :: proc(button: int, down: bool) {
}

@(private)
backend_wheel :: proc(dx, dy: f64) {
}

@(private)
backend_key :: proc(key: Key, down: bool) {
}
