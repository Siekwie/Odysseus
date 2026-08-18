package core

import d3d11 "vendor:directx/d3d11"
import ffmpeg "../../vendor/ffmpeg"
import "../utils"
import "core:fmt"

// D3D11 texture -> h264_nvenc via FFmpeg hardware frames (no full-frame CPU readback).

Encoder_HW :: struct {
	base:           Encoder,
	hw_device:      ^ffmpeg.AVBuffer_Ref,
	hw_frames:      ^ffmpeg.AVBuffer_Ref,
	d3d_device:     ^d3d11.IDevice,
	d3d_context:    ^d3d11.IDeviceContext,
}

@(private)
d3d11va_from_hw_device :: proc(ref: ^ffmpeg.AVBuffer_Ref) -> ^ffmpeg.AVD3D11VADeviceContext {
	if ref == nil || ref.data == nil {
		return nil
	}
	hw_dev := cast(^ffmpeg.AVHWDeviceContext)(ref.data)
	if hw_dev.hwctx == nil {
		return nil
	}
	return cast(^ffmpeg.AVD3D11VADeviceContext)(hw_dev.hwctx)
}

@(private)
d3d11va_lock :: proc(ref: ^ffmpeg.AVBuffer_Ref) {
	va := d3d11va_from_hw_device(ref)
	if va != nil && va.lock != nil {
		va.lock(va.lock_ctx)
	}
}

@(private)
d3d11va_unlock :: proc(ref: ^ffmpeg.AVBuffer_Ref) {
	va := d3d11va_from_hw_device(ref)
	if va != nil && va.unlock != nil {
		va.unlock(va.lock_ctx)
	}
}

