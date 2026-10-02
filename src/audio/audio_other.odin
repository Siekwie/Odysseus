#+build !windows
#+build !linux
#+build !darwin
package audio

import "../utils"

// No system-audio capture backend on this platform.

@(private)
capture_start :: proc(s: ^Stream, device_name: string) -> bool {
	utils.log_info("audio is not supported on this platform")
	return false
}

@(private)
capture_stop :: proc(s: ^Stream) {
}
