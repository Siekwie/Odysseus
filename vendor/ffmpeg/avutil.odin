package ffmpeg

when !STUB_LIBS && ODIN_OS == .Windows {
	foreign import avutil "lib/avutil.lib"
} else when !STUB_LIBS {
	foreign import avutil "system:avutil"
}

when STUB_LIBS {
	av_frame_alloc :: proc "c" () -> ^AVFrame { return nil }
	av_frame_free :: proc "c" (frame: ^^AVFrame) {}
	av_frame_unref :: proc "c" (frame: ^AVFrame) {}
	av_frame_get_buffer :: proc "c" (frame: ^AVFrame, align: i32) -> i32 { return -1 }
	av_frame_make_writable :: proc "c" (frame: ^AVFrame) -> i32 { return -1 }

	av_malloc :: proc "c" (size: uint) -> rawptr { return nil }
	av_mallocz :: proc "c" (size: uint) -> rawptr { return nil }
	av_free :: proc "c" (ptr: rawptr) {}
	av_freep :: proc "c" (ptr: rawptr) {}

	av_dict_set :: proc "c" (pm: ^^AVDictionary, key, value: cstring, flags: i32) -> i32 { return -1 }
	av_dict_free :: proc "c" (m: ^^AVDictionary) {}

	av_opt_set :: proc "c" (obj: rawptr, name, val: cstring, search_flags: i32) -> i32 { return -1 }
	av_opt_set_int :: proc "c" (obj: rawptr, name: cstring, val: i64, search_flags: i32) -> i32 { return -1 }
	av_opt_set_double :: proc "c" (obj: rawptr, name: cstring, val: f64, search_flags: i32) -> i32 { return -1 }

	av_strerror :: proc "c" (errnum: i32, errbuf: [^]u8, errbuf_size: int) -> i32 { return -1 }
	av_log_set_level :: proc "c" (level: i32) {}
	av_log_get_level :: proc "c" () -> i32 { return 0 }

	av_image_get_buffer_size :: proc "c" (pix_fmt: Pixel_Format, width, height, align: i32) -> i32 { return -1 }
	av_image_fill_arrays :: proc "c" (
		dst_data: [^][^]u8,
		dst_linesize: [^]i32,
		src: [^]u8,
		pix_fmt: Pixel_Format,
		width, height, align: i32,
	) -> i32 { return -1 }

	av_rescale_q :: proc "c" (a: i64, bq, cq: AVRational) -> i64 { return 0 }
	av_gettime_relative :: proc "c" () -> i64 { return 0 }

	av_hwdevice_ctx_create :: proc "c" (
		device_ctx: ^^AVBuffer_Ref,
		type: HW_Device_Type,
		device: cstring,
		opts: ^AVDictionary,
		flags: i32,
	) -> i32 { return -1 }
	av_hwdevice_find_type_by_name :: proc "c" (name: cstring) -> HW_Device_Type { return .None }
	av_hwdevice_get_type_name :: proc "c" (type: HW_Device_Type) -> cstring { return nil }
	av_hwdevice_iterate_types :: proc "c" (prev: HW_Device_Type) -> HW_Device_Type { return .None }
	av_buffer_ref :: proc "c" (buf: ^AVBuffer_Ref) -> ^AVBuffer_Ref { return nil }
	av_buffer_unref :: proc "c" (buf: ^^AVBuffer_Ref) {}
	av_hwdevice_ctx_alloc :: proc "c" (_: HW_Device_Type) -> ^AVBuffer_Ref { return nil }
	av_hwdevice_ctx_init :: proc "c" (_: ^AVBuffer_Ref) -> i32 { return -1 }
	av_hwframe_ctx_alloc :: proc "c" (_: ^AVBuffer_Ref) -> ^AVBuffer_Ref { return nil }
	av_hwframe_ctx_init :: proc "c" (_: ^AVBuffer_Ref) -> i32 { return -1 }
	av_hwframe_get_buffer :: proc "c" (_: ^AVBuffer_Ref, _: ^AVFrame, _: i32) -> i32 { return -1 }
	av_get_pix_fmt :: proc "c" (_: cstring) -> Pixel_Format { return PIX_FMT_NONE }
} else {
	@(default_calling_convention = "c")
	foreign avutil {
		av_frame_alloc :: proc() -> ^AVFrame ---
		av_frame_free :: proc(frame: ^^AVFrame) ---
		av_frame_unref :: proc(frame: ^AVFrame) ---
		av_frame_get_buffer :: proc(frame: ^AVFrame, align: i32) -> i32 ---
		av_frame_make_writable :: proc(frame: ^AVFrame) -> i32 ---

		av_malloc :: proc(size: uint) -> rawptr ---
		av_mallocz :: proc(size: uint) -> rawptr ---
		av_free :: proc(ptr: rawptr) ---
		av_freep :: proc(ptr: rawptr) ---

		av_dict_set :: proc(pm: ^^AVDictionary, key, value: cstring, flags: i32) -> i32 ---
		av_dict_free :: proc(m: ^^AVDictionary) ---

		av_opt_set :: proc(obj: rawptr, name, val: cstring, search_flags: i32) -> i32 ---
		av_opt_set_int :: proc(obj: rawptr, name: cstring, val: i64, search_flags: i32) -> i32 ---
		av_opt_set_double :: proc(obj: rawptr, name: cstring, val: f64, search_flags: i32) -> i32 ---

		av_strerror :: proc(errnum: i32, errbuf: [^]u8, errbuf_size: int) -> i32 ---
		av_log_set_level :: proc(level: i32) ---
		av_log_get_level :: proc() -> i32 ---

		av_image_get_buffer_size :: proc(pix_fmt: Pixel_Format, width, height, align: i32) -> i32 ---
		av_image_fill_arrays :: proc(
			dst_data: [^][^]u8,
			dst_linesize: [^]i32,
			src: [^]u8,
			pix_fmt: Pixel_Format,
			width, height, align: i32,
		) -> i32 ---

		av_rescale_q :: proc(a: i64, bq, cq: AVRational) -> i64 ---
		av_gettime_relative :: proc() -> i64 ---

		av_hwdevice_ctx_create :: proc(
			device_ctx: ^^AVBuffer_Ref,
			type: HW_Device_Type,
			device: cstring,
			opts: ^AVDictionary,
			flags: i32,
		) -> i32 ---
		av_hwdevice_find_type_by_name :: proc(name: cstring) -> HW_Device_Type ---
		av_hwdevice_get_type_name :: proc(type: HW_Device_Type) -> cstring ---
		av_hwdevice_iterate_types :: proc(prev: HW_Device_Type) -> HW_Device_Type ---
		av_buffer_ref :: proc(buf: ^AVBuffer_Ref) -> ^AVBuffer_Ref ---
		av_buffer_unref :: proc(buf: ^^AVBuffer_Ref) ---
		av_hwdevice_ctx_alloc :: proc(type: HW_Device_Type) -> ^AVBuffer_Ref ---
		av_hwdevice_ctx_init :: proc(ref: ^AVBuffer_Ref) -> i32 ---
		av_hwframe_ctx_alloc :: proc(device_ref: ^AVBuffer_Ref) -> ^AVBuffer_Ref ---
		av_hwframe_ctx_init :: proc(ref: ^AVBuffer_Ref) -> i32 ---
		av_hwframe_get_buffer :: proc(hwframe_ctx: ^AVBuffer_Ref, frame: ^AVFrame, flags: i32) -> i32 ---
		av_get_pix_fmt :: proc(name: cstring) -> Pixel_Format ---
	}
}
