#+build !windows
package utils

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

@(private)
shutdown_proc: proc()
@(private)
shutdown_requested: bool

// install_crash_handler records fatal signals in the log before the process dies.
install_crash_handler :: proc() {
	posix.signal(.SIGSEGV, on_fatal_signal)
	posix.signal(.SIGBUS, on_fatal_signal)
	posix.signal(.SIGABRT, on_fatal_signal)
	posix.signal(.SIGFPE, on_fatal_signal)
	// A viewer closing its socket mid-write must not kill the process.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

// install_shutdown_handler runs cleanup once when the process is asked to
// stop (SIGINT, SIGTERM, SIGHUP), then exits. The signal handler only sets a
// flag; a watcher thread does the actual work outside signal context.
install_shutdown_handler :: proc(cleanup: proc()) {
	shutdown_proc = cleanup
	posix.signal(.SIGINT, on_stop_signal)
	posix.signal(.SIGTERM, on_stop_signal)
	posix.signal(.SIGHUP, on_stop_signal)
	thread.create_and_start(shutdown_watcher, self_cleanup = true)
}

@(private)
on_stop_signal :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&shutdown_requested, true)
}

@(private)
shutdown_watcher :: proc() {
	for !sync.atomic_load(&shutdown_requested) {
		time.sleep(100 * time.Millisecond)
	}
	if cleanup := shutdown_proc; cleanup != nil {
		shutdown_proc = nil
		cleanup()
	}
	os.exit(0)
}

@(private)
on_fatal_signal :: proc "c" (sig: posix.Signal) {
	context = runtime.default_context()
	buf: [128]byte
	log_raw(fmt.bprintf(buf[:], "CRASH: fatal signal %d", i32(sig)))
	// Restore the default action and re-raise so the exit status and core dump are the real ones.
	posix.signal(sig, auto_cast posix.SIG_DFL)
	posix.raise(sig)
}
