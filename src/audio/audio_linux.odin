package audio

import "core:c"
import "core:dynlib"
import "core:strings"
import "core:sync"
import "core:thread"

import "../utils"

// PulseAudio (or PipeWire's pulse server) through libpulse-simple, loaded at
// run time: the monitor source of the default sink is what the speakers play.

@(private)
PA_STREAM_RECORD :: 2
@(private)
PA_SAMPLE_S16LE  :: 3

@(private)
Pa_Sample_Spec :: struct {
	format:   c.int,
	rate:     u32,
	channels: u8,
}

@(private)
Pa_Buffer_Attr :: struct {
	maxlength: u32,
	tlength:   u32,
	prebuf:    u32,
	minreq:    u32,
	fragsize:  u32,
}

@(private)
Pulse_Lib :: struct {
	pa_simple_new: proc "c" (
		server: cstring,
		name: cstring,
		dir: c.int,
		dev: cstring,
		stream_name: cstring,
		spec: ^Pa_Sample_Spec,
		channel_map: rawptr,
		attr: ^Pa_Buffer_Attr,
		error: ^c.int,
	) -> rawptr,
	pa_simple_read: proc "c" (s: rawptr, data: rawptr, bytes: c.size_t, error: ^c.int) -> c.int,
	pa_simple_free: proc "c" (s: rawptr),
	__handle:       dynlib.Library,
}

@(private)
pulse: Pulse_Lib
@(private)
_pulse_once: sync.Once
@(private)
_pulse_ok: bool

@(private)
Capture_Pulse :: struct {
	simple:  rawptr,
	thread:  ^thread.Thread,
	running: bool, // atomic
}

@(private)
capture_start :: proc(s: ^Stream, device_name: string) -> bool {
	sync.once_do(&_pulse_once, proc() {
		_, _pulse_ok = dynlib.initialize_symbols(&pulse, "libpulse-simple.so.0")
	})
	if !_pulse_ok {
		utils.log_warn("audio disabled: libpulse-simple.so.0 not found (install PulseAudio or pipewire-pulse)")
		return false
	}

	spec := Pa_Sample_Spec{format = PA_SAMPLE_S16LE, rate = SAMPLE_RATE, channels = CHANNELS}
	frame_bytes := u32(FRAME_SAMPLES * CHANNELS * size_of(i16))
	attr := Pa_Buffer_Attr{
		maxlength = max(u32),
		tlength   = max(u32),
		prebuf    = max(u32),
		minreq    = max(u32),
		fragsize  = frame_bytes / 2, // 10 ms fragments keep latency low
	}
	source := strings.clone_to_cstring(device_name if device_name != "" else "@DEFAULT_MONITOR@", context.temp_allocator)

	err: c.int
	simple := pulse.pa_simple_new(nil, "Odysseus", PA_STREAM_RECORD, source, "system audio", &spec, nil, &attr, &err)
	if simple == nil {
		utils.log_warn("audio disabled: could not open PulseAudio source '%s' (error %d)", source, err)
		return false
	}

	cap := new(Capture_Pulse)
	cap.simple = simple
	cap.running = true
	s.platform = cap
	cap.thread = thread.create_and_start_with_poly_data(s, pulse_loop)
	return true
}

@(private)
capture_stop :: proc(s: ^Stream) {
	cap := (^Capture_Pulse)(s.platform)
	if cap == nil {
		return
	}
	sync.atomic_store(&cap.running, false)
	if cap.thread != nil {
		// pa_simple_read returns within one fragment while the source is running.
		thread.join(cap.thread)
		thread.destroy(cap.thread)
	}
	pulse.pa_simple_free(cap.simple)
	free(cap)
	s.platform = nil
}

@(private)
pulse_loop :: proc(s: ^Stream) {
	cap := (^Capture_Pulse)(s.platform)
	buf: [FRAME_SAMPLES / 2 * CHANNELS]i16
	for sync.atomic_load(&cap.running) {
		err: c.int
		if pulse.pa_simple_read(cap.simple, &buf[0], size_of(buf), &err) < 0 {
			utils.log_warn("audio capture stopped (PulseAudio error %d)", err)
			return
		}
		push_pcm(s, buf[:], now_ns())
	}
}
