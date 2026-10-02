#+build !windows
package utils

import "core:strings"
import "core:sys/posix"

// hostname returns this machine's network name ("" when unknown). The result is temp-allocated.
hostname :: proc() -> string {
	buf: [256]u8
	if posix.gethostname(cast([^]u8)&buf[0], len(buf) - 1) != .OK {
		return ""
	}
	return strings.clone(string(cstring(&buf[0])), context.temp_allocator)
}
