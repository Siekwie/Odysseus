package ffmpeg

// Hardware context structs, used by the D3D11 zero-copy path on Windows.
// Layouts match libavutil/hwcontext.h and hwcontext_d3d11va.h (FFmpeg 6-8).

AVHWDeviceContext :: struct {
	av_class:    rawptr,
	type:        HW_Device_Type,
	hwctx:       rawptr,
	free:        proc "c" (_: ^AVHWDeviceContext),
	user_opaque: rawptr,
}

AVHWFramesContext :: struct {
	av_class:          rawptr,
	device_ref:        ^AVBuffer_Ref,
	device_ctx:        ^AVHWDeviceContext,
	hwctx:             rawptr,
	free:              proc "c" (_: ^AVHWFramesContext),
	user_opaque:       rawptr,
	pool:              rawptr,
	initial_pool_size: i32,
	format:            Pixel_Format,
	sw_format:         Pixel_Format,
	width:             i32,
	height:            i32,
}

AVD3D11VADeviceContext :: struct {
	device:         rawptr, // ID3D11Device*
	device_context: rawptr, // ID3D11DeviceContext*
	video_device:   rawptr,
	video_context:  rawptr,
	lock:           proc "c" (_: rawptr),
	unlock:         proc "c" (_: rawptr),
	lock_ctx:       rawptr,
	bind_flags:     u32,
	misc_flags:     u32,
}
