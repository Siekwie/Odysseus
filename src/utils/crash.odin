package utils

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import win32 "core:sys/windows"

log_file: ^os.File
log_mu: sync.Mutex

log_line :: proc(s: string) {
	sync.mutex_lock(&log_mu)
	defer sync.mutex_unlock(&log_mu)
	fmt.println(s)
	if log_file != nil {
		os.write_string(log_file, s)
		os.write_string(log_file, "\n")
		os.flush(log_file)
	}
}

log_error :: proc(s: string) {
	sync.mutex_lock(&log_mu)
	defer sync.mutex_unlock(&log_mu)
	fmt.eprintln(s)
	if log_file != nil {
		os.write_string(log_file, s)
		os.write_string(log_file, "\n")
		os.flush(log_file)
	}
}

install_crash_log :: proc() {
	name := "odysseus.log"
	if len(os.args) > 0 {
		dir := filepath.dir(os.args[0])
		if dir != "" {
			joined, jerr := filepath.join({dir, "odysseus.log"})
			if jerr == nil {
				name = joined
			}
		}
	}
	h, err := os.create(name)
	if err != nil {
		fmt.eprintln("could not open odysseus.log:", err)
		return
	}
	log_file = h
	fmt.println("writing logs to", name)

	when ODIN_OS == .Windows {
		win32.SetUnhandledExceptionFilter(unhandled_exception)
	}
	libc.signal(libc.SIGABRT, on_abort)
}

wait_for_enter :: proc() {
	fmt.println("Press Enter to close...")
	b: [8]byte
	os.read(os.stdin, b[:])
}

@(private)
write_crash_unlocked :: proc(s: string) {
	fmt.eprintln(s)
	if log_file != nil {
		os.write_string(log_file, s)
		os.write_string(log_file, "\n")
		os.flush(log_file)
	}
}

@(private)
on_abort :: proc "c" (sig: i32) {
	context = runtime.default_context()
	write_crash_unlocked(fmt.tprintf("CRASH: abort signal %d (C++ terminate / mbedtls assert)", sig))
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
	write_crash_unlocked(fmt.tprintf("CRASH: exception 0x%X at %p", code, addr))
	os.exit(1)
}
