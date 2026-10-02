package ffmpeg

// libavformat + libavdevice, used only to read raw frames from the
// screen-grab input devices (gdigrab, x11grab, avfoundation).

when ODIN_OS == .Windows {
	foreign import avformat "lib/avformat.lib"
	foreign import avdevice "lib/avdevice.lib"
} else {
	foreign import avformat "system:avformat"
	foreign import avdevice "system:avdevice"
}

@(default_calling_convention = "c")
foreign avformat {
	avformat_version :: proc() -> u32 ---
	av_find_input_format :: proc(short_name: cstring) -> ^AVInputFormat ---
	avformat_open_input :: proc(ps: ^^AVFormatContext, url: cstring, fmt: ^AVInputFormat, options: ^^AVDictionary) -> i32 ---
	avformat_close_input :: proc(ps: ^^AVFormatContext) ---
	av_read_frame :: proc(s: ^AVFormatContext, pkt: ^AVPacket) -> i32 ---
}

@(default_calling_convention = "c")
foreign avdevice {
	avdevice_register_all :: proc() ---
}
