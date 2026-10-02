package utils

import "core:os"

// hostname returns this machine's network name ("" when unknown). The result is temp-allocated.
hostname :: proc() -> string {
	return os.get_env("COMPUTERNAME", context.temp_allocator)
}
