package ffmpeg

// Minimal Odin bindings for the FFmpeg pieces Odysseus uses:
//   libavcodec  (H.264 / Opus encode)
//   libavutil   (frames, options, hardware contexts)
//   libswscale  (pixel format conversion and scaling)
//   libavformat + libavdevice (screen grab devices: gdigrab, x11grab, avfoundation)
//
// Windows links the import libraries vendored under lib/ (FFmpeg n8.1 shared);
// the DLLs in bin/ are copied next to the executable by build.ps1.
// Linux and macOS link the system libraries, whose version varies by distro.
// To stay ABI-compatible with FFmpeg 6, 7 and 8 the bindings never touch
// AVCodecContext fields directly (everything goes through AVOptions) and the
// few AVFrame fields that moved between releases are reached through abi.odin.

import "core:strings"

rational :: proc(num, den: i32) -> AVRational {
	return {num, den}
}

// error_string formats an FFmpeg error code into buf.
error_string :: proc(err: i32, buf: []u8) -> string {
	if len(buf) == 0 {
		return ""
	}
	if av_strerror(err, raw_data(buf), uint(len(buf))) < 0 {
		return "unknown ffmpeg error"
	}
	return string(cstring(raw_data(buf)))
}

is_again :: proc(err: i32) -> bool {
	return err == AVERROR_EAGAIN
}

is_eof :: proc(err: i32) -> bool {
	return err == AVERROR_EOF
}

// pix_fmt looks a pixel format up by name. Numeric values are not stable across releases.
pix_fmt :: proc(name: cstring) -> Pixel_Format {
	return av_get_pix_fmt(name)
}

pix_fmt_name :: proc(fmt: Pixel_Format) -> string {
	name := av_get_pix_fmt_name(fmt)
	if name == nil {
		return "unknown"
	}
	return string(name)
}

// dict_set copies key and value into the dictionary.
dict_set :: proc(dict: ^^AVDictionary, key, value: string) {
	k := strings.clone_to_cstring(key, context.temp_allocator)
	v := strings.clone_to_cstring(value, context.temp_allocator)
	av_dict_set(dict, k, v, 0)
}
