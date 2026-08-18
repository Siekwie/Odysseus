package ffmpeg

when !STUB_LIBS && ODIN_OS == .Windows {
	foreign import avcodec "lib/avcodec.lib"
} else when !STUB_LIBS {
	foreign import avcodec "system:avcodec"
}

when STUB_LIBS {
	avcodec_find_encoder_by_name :: proc "c" (name: cstring) -> ^AVCodec { return nil }
	avcodec_find_encoder :: proc "c" (id: i32) -> ^AVCodec { return nil }
	avcodec_alloc_context3 :: proc "c" (codec: ^AVCodec) -> ^AVCodecContext { return nil }
	avcodec_free_context :: proc "c" (avctx: ^^AVCodecContext) {}
	avcodec_open2 :: proc "c" (avctx: ^AVCodecContext, codec: ^AVCodec, options: ^^AVDictionary) -> i32 { return -1 }
	av_packet_alloc :: proc "c" () -> ^AVPacket { return nil }
	av_packet_free :: proc "c" (pkt: ^^AVPacket) {}
	av_packet_unref :: proc "c" (pkt: ^AVPacket) {}
	avcodec_send_frame :: proc "c" (avctx: ^AVCodecContext, frame: ^AVFrame) -> i32 { return -1 }
	avcodec_receive_packet :: proc "c" (avctx: ^AVCodecContext, avpkt: ^AVPacket) -> i32 { return -1 }
	avcodec_flush_buffers :: proc "c" (avctx: ^AVCodecContext) {}
	avcodec_get_name :: proc "c" (id: i32) -> cstring { return nil }
	av_codec_is_encoder :: proc "c" (codec: ^AVCodec) -> i32 { return 0 }
} else {
	@(default_calling_convention = "c")
	foreign avcodec {
		avcodec_find_encoder_by_name :: proc(name: cstring) -> ^AVCodec ---
		avcodec_find_encoder :: proc(id: i32) -> ^AVCodec ---
		avcodec_alloc_context3 :: proc(codec: ^AVCodec) -> ^AVCodecContext ---
		avcodec_free_context :: proc(avctx: ^^AVCodecContext) ---
		avcodec_open2 :: proc(avctx: ^AVCodecContext, codec: ^AVCodec, options: ^^AVDictionary) -> i32 ---
		av_packet_alloc :: proc() -> ^AVPacket ---
		av_packet_free :: proc(pkt: ^^AVPacket) ---
		av_packet_unref :: proc(pkt: ^AVPacket) ---
		avcodec_send_frame :: proc(avctx: ^AVCodecContext, frame: ^AVFrame) -> i32 ---
		avcodec_receive_packet :: proc(avctx: ^AVCodecContext, avpkt: ^AVPacket) -> i32 ---
		avcodec_flush_buffers :: proc(avctx: ^AVCodecContext) ---
		avcodec_get_name :: proc(id: i32) -> cstring ---
		av_codec_is_encoder :: proc(codec: ^AVCodec) -> i32 ---
	}
}
