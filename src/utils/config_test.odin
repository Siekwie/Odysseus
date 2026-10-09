package utils

import "core:strings"
import "core:testing"

// Everything below only exists in `odin test` builds: the package directory is
// also built by a plain `odin build`, which must not compile (or break on) tests.
when ODIN_TEST {

// Unit tests for config_default / config_validate / scaled_size.

@(private = "file")
expect_valid :: proc(t: ^testing.T, cfg: Config, loc := #caller_location) {
	c := cfg
	msg := config_validate(&c)
	testing.expectf(t, msg == "", "expected valid config, got: %s", msg, loc = loc)
}

// Expects an error message that mentions `needle` (the flag name).
@(private = "file")
expect_invalid :: proc(t: ^testing.T, cfg: Config, needle: string, loc := #caller_location) {
	c := cfg
	msg := config_validate(&c)
	testing.expectf(t, msg != "", "expected an error mentioning %q, config was accepted", needle, loc = loc)
	if msg != "" {
		testing.expectf(t, strings.contains(msg, needle), "error %q does not mention %q", msg, needle, loc = loc)
	}
}

@(test)
test_default_config_is_valid :: proc(t: ^testing.T) {
	cfg := config_default()
	msg := config_validate(&cfg)
	testing.expect_value(t, msg, "")
	// Defaults are untouched by validation.
	d := config_default()
	testing.expect_value(t, cfg.port, d.port)
	testing.expect_value(t, cfg.capture, "auto")
	testing.expect_value(t, cfg.encoder, "h264")
}

@(test)
test_default_config_values :: proc(t: ^testing.T) {
	cfg := config_default()
	testing.expect_value(t, cfg.port, 8080)
	testing.expect_value(t, cfg.fps, 30)
	testing.expect_value(t, cfg.bitrate, 8000)
	testing.expect_value(t, cfg.width, 0)
	testing.expect_value(t, cfg.height, 0)
	testing.expect_value(t, cfg.monitor, 0)
	testing.expect_value(t, cfg.audio_bitrate, 128)
	testing.expect_value(t, cfg.password, "")
	testing.expect(t, !cfg.input, "remote control must be opt-in")
}

@(test)
test_validate_port :: proc(t: ^testing.T) {
	cfg := config_default()
	for p in ([]int{1, 80, 8080, 65535}) {
		cfg.port = p
		expect_valid(t, cfg)
	}
	for p in ([]int{0, -1, 65536, 100000, min(int), max(int)}) {
		cfg.port = p
		expect_invalid(t, cfg, "-port")
	}
}

@(test)
test_validate_fps :: proc(t: ^testing.T) {
	cfg := config_default()
	for v in ([]int{1, 24, 60, 144, 240}) {
		cfg.fps = v
		expect_valid(t, cfg)
	}
	for v in ([]int{0, -1, 241, 1000}) {
		cfg.fps = v
		expect_invalid(t, cfg, "-fps")
	}
}

@(test)
test_validate_bitrate :: proc(t: ^testing.T) {
	cfg := config_default()
	for v in ([]int{100, 8000, 500_000}) {
		cfg.bitrate = v
		expect_valid(t, cfg)
	}
	for v in ([]int{0, 99, -5, 500_001}) {
		cfg.bitrate = v
		expect_invalid(t, cfg, "-bitrate")
	}
}

@(test)
test_validate_audio_bitrate :: proc(t: ^testing.T) {
	cfg := config_default()
	for v in ([]int{16, 128, 510}) {
		cfg.audio_bitrate = v
		expect_valid(t, cfg)
	}
	for v in ([]int{0, 15, -1, 511}) {
		cfg.audio_bitrate = v
		expect_invalid(t, cfg, "-audio-bitrate")
	}
}

@(test)
test_validate_size :: proc(t: ^testing.T) {
	cfg := config_default()
	// Valid: both 0, one 0, at least 64, up to 8192.
	valid := [][2]int{{0, 0}, {1280, 0}, {0, 720}, {64, 64}, {1920, 1080}, {8192, 8192}, {0, 64}, {64, 0}}
	for sz in valid {
		cfg.width, cfg.height = sz[0], sz[1]
		expect_valid(t, cfg)
	}
	invalid := [][2]int{{-1, 0}, {0, -1}, {8193, 0}, {0, 8193}, {63, 0}, {0, 63}, {1, 1}, {1920, 63}, {63, 1080}, {-100, -100}}
	for sz in invalid {
		cfg.width, cfg.height = sz[0], sz[1]
		expect_invalid(t, cfg, "-width")
	}
}

@(test)
test_validate_monitor :: proc(t: ^testing.T) {
	cfg := config_default()
	for v in ([]int{0, 1, 7}) {
		cfg.monitor = v
		expect_valid(t, cfg)
	}
	cfg.monitor = -1
	expect_invalid(t, cfg, "-monitor")
	cfg.monitor = min(int)
	expect_invalid(t, cfg, "-monitor")
}

@(test)
test_validate_connection_limits :: proc(t: ^testing.T) {
	cfg := config_default()
	cfg.max_http, cfg.max_viewers = 0, 0 // 0 = unlimited
	expect_valid(t, cfg)
	cfg.max_http, cfg.max_viewers = 1, 1
	expect_valid(t, cfg)
	cfg = config_default()
	cfg.max_http = -1
	expect_invalid(t, cfg, "-max-http")
	cfg = config_default()
	cfg.max_viewers = -1
	expect_invalid(t, cfg, "-max-viewers")
}

@(test)
test_validate_capture_backend :: proc(t: ^testing.T) {
	cfg := config_default()
	for name in ([]string{"auto", "dxgi", "gdigrab", "x11", "pipewire", "avfoundation", "screencapturekit"}) {
		cfg.capture = name
		expect_valid(t, cfg)
		c := cfg
		config_validate(&c)
		testing.expect_value(t, c.capture, name)
	}
	for name in ([]string{"nope", "DXGI", "dxgi ", " auto", "x11,pipewire", "wayland"}) {
		cfg.capture = name
		expect_invalid(t, cfg, "-capture")
	}
}

@(test)
test_validate_normalizes_empty_strings :: proc(t: ^testing.T) {
	cfg := config_default()
	cfg.capture = ""
	cfg.encoder = ""
	msg := config_validate(&cfg)
	testing.expect_value(t, msg, "")
	testing.expect_value(t, cfg.capture, "auto")
	testing.expect_value(t, cfg.encoder, "h264")

	// A zero-value Config (nothing set by the CLI) is rejected for its numeric
	// fields, not accepted silently.
	zero: Config
	expect_invalid(t, zero, "-port")
}

@(test)
test_validate_reports_first_problem :: proc(t: ^testing.T) {
	cfg := config_default()
	cfg.port = 0
	cfg.fps = 0
	msg := config_validate(&cfg)
	testing.expect(t, strings.contains(msg, "-port"), "port is checked before fps")
}

@(test)
test_validate_does_not_mutate_on_error :: proc(t: ^testing.T) {
	// An invalid backend must not be rewritten.
	cfg := config_default()
	cfg.capture = "bogus"
	cfg.encoder = ""
	msg := config_validate(&cfg)
	testing.expect(t, msg != "")
	testing.expect_value(t, cfg.capture, "bogus")
}

// ---------------------------------------------------------------------------
// scaled_size
// ---------------------------------------------------------------------------

@(private = "file")
expect_size :: proc(t: ^testing.T, cw, ch, sw, sh, ew, eh: int, loc := #caller_location) {
	w, h := scaled_size(cw, ch, sw, sh)
	testing.expectf(t, w == ew && h == eh, "scaled_size(%d,%d, src %dx%d) = %dx%d, want %dx%d", cw, ch, sw, sh, w, h, ew, eh, loc = loc)
}

@(test)
test_scaled_size_zero_keeps_source :: proc(t: ^testing.T) {
	expect_size(t, 0, 0, 1920, 1080, 1920, 1080)
	expect_size(t, 0, 0, 2560, 1440, 2560, 1440)
	expect_size(t, 0, 0, 3840, 2160, 3840, 2160)
}

@(test)
test_scaled_size_odd_source_rounded_to_even :: proc(t: ^testing.T) {
	expect_size(t, 0, 0, 1921, 1081, 1920, 1080)
	expect_size(t, 0, 0, 1366, 767, 1366, 766)
	expect_size(t, 0, 0, 1023, 1023, 1022, 1022)
}

@(test)
test_scaled_size_explicit_both :: proc(t: ^testing.T) {
	// Both given: used as is (aspect ratio is the user's business), even.
	expect_size(t, 1280, 720, 1920, 1080, 1280, 720)
	expect_size(t, 1281, 721, 1920, 1080, 1280, 720)
	expect_size(t, 640, 640, 1920, 1080, 640, 640)
	expect_size(t, 3840, 2160, 1280, 720, 3840, 2160) // upscaling allowed
}

@(test)
test_scaled_size_width_only_keeps_aspect :: proc(t: ^testing.T) {
	expect_size(t, 1280, 0, 1920, 1080, 1280, 720)
	expect_size(t, 640, 0, 1920, 1080, 640, 360)
	expect_size(t, 1920, 0, 2560, 1440, 1920, 1080)
	expect_size(t, 1000, 0, 1920, 1080, 1000, 562) // 562.5 rounds to 563 -> even 562
	expect_size(t, 1280, 0, 1280, 800, 1280, 800)
	expect_size(t, 1280, 0, 1024, 768, 1280, 960)
	// Portrait source.
	expect_size(t, 540, 0, 1080, 1920, 540, 960)
}

@(test)
test_scaled_size_height_only_keeps_aspect :: proc(t: ^testing.T) {
	expect_size(t, 0, 720, 1920, 1080, 1280, 720)
	expect_size(t, 0, 360, 1920, 1080, 640, 360)
	expect_size(t, 0, 1080, 2560, 1440, 1920, 1080)
	expect_size(t, 0, 1000, 1920, 1080, 1778, 1000) // 1777.8 -> 1778
	expect_size(t, 0, 960, 1080, 1920, 540, 960)
}

@(test)
test_scaled_size_always_even_and_positive :: proc(t: ^testing.T) {
	sources := [][2]int{{1920, 1080}, {1366, 768}, {1921, 1081}, {800, 600}, {3440, 1440}, {1080, 1920}, {1, 1}, {7, 3}}
	for src in sources {
		for cw in 0 ..< 130 {
			w, h := scaled_size(cw, 0, src[0], src[1])
			testing.expectf(t, w >= 2 && h >= 2 && w % 2 == 0 && h % 2 == 0, "width %d, src %dx%d -> %dx%d", cw, src[0], src[1], w, h)
			w, h = scaled_size(0, cw, src[0], src[1])
			testing.expectf(t, w >= 2 && h >= 2 && w % 2 == 0 && h % 2 == 0, "height %d, src %dx%d -> %dx%d", cw, src[0], src[1], w, h)
		}
	}
}

@(test)
test_scaled_size_tiny_and_extreme_aspect :: proc(t: ^testing.T) {
	// Very wide source: the derived dimension would be 0 but must stay >= 2,
	// and a derived dimension beyond MAX_DIMENSION shrinks both to fit.
	expect_size(t, 0, 64, 10000, 10, 8192, 8)
	expect_size(t, 64, 0, 10000, 10, 64, 2) // 64*10/10000 = 0.064 -> 0 -> min 2
	expect_size(t, 64, 0, 10, 10000, 8, 8192)
	expect_size(t, 2, 2, 100, 100, 2, 2)
	expect_size(t, 1, 1, 100, 100, 2, 2)
	expect_size(t, 3, 3, 100, 100, 2, 2)
}

@(test)
test_scaled_size_unknown_source :: proc(t: ^testing.T) {
	// Capture size not known (0): fall back to the configured size, even, at least 2.
	expect_size(t, 1280, 720, 0, 0, 1280, 720)
	expect_size(t, 1281, 721, 0, 0, 1280, 720)
	expect_size(t, 0, 0, 0, 0, 2, 2)
	expect_size(t, 1280, 0, 0, 0, 1280, 2)
	expect_size(t, 0, 720, 0, 0, 2, 720)
	expect_size(t, 640, 480, -1, -1, 640, 480)
	expect_size(t, 640, 480, 1920, 0, 640, 480)
}

@(test)
test_scaled_size_negative_config_is_treated_as_unset :: proc(t: ^testing.T) {
	expect_size(t, -5, -5, 1920, 1080, 1920, 1080)
	expect_size(t, -5, 720, 1920, 1080, 1280, 720)
	expect_size(t, 1280, -5, 1920, 1080, 1280, 720)
}

@(test)
test_scaled_size_large_values_do_not_overflow :: proc(t: ^testing.T) {
	// Largest accepted -width/-height against a huge source.
	expect_size(t, 8192, 0, 16384, 16384, 8192, 8192)
	expect_size(t, 0, 8192, 16384, 8192, 8192, 4096) // derived width clamped, aspect kept
	expect_size(t, 0, 0, 16384, 8192, 8192, 4096)    // native size beyond the limit
	expect_size(t, 0, 721, 1920, 1080, 1280, 720)    // odd request rounds first, then derives
}

} // when ODIN_TEST
