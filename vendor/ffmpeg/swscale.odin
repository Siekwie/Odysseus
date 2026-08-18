package ffmpeg

when !STUB_LIBS && ODIN_OS == .Windows {
	foreign import swscale "lib/swscale.lib"
} else when !STUB_LIBS {
	foreign import swscale "system:swscale"
}

when STUB_LIBS {
	sws_getContext :: proc "c" (
		srcW, srcH: i32,
		srcFormat: Pixel_Format,
		dstW, dstH: i32,
		dstFormat: Pixel_Format,
		flags: i32,
		srcFilter, dstFilter: ^Sws_Filter,
		param: [^]f64,
	) -> ^Sws_Context { return nil }

	sws_getCachedContext :: proc "c" (
		ctx: ^Sws_Context,
		srcW, srcH: i32,
		srcFormat: Pixel_Format,
		dstW, dstH: i32,
		dstFormat: Pixel_Format,
		flags: i32,
		srcFilter, dstFilter: ^Sws_Filter,
		param: [^]f64,
	) -> ^Sws_Context { return nil }

	sws_scale :: proc "c" (
		c: ^Sws_Context,
		srcSlice: [^]^u8,
		srcStride: [^]i32,
		srcSliceY, srcSliceH: i32,
		dst: [^]^u8,
		dstStride: [^]i32,
	) -> i32 { return 0 }

	sws_freeContext :: proc "c" (swsContext: ^Sws_Context) {}
} else {
	@(default_calling_convention = "c")
	foreign swscale {
		sws_getContext :: proc(
			srcW, srcH: i32,
			srcFormat: Pixel_Format,
			dstW, dstH: i32,
			dstFormat: Pixel_Format,
			flags: i32,
			srcFilter, dstFilter: ^Sws_Filter,
			param: [^]f64,
		) -> ^Sws_Context ---

		sws_getCachedContext :: proc(
			ctx: ^Sws_Context,
			srcW, srcH: i32,
			srcFormat: Pixel_Format,
			dstW, dstH: i32,
			dstFormat: Pixel_Format,
			flags: i32,
			srcFilter, dstFilter: ^Sws_Filter,
			param: [^]f64,
		) -> ^Sws_Context ---

		sws_scale :: proc(
			c: ^Sws_Context,
			srcSlice: [^]^u8,
			srcStride: [^]i32,
			srcSliceY, srcSliceH: i32,
			dst: [^]^u8,
			dstStride: [^]i32,
		) -> i32 ---

		sws_freeContext :: proc(swsContext: ^Sws_Context) ---
	}
}