// Open NVENC fed by D3D11 textures on an existing capture device. Falls back caller-side on error.
encoder_open_d3d11 :: proc(
	cfg: utils.Config,
	device: ^d3d11.IDevice,
	imm: ^d3d11.IDeviceContext,
) -> (enc: Encoder_HW, err: Encoder_Error) {
	when ffmpeg.STUB_LIBS {
		return {}, .Stub_Libs
	}

	name := cstring("h264_nvenc")
	if cfg.encoder != "" && cfg.encoder != "h264" {
		name = resolve_encoder_name(cfg.encoder)
	}
	codec := ffmpeg.avcodec_find_encoder_by_name(name)
	if codec == nil || string(name) != "h264_nvenc" {
		return {}, .Codec_Not_Found
	}

	w := i32(cfg.width)
	h := i32(cfg.height)
	fps := i32(cfg.fps)
	if w <= 0 { w = 1920 }
	if h <= 0 { h = 1080 }
	if fps <= 0 { fps = 30 }

	hw_device := ffmpeg.av_hwdevice_ctx_alloc(.D3d11va)
	if hw_device == nil {
		return {}, .Alloc_Failed
	}
	hw_dev := cast(^ffmpeg.AVHWDeviceContext)(hw_device.data)
	d3d11va := cast(^ffmpeg.AVD3D11VADeviceContext)(hw_dev.hwctx)
	d3d11va.device = device
	d3d11va.device_context = imm
	// CopySubresourceRegion targets; avoid VIDEO_ENCODER here (BGRA pool alloc fails on some drivers).
	d3d11va.bind_flags = u32(d3d11.BIND_FLAGS{.SHADER_RESOURCE, .RENDER_TARGET})
	device->AddRef()
	imm->AddRef()
	if ffmpeg.av_hwdevice_ctx_init(hw_device) < 0 {
		ffmpeg.av_buffer_unref(&hw_device)
		return {}, .Open_Failed
	}

	hw_frames := ffmpeg.av_hwframe_ctx_alloc(hw_device)
	if hw_frames == nil {
		ffmpeg.av_buffer_unref(&hw_device)
		return {}, .Alloc_Failed
	}
	frames := cast(^ffmpeg.AVHWFramesContext)(hw_frames.data)
	d3d11_fmt := ffmpeg.pix_fmt_d3d11()
	frames.format = d3d11_fmt
	frames.sw_format = ffmpeg.PIX_FMT_BGRA
	frames.width = w
	frames.height = h
	frames.initial_pool_size = 0
	if ffmpeg.av_hwframe_ctx_init(hw_frames) < 0 {
		ffmpeg.av_buffer_unref(&hw_frames)
		ffmpeg.av_buffer_unref(&hw_device)
		return {}, .Open_Failed
	}

	ctx := ffmpeg.avcodec_alloc_context3(codec)
	if ctx == nil {
		ffmpeg.av_buffer_unref(&hw_frames)
		ffmpeg.av_buffer_unref(&hw_device)
		return {}, .Alloc_Failed
	}

	ctx.width = w
	ctx.height = h
	ctx.pix_fmt = ffmpeg.pix_fmt_d3d11()
	ctx.time_base = ffmpeg.rational(1, fps)
	ctx.framerate = ffmpeg.rational(fps, 1)
	ctx.bit_rate = i64(cfg.bitrate) * 1000
	ctx.flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY
	ctx.sample_aspect_ratio = ffmpeg.rational(1, 1)

	ffmpeg.codec_set_hw_frames_ctx(ctx, hw_frames)
	apply_encoder_options(ctx, name, fps)

	opts: ^ffmpeg.AVDictionary
	if ffmpeg.avcodec_open2(ctx, codec, &opts) < 0 {
		ffmpeg.av_dict_free(&opts)
		ffmpeg.avcodec_free_context(&ctx)
		ffmpeg.av_buffer_unref(&hw_frames)
		ffmpeg.av_buffer_unref(&hw_device)
		return {}, .Open_Failed
	}
	ffmpeg.av_dict_free(&opts)

	headers: []byte
	if ctx.extradata != nil && ctx.extradata_size > 0 {
		headers = param_sets_from_extradata(ctx.extradata[:ctx.extradata_size])
	}

	frame := ffmpeg.av_frame_alloc()
	packet := ffmpeg.av_packet_alloc()
	if frame == nil || packet == nil {
		delete(headers)
		encoder_hw_close(&Encoder_HW{
			base = Encoder{ctx = ctx, frame = frame, packet = packet, headers = headers},
			hw_device = hw_device,
			hw_frames = hw_frames,
		})
		return {}, .Alloc_Failed
	}

	// Prove pool alloc works before the capture loop relies on it.
	d3d11va_lock(hw_device)
	buf_err := ffmpeg.av_hwframe_get_buffer(hw_frames, frame, 0)
	d3d11va_unlock(hw_device)
	if buf_err < 0 {
		utils.log_error(fmt.tprintf("d3d11 encoder: hw frame pool test failed: %s",
			ffmpeg.error_string(buf_err, make([]u8, ffmpeg.AV_ERROR_MAX_STRING_SIZE))))
		delete(headers)
		encoder_hw_close(&Encoder_HW{
			base = Encoder{ctx = ctx, frame = frame, packet = packet, headers = headers},
			hw_device = hw_device,
			hw_frames = hw_frames,
		})
		return {}, .Open_Failed
	}
	ffmpeg.av_frame_unref(frame)

	enc = {
		base = {
			codec            = codec,
			ctx              = ctx,
			frame            = frame,
			packet           = packet,
			width            = w,
			height           = h,
			fps              = fps,
			pix_fmt          = ffmpeg.pix_fmt_d3d11(),
			name             = string(name),
			headers          = headers,
			profile_level_id = h264_profile_level_id(w, h, fps),
		},
		hw_device   = hw_device,
		hw_frames   = hw_frames,
		d3d_device  = device,
		d3d_context = imm,
	}
	fmt.println("NVENC D3D11 zero-copy path enabled")
	return enc, .None
}

encoder_hw_close :: proc(enc: ^Encoder_HW) {
	if enc == nil {
		return
	}
	encoder_close(&enc.base)
	if enc.hw_frames != nil {
		ffmpeg.av_buffer_unref(&enc.hw_frames)
	}
	if enc.hw_device != nil {
		ffmpeg.av_buffer_unref(&enc.hw_device)
	}
	if enc.d3d_device != nil {
		enc.d3d_device->Release()
		enc.d3d_device = nil
	}
	if enc.d3d_context != nil {
		enc.d3d_context->Release()
		enc.d3d_context = nil
	}
}

