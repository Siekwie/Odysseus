package audio

import "base:runtime"
import "core:strings"

import ma "vendor:miniaudio"

import "../utils"

// WASAPI loopback through miniaudio: captures what the selected output
// device plays, already converted to 48 kHz stereo S16.

@(private)
Capture_MA :: struct {
	ctx:      ma.context_type,
	device:   ma.device,
	have_ctx: bool,
	have_dev: bool,
}

@(private)
capture_start :: proc(s: ^Stream, device_name: string) -> bool {
	cap := new(Capture_MA)
	s.platform = cap

	if ma.context_init(nil, 0, nil, &cap.ctx) != .SUCCESS {
		utils.log_warn("audio disabled: no audio backend")
		capture_stop(s)
		return false
	}
	cap.have_ctx = true

	config := ma.device_config_init(.loopback)
	config.capture.format = .s16
	config.capture.channels = CHANNELS
	config.sampleRate = SAMPLE_RATE
	config.periodSizeInFrames = FRAME_SAMPLES / 2
	config.dataCallback = on_audio_data
	config.pUserData = s

	// Loopback records a *playback* device; pick it by name when asked.
	chosen: ma.device_id
	if device_name != "" {
		playback: [^]ma.device_info
		playback_count: u32
		found := false
		if ma.context_get_devices(&cap.ctx, &playback, &playback_count, nil, nil) == .SUCCESS {
			for &info in playback[:playback_count] {
				name := string(cstring(&info.name[0]))
				if strings.contains(strings.to_lower(name, context.temp_allocator), strings.to_lower(device_name, context.temp_allocator)) {
					chosen = info.id
					config.capture.pDeviceID = &chosen
					found = true
					utils.log_info("audio: capturing '%s'", name)
					break
				}
			}
		}
		if !found {
			utils.log_warn("audio device '%s' not found; using the default output", device_name)
		}
	}

	if ma.device_init(&cap.ctx, &config, &cap.device) != .SUCCESS {
		utils.log_warn("audio disabled: could not open the output device for loopback capture")
		capture_stop(s)
		return false
	}
	cap.have_dev = true
	if ma.device_start(&cap.device) != .SUCCESS {
		utils.log_warn("audio disabled: could not start loopback capture")
		capture_stop(s)
		return false
	}
	return true
}

@(private)
capture_stop :: proc(s: ^Stream) {
	cap := (^Capture_MA)(s.platform)
	if cap == nil {
		return
	}
	if cap.have_dev {
		ma.device_uninit(&cap.device) // stops the device and joins its thread
	}
	if cap.have_ctx {
		ma.context_uninit(&cap.ctx)
	}
	free(cap)
	s.platform = nil
}

@(private)
on_audio_data :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	context = runtime.default_context()
	s := (^Stream)(device.pUserData)
	if s == nil || input == nil || frame_count == 0 {
		return
	}
	push_pcm(s, ([^]i16)(input)[:frame_count * CHANNELS], now_ns())
}
