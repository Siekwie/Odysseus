package utils

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:os"
import win32 "core:sys/windows"

@(private)
shutdown_proc: proc()

// install_crash_handler records unhandled exceptions and aborts in the log before the process dies.
install_crash_handler :: proc() {
	win32.SetUnhandledExceptionFilter(unhandled_exception)
	libc.signal(libc.SIGABRT, on_abort)
}

// install_shutdown_handler runs cleanup once when the process is asked to
// stop (Ctrl+C, console close, logoff), then exits.
install_shutdown_handler :: proc(cleanup: proc()) {
	shutdown_proc = cleanup
	win32.SetConsoleCtrlHandler(on_console_ctrl, win32.TRUE)
}

@(private)
on_console_ctrl :: proc "system" (ctrl_type: win32.DWORD) -> win32.BOOL {
	context = runtime.default_context()
	// Windows runs this on its own thread, so real work is fine here.
	if cleanup := shutdown_proc; cleanup != nil {
		shutdown_proc = nil
		cleanup()
	}
	os.exit(0)
}

@(private)
on_abort :: proc "c" (sig: i32) {
	context = runtime.default_context()
	buf: [128]byte
	log_raw(fmt.bprintf(buf[:], "CRASH: abort signal %d (C++ terminate or assertion in a native library)", sig))
	os.exit(1)
}

@(private)
unhandled_exception :: proc "system" (info: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
	context = runtime.default_context()
	code: u32
	addr: rawptr
	if info != nil && info.ExceptionRecord != nil {
		code = info.ExceptionRecord.ExceptionCode
		addr = info.ExceptionRecord.ExceptionAddress
	}
	buf: [128]byte
	log_raw(fmt.bprintf(buf[:], "CRASH: exception 0x%X at %p", code, addr))
	os.exit(1)
}
