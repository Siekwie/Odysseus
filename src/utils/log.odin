package utils

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:time"

// Leveled logging to the console and, optionally, a log file. Messages are
// formatted into a stack buffer so the procedures are safe to call from the
// FFmpeg / libdatachannel callback threads, which have no temp allocator scope.

Log_Level :: enum {
	Debug,
	Info,
	Warn,
	Error,
}

@(private)
log_file: ^os.File
@(private)
log_mu: sync.Mutex
@(private)
log_min: Log_Level = .Info

log_set_verbose :: proc(verbose: bool) {
	log_min = .Debug if verbose else .Info
}

log_is_verbose :: proc() -> bool {
	return log_min == .Debug
}

log_debug :: proc(format: string, args: ..any) {
	log_write(.Debug, format, ..args)
}

log_info :: proc(format: string, args: ..any) {
	log_write(.Info, format, ..args)
}

log_warn :: proc(format: string, args: ..any) {
	log_write(.Warn, format, ..args)
}

log_error :: proc(format: string, args: ..any) {
	log_write(.Error, format, ..args)
}

@(private)
LEVEL_TAG := [Log_Level]string {
	.Debug = "debug",
	.Info  = "info ",
	.Warn  = "warn ",
	.Error = "error",
}

@(private)
log_write :: proc(level: Log_Level, format: string, args: ..any) {
	if level < log_min {
		return
	}
	buf: [2048]byte
	hour, min, sec := time.clock_from_time(time.now())
	prefix := fmt.bprintf(buf[:], "%02d:%02d:%02d %s  ", hour, min, sec, LEVEL_TAG[level])
	body := fmt.bprintf(buf[len(prefix):len(buf) - 1], format, ..args)
	n := len(prefix) + len(body)
	buf[n] = '\n'
	line := buf[:n + 1]

	sync.mutex_lock(&log_mu)
	defer sync.mutex_unlock(&log_mu)
	os.write(os.stderr if level >= .Warn else os.stdout, line)
	if log_file != nil {
		os.write(log_file, line)
		os.flush(log_file)
	}
}

// log_raw writes a line without a mutex or formatting allocations; for crash handlers.
log_raw :: proc(s: string) {
	os.write_string(os.stderr, s)
	os.write_string(os.stderr, "\n")
	if log_file != nil {
		os.write_string(log_file, s)
		os.write_string(log_file, "\n")
		os.flush(log_file)
	}
}

// log_open starts the log file. An empty path means odysseus.log next to the
// executable; "none" disables the file. Failure to open is not fatal.
log_open :: proc(path: string) {
	if path == "none" {
		return
	}
	name := path
	explicit := path != ""
	if !explicit {
		name = "odysseus.log"
		if len(os.args) > 0 {
			if dir := filepath.dir(os.args[0]); dir != "" {
				if joined, err := filepath.join({dir, "odysseus.log"}, context.temp_allocator); err == nil {
					name = joined
				}
			}
		}
	}
	f, err := os.create(name)
	if err != nil {
		// The default location is often read-only for installed binaries; only complain when asked for.
		if explicit {
			log_warn("could not open log file %s: %v", name, err)
		}
		return
	}
	log_file = f
	log_debug("logging to %s", name)
}

log_close :: proc() {
	sync.mutex_lock(&log_mu)
	defer sync.mutex_unlock(&log_mu)
	if log_file != nil {
		os.close(log_file)
		log_file = nil
	}
}
