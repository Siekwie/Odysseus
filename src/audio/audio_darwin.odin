package audio

import "base:runtime"
import "core:c"

import "../utils"

// macOS has no loopback device; the only way to record what the speakers play
// is ScreenCaptureKit's system audio (macOS 13+), whichever video backend is
// in use. The Objective-C side lives in src/native/sck_capture.m and is only
// linked when the build passes -define:ODYSSEUS_SCK=true.

ODYSSEUS_SCK :: #config(ODYSSEUS_SCK, false)

when ODYSSEUS_SCK {

foreign import sck_native "system:odysseus_native"

@(private)
SCK_Audio :: distinct rawptr

@(private)
SCK_Audio_Proc :: #type proc "c" (user: rawptr, samples: [^]f32, frame_count: c.int)

@(private, default_calling_convention = "c")
foreign sck_native {
	ody_sck_audio_start :: proc(cb: SCK_Audio_Proc, user: rawptr, err: [^]u8, err_len: c.int) -> SCK_Audio ---
	ody_sck_audio_stop :: proc(a: SCK_Audio) ---
}

@(private)
capture_start :: proc(s: ^Stream, device_name: string) -> bool {
	if device_name != "" {
		utils.log_info("audio: macOS captures the system mix; ignoring -audio-device '%s'", device_name)
	}
	reason: [256]u8
	handle := ody_sck_audio_start(on_sck_audio, s, raw_data(reason[:]), len(reason))
	if handle == nil {
		reason[len(reason) - 1] = 0
		utils.log_warn("audio disabled: %s", string(cstring(raw_data(reason[:]))))
		return false
	}
	s.platform = rawptr(handle)
	return true
}

@(private)
capture_stop :: proc(s: ^Stream) {
	handle := SCK_Audio(s.platform)
	if handle == nil {
		return
	}
	ody_sck_audio_stop(handle) // returns once no callback is running any more
	s.platform = nil
}

// Called on a ScreenCaptureKit queue with interleaved stereo float at 48 kHz.
@(private)
on_sck_audio :: proc "c" (user: rawptr, samples: [^]f32, frame_count: c.int) {
	context = runtime.default_context()
	s := (^Stream)(user)
	if s == nil || samples == nil || frame_count <= 0 {
		return
	}
	push_pcm_f32(s, samples[:int(frame_count) * CHANNELS], now_ns())
}

} else {

@(private)
capture_start :: proc(s: ^Stream, device_name: string) -> bool {
	utils.log_info("audio is not available: this build has no ScreenCaptureKit support")
	return false
}

@(private)
capture_stop :: proc(s: ^Stream) {
}

}
