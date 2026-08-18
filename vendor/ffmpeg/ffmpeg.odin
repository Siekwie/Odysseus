package ffmpeg

// Minimal Odin bindings for the FFmpeg pieces Odysseus uses:
// libavcodec (H.264 encode), libavutil (frames/packets/options), libswscale (BGRA -> YUV).
//
// Layouts target FFmpeg 8.x (n8.1 shared build vendored under lib/ and bin/).
//   vendor/ffmpeg/lib/{avcodec,avutil,swscale}.lib
//   vendor/ffmpeg/bin/*.dll  (copied into build/ by build.ps1)

STUB_LIBS :: !#exists("lib/avcodec.lib")

rational :: proc(num, den: i32) -> AVRational {
	return {num, den}
}

error_string :: proc(err: i32, buf: []u8) -> string {
	if len(buf) == 0 {
		return ""
	}
	n := av_strerror(err, raw_data(buf), len(buf))
	if n < 0 {
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
