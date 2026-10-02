package ffmpeg

when ODIN_OS == .Windows {
	foreign import swscale "lib/swscale.lib"
} else {
	foreign import swscale "system:swscale"
}

@(default_calling_convention = "c")
foreign swscale {
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
		srcSlice: [^][^]u8,
		srcStride: [^]i32,
		srcSliceY, srcSliceH: i32,
		dst: [^][^]u8,
		dstStride: [^]i32,
	) -> i32 ---

	sws_freeContext :: proc(swsContext: ^Sws_Context) ---

	sws_getCoefficients :: proc(colorspace: i32) -> [^]i32 ---
	sws_setColorspaceDetails :: proc(
		c: ^Sws_Context,
		inv_table: [^]i32,
		srcRange: i32,
		table: [^]i32,
		dstRange: i32,
		brightness, contrast, saturation: i32,
	) -> i32 ---
}
