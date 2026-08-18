package ffmpeg

// FFmpeg n8.1 (Windows x64): offsetof(AVCodecContext, hw_frames_ctx) == 552
HW_FRAMES_CTX_OFFSET :: 552

// FFmpeg n8.1 win64: AV_PIX_FMT_D3D11 is 171 (not 172 — that is GRAY9BE). Prefer runtime lookup.
PIX_FMT_D3D11_FALLBACK :: Pixel_Format(171)

pix_fmt_d3d11 :: proc() -> Pixel_Format {
	when STUB_LIBS {
		return PIX_FMT_D3D11_FALLBACK
	}
	fmt := av_get_pix_fmt("d3d11")
	if fmt == PIX_FMT_NONE {
		return PIX_FMT_D3D11_FALLBACK
	}
	return fmt
}

AVClass :: struct {}

AVBufferPool :: struct {}

AVHWDeviceContext :: struct {
	av_class:    ^AVClass,
	type:        HW_Device_Type,
	hwctx:       rawptr,
	free:        proc "c" (_: ^AVHWDeviceContext),
	user_opaque: rawptr,
}

AVHWFramesContext :: struct {
	av_class:           ^AVClass,
	device_ref:         ^AVBuffer_Ref,
	device_ctx:         ^AVHWDeviceContext,
	hwctx:              rawptr,
	free:               proc "c" (_: ^AVHWFramesContext),
	user_opaque:        rawptr,
	pool:               ^AVBufferPool,
	initial_pool_size:  i32,
	format:             Pixel_Format,
	sw_format:          Pixel_Format,
	width:              i32,
	height:             i32,
}

// Matches libavutil/hwcontext_d3d11va.h (FFmpeg 8.x).
AVD3D11VADeviceContext :: struct {
	device:          rawptr, // ^d3d11.IDevice
	device_context:  rawptr, // ^d3d11.IDeviceContext
	video_device:    rawptr,
	video_context:   rawptr,
	lock:            proc "c" (_: rawptr),
	unlock:          proc "c" (_: rawptr),
	lock_ctx:        rawptr,
	bind_flags:      u32,
	misc_flags:      u32,
}

AVD3D11VAFramesContext :: struct {
	texture:       rawptr,
	bind_flags:    u32,
	misc_flags:    u32,
	texture_infos: rawptr,
}

codec_ctx_hw_frames :: proc(ctx: ^AVCodecContext) -> ^^AVBuffer_Ref {
	when ODIN_ARCH == .amd64 && ODIN_OS == .Windows {
		return (^^AVBuffer_Ref)(uintptr(ctx) + HW_FRAMES_CTX_OFFSET)
	}
	when ODIN_OS == .Windows {
		panic("unsupported architecture for FFmpeg hw_frames_ctx offset")
	}
	return nil
}

codec_set_hw_frames_ctx :: proc(ctx: ^AVCodecContext, frames: ^AVBuffer_Ref) {
	dst := codec_ctx_hw_frames(ctx)
	if dst == nil {
		return
	}
	if dst^ != nil {
		av_buffer_unref(dst)
	}
	dst^ = av_buffer_ref(frames)
}
