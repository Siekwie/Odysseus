package main

import "core:fmt"

import "src/audio"
import "src/core"

import ffmpeg "./vendor/ffmpeg"

// `odysseus -self-test`: encodes synthetic video and audio with the FFmpeg the
// program is actually linked against and checks the results. It needs no
// screen, sound device or network, so it is what CI runs on every platform;
// its main job is to catch an FFmpeg release whose ABI the bindings in
// vendor/ffmpeg get wrong (see abi.odin).

@(private = "file")
TEST_W :: 320
@(private = "file")
TEST_H :: 240
@(private = "file")
TEST_FRAMES :: 12
@(private = "file")
TEST_FORCED :: 6 // frame at which a keyframe is requested

// Returns true when everything passed.
self_test :: proc() -> bool {
	v := ffmpeg.versions()
	fmt.printf("FFmpeg: libavutil %d, libavcodec %d, libavformat %d\n", v.avutil, v.avcodec, v.avformat)

	ok := true
	working := core.probe_encoders()
	defer delete(working)
	if len(working) == 0 {
		fmt.println("FAIL  video: no H.264 encoder opens on this machine")
		ok = false
	}
	for name in working {
		ok = self_test_video(name) && ok
	}

	packets, bytes, audio_ok := audio.encode_test(25)
	if audio_ok && packets >= 20 && bytes > 0 {
		fmt.printf("ok    audio: libopus, %d packets, %d bytes\n", packets, bytes)
	} else if !audio_ok {
		// Not fatal for the program (video still works), but the reason should be known.
		fmt.println("FAIL  audio: the Opus encoder could not be set up")
		ok = false
	} else {
		fmt.printf("FAIL  audio: only %d packets (%d bytes) for 25 frames\n", packets, bytes)
		ok = false
	}

	fmt.println("self-test passed" if ok else "self-test FAILED")
	return ok
}

// Encodes a moving gradient and checks that keyframes appear exactly where asked.
@(private = "file")
self_test_video :: proc(name: string) -> bool {
	enc, err := core.encoder_open(name, {width = TEST_W, height = TEST_H, fps = 30, bitrate_kbps = 2000})
	if err != .None {
		fmt.printf("FAIL  video: %s stopped opening (%v)\n", name, err)
		return false
	}
	defer core.encoder_close(enc)

	pixels := make([]u8, TEST_W * TEST_H * 4)
	defer delete(pixels)
	frame := core.Frame{
		width  = TEST_W,
		height = TEST_H,
		format = ffmpeg.pix_fmt("bgra"),
	}
	frame.planes[0] = raw_data(pixels)
	frame.strides[0] = TEST_W * 4

	units: [dynamic]core.Encoded_AU
	defer {
		for au in units {
			delete(au.data)
		}
		delete(units)
	}

	for n in 0 ..< TEST_FRAMES {
		for y in 0 ..< TEST_H {
			for x in 0 ..< TEST_W {
				i := (y * TEST_W + x) * 4
				pixels[i] = u8(x + n * 7)
				pixels[i + 1] = u8(y + n * 3)
				pixels[i + 2] = u8(x + y)
				pixels[i + 3] = 255
			}
		}
		if n == TEST_FORCED {
			core.encoder_request_keyframe(enc)
		}
		if e := core.encoder_encode(enc, &frame, &units); e != .None {
			fmt.printf("FAIL  video: %s failed on frame %d (%v)\n", name, n, e)
			return false
		}
		free_all(context.temp_allocator)
	}

	keyframes := 0
	forced_at := -1
	for au, i in units {
		if !au.is_keyframe {
			continue
		}
		keyframes += 1
		if i > 0 && forced_at < 0 {
			forced_at = i
		}
		// A keyframe must start with the SPS+PPS aggregation packet.
		if len(au.data) < 5 || core.nal_type(au.data[4:]) != core.NAL_STAP_A {
			fmt.printf("FAIL  video: %s keyframe %d carries no parameter sets\n", name, i)
			return false
		}
	}

	// Media Foundation buffers frames and has no way to force a keyframe; all
	// that can be checked is that it produces a decodable start.
	lenient := name == "h264_mf"

	switch {
	case len(units) == 0:
		fmt.printf("FAIL  video: %s produced no output\n", name)
	case !units[0].is_keyframe:
		fmt.printf("FAIL  video: %s did not start with a keyframe\n", name)
	case lenient:
		fmt.printf("ok    video: %s, %d of %d frames out so far, %d keyframe(s) (requests not supported)\n", name, len(units), TEST_FRAMES, keyframes)
		return true
	case keyframes != 2:
		// 1: the keyframe request was not understood (wrong pict_type offset).
		// >2: ordinary frames are read as keyframe requests.
		fmt.printf("FAIL  video: %s produced %d keyframes in %d frames, expected 2 (first frame + the one requested)\n", name, keyframes, len(units))
	case len(units) == TEST_FRAMES && forced_at != TEST_FORCED:
		fmt.printf("FAIL  video: %s put the requested keyframe at frame %d instead of %d\n", name, forced_at, TEST_FORCED)
	case:
		fmt.printf("ok    video: %s, %d frames, keyframes at 0 and %d\n", name, len(units), forced_at)
		return true
	}
	return false
}
