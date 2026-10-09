package ffmpeg

when ODIN_OS == .Windows {
	foreign import avutil "lib/avutil.lib"
} else {
	foreign import avutil "system:avutil"
}

@(default_calling_convention = "c")
foreign avutil {
	avutil_version :: proc() -> u32 ---

	av_frame_alloc :: proc() -> ^AVFrame ---
	av_frame_free :: proc(frame: ^^AVFrame) ---
	av_frame_unref :: proc(frame: ^AVFrame) ---
	av_frame_get_buffer :: proc(frame: ^AVFrame, align: i32) -> i32 ---
	av_frame_make_writable :: proc(frame: ^AVFrame) -> i32 ---

	av_malloc :: proc(size: uint) -> rawptr ---
	av_free :: proc(ptr: rawptr) ---

	av_dict_set :: proc(pm: ^^AVDictionary, key, value: cstring, flags: i32) -> i32 ---
	av_dict_free :: proc(m: ^^AVDictionary) ---

	av_opt_set :: proc(obj: rawptr, name, val: cstring, search_flags: i32) -> i32 ---
	av_opt_set_int :: proc(obj: rawptr, name: cstring, val: i64, search_flags: i32) -> i32 ---
	av_opt_set_q :: proc(obj: rawptr, name: cstring, val: AVRational, search_flags: i32) -> i32 ---
	av_opt_set_image_size :: proc(obj: rawptr, name: cstring, w, h: i32, search_flags: i32) -> i32 ---
	av_opt_set_pixel_fmt :: proc(obj: rawptr, name: cstring, fmt: Pixel_Format, search_flags: i32) -> i32 ---
	av_opt_set_sample_fmt :: proc(obj: rawptr, name: cstring, fmt: Sample_Format, search_flags: i32) -> i32 ---
	av_opt_get_int :: proc(obj: rawptr, name: cstring, search_flags: i32, out_val: ^i64) -> i32 ---
	av_opt_get_image_size :: proc(obj: rawptr, name: cstring, search_flags: i32, w_out, h_out: ^i32) -> i32 ---
	av_opt_get_pixel_fmt :: proc(obj: rawptr, name: cstring, search_flags: i32, out_fmt: ^Pixel_Format) -> i32 ---
	av_opt_get_sample_fmt :: proc(obj: rawptr, name: cstring, search_flags: i32, out_fmt: ^Sample_Format) -> i32 ---

	av_strerror :: proc(errnum: i32, errbuf: [^]u8, errbuf_size: uint) -> i32 ---
	av_log_set_level :: proc(level: i32) ---
	av_log_get_level :: proc() -> i32 ---

	av_get_pix_fmt :: proc(name: cstring) -> Pixel_Format ---
	av_get_pix_fmt_name :: proc(fmt: Pixel_Format) -> cstring ---

	av_buffer_alloc :: proc(size: uint) -> ^AVBuffer_Ref ---
	av_buffer_ref :: proc(buf: ^AVBuffer_Ref) -> ^AVBuffer_Ref ---
	av_buffer_unref :: proc(buf: ^^AVBuffer_Ref) ---

	av_hwdevice_ctx_create :: proc(device_ctx: ^^AVBuffer_Ref, type: HW_Device_Type, device: cstring, opts: ^AVDictionary, flags: i32) -> i32 ---
	av_hwframe_transfer_data :: proc(dst, src: ^AVFrame, flags: i32) -> i32 ---
	av_hwdevice_ctx_alloc :: proc(type: HW_Device_Type) -> ^AVBuffer_Ref ---
	av_hwdevice_ctx_init :: proc(ref: ^AVBuffer_Ref) -> i32 ---
	av_hwframe_ctx_alloc :: proc(device_ref: ^AVBuffer_Ref) -> ^AVBuffer_Ref ---
	av_hwframe_ctx_init :: proc(ref: ^AVBuffer_Ref) -> i32 ---
	av_hwframe_get_buffer :: proc(hwframe_ctx: ^AVBuffer_Ref, frame: ^AVFrame, flags: i32) -> i32 ---
}