encoder_hw_request_keyframe :: proc(enc: ^Encoder_HW) {
	encoder_request_keyframe(&enc.base)
}

// Copy `src` into an NVENC pool frame and return encoded access units.
encoder_encode_d3d11 :: proc(enc: ^Encoder_HW, src: ^d3d11.ITexture2D, packets: ^[dynamic]Encoded_AU) -> Encoder_Error {
	if enc == nil {
		utils.log_error("d3d11 encode: nil encoder")
		return .Alloc_Failed
	}
	if enc.base.ctx == nil {
		utils.log_error("d3d11 encode: codec context is nil")
		return .Alloc_Failed
	}
	if enc.base.frame == nil {
		utils.log_error("d3d11 encode: frame is nil")
		return .Alloc_Failed
	}
	if src == nil {
		utils.log_error("d3d11 encode: source texture is nil")
		return .Alloc_Failed
	}
	if enc.hw_frames == nil {
		utils.log_error("d3d11 encode: hw_frames is nil")
		return .Alloc_Failed
	}

	ffmpeg.av_frame_unref(enc.base.frame)

	d3d11va_lock(enc.hw_device)
	defer d3d11va_unlock(enc.hw_device)

	buf_err := ffmpeg.av_hwframe_get_buffer(enc.hw_frames, enc.base.frame, 0)
	if buf_err < 0 {
		utils.log_error(fmt.tprintf("d3d11 encode: av_hwframe_get_buffer: %s",
			ffmpeg.error_string(buf_err, make([]u8, ffmpeg.AV_ERROR_MAX_STRING_SIZE))))
		return .Alloc_Failed
	}

	dst_tex := cast(^d3d11.ITexture2D)(enc.base.frame.data[0])
	dst_idx := int(uintptr(enc.base.frame.data[1]))
	if dst_tex == nil {
		utils.log_error("d3d11 encode: hw frame texture is nil after get_buffer")
		return .Alloc_Failed
	}

	src_desc, dst_desc: d3d11.TEXTURE2D_DESC
	src->GetDesc(&src_desc)
	dst_tex->GetDesc(&dst_desc)
	if src_desc.Width != dst_desc.Width || src_desc.Height != dst_desc.Height {
		utils.log_error(fmt.tprintf("d3d11 encode: texture size mismatch src=%dx%d dst=%dx%d",
			src_desc.Width, src_desc.Height, dst_desc.Width, dst_desc.Height))
		return .Scale_Failed
	}

	enc.d3d_context->CopySubresourceRegion(
		(^d3d11.IResource)(dst_tex),
		u32(dst_idx),
		0, 0, 0,
		(^d3d11.IResource)(src),
		0,
		nil,
	)

	d3d11_fmt := ffmpeg.pix_fmt_d3d11()
	enc.base.frame.format = i32(d3d11_fmt)
	enc.base.frame.width = enc.base.width
	enc.base.frame.height = enc.base.height
	enc.base.frame.pts = enc.base.pts
	enc.base.pts += 1
	if enc.base.force_key {
		enc.base.frame.pict_type = ffmpeg.AV_PICTURE_TYPE_I
	} else {
		enc.base.frame.pict_type = 0
	}

	send := ffmpeg.avcodec_send_frame(enc.base.ctx, enc.base.frame)
	if send < 0 && !ffmpeg.is_again(send) {
		utils.log_error(fmt.tprintf("d3d11 encode: nvenc send_frame: %s",
			ffmpeg.error_string(send, make([]u8, ffmpeg.AV_ERROR_MAX_STRING_SIZE))))
		return .Send_Failed
	}
	if ffmpeg.is_again(send) {
		_ = drain_encoder_packets(&enc.base, packets)
		send = ffmpeg.avcodec_send_frame(enc.base.ctx, enc.base.frame)
		if send < 0 && !ffmpeg.is_again(send) {
			return .Send_Failed
		}
	}

	return drain_encoder_packets(&enc.base, packets)
}
