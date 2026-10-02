package ffmpeg

when ODIN_OS == .Windows {
	foreign import avcodec "lib/avcodec.lib"
} else {
	foreign import avcodec "system:avcodec"
}

@(default_calling_convention = "c")
foreign avcodec {
	avcodec_version :: proc() -> u32 ---

	avcodec_find_encoder_by_name :: proc(name: cstring) -> ^AVCodec ---
	avcodec_alloc_context3 :: proc(codec: ^AVCodec) -> ^AVCodecContext ---
	avcodec_free_context :: proc(avctx: ^^AVCodecContext) ---
	avcodec_open2 :: proc(avctx: ^AVCodecContext, codec: ^AVCodec, options: ^^AVDictionary) -> i32 ---
	avcodec_parameters_to_context :: proc(avctx: ^AVCodecContext, par: ^AVCodecParameters) -> i32 ---

	av_packet_alloc :: proc() -> ^AVPacket ---
	av_packet_free :: proc(pkt: ^^AVPacket) ---
	av_packet_unref :: proc(pkt: ^AVPacket) ---

	avcodec_send_frame :: proc(avctx: ^AVCodecContext, frame: ^AVFrame) -> i32 ---
	avcodec_receive_packet :: proc(avctx: ^AVCodecContext, avpkt: ^AVPacket) -> i32 ---
}
