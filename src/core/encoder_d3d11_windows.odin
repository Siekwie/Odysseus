package core

import "core:strings"
import d3d11 "vendor:directx/d3d11"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

// D3D11 texture -> hardware encoder through FFmpeg hardware frames: the
// captured desktop never leaves the GPU. Works with encoders that accept
// AV_PIX_FMT_D3D11 BGRA input on the capture device (NVENC, AMF).

@(private)
Encoder_D3D11 :: struct {
	hw_device: ^ffmpeg.AVBuffer_Ref,
	hw_frames: ^ffmpeg.AVBuffer_Ref,
	// Borrowed from the capture; FFmpeg's device context owns the references taken in encoder_open_d3d11.
	d3d_context: ^d3d11.IDeviceContext,
}

// The encoder that can take textures of the capture device directly: the
// texture lives on the GPU that drives the monitor, so only that vendor's
// encoder can read it. (Intel: Quick Sync needs its own frame type, not done.)
@(private)
zero_copy_encoder_for :: proc(vendor: u32) -> string {
	switch vendor {
	case GPU_VENDOR_NVIDIA: return "h264_nvenc"
	case GPU_VENDOR_AMD:    return "h264_amf"
	}
	return ""
}

// encoder_open_zero_copy opens a GPU-fed encoder on the capture's D3D11 device.
// The encoder runs at the capture size; scaling needs the CPU path.
encoder_open_zero_copy :: proc(requested: string, cap: ^Capture, opts: Encoder_Options, skip: []string = nil) -> (enc: ^Encoder, err: Encoder_Error) {
	device, imm, ok := capture_d3d11(cap)
	if !ok || opts.width != cap.width || opts.height != cap.height {
		return nil, .Codec_Not_Found
	}
	// hw_frames_ctx has no AVOption; its offset is only known for the vendored FFmpeg.
	if !ffmpeg.codec_hw_frames_supported() {
		return nil, .Codec_Not_Found
	}

	level := ffmpeg.av_log_get_level()
	if !utils.log_is_verbose() {
		ffmpeg.av_log_set_level(ffmpeg.AV_LOG_FATAL)
	}
	defer ffmpeg.av_log_set_level(level)

	name := zero_copy_encoder_for(capture_adapter_vendor(cap))
	if name == "" {
		// E.g. a laptop panel on the integrated GPU: frames go through system
		// memory and can still be encoded by a discrete GPU's encoder.
		utils.log_debug("zero-copy skipped: the monitor is on a GPU (vendor 0x%04x) without a texture-fed encoder", capture_adapter_vendor(cap))
		return nil, .Codec_Not_Found
	}
	if !encoder_is_auto(requested) && requested != name {
		return nil, .Codec_Not_Found
	}
	for s in skip {
		if s == name {
			return nil, .Codec_Not_Found
		}
	}
	enc, err = encoder_open_d3d11(name, opts, device, imm)
	if err != .None {
		utils.log_debug("zero-copy %s: %v", name, err)
	}
	return
}

@(private)
d3d11va_device :: proc(ref: ^ffmpeg.AVBuffer_Ref) -> ^ffmpeg.AVD3D11VADeviceContext {
	if ref == nil || ref.data == nil {
		return nil
	}
	hw_dev := (^ffmpeg.AVHWDeviceContext)(ref.data)
	return (^ffmpeg.AVD3D11VADeviceContext)(hw_dev.hwctx)
}

@(private)
d3d11va_lock :: proc(ref: ^ffmpeg.AVBuffer_Ref) {
	if va := d3d11va_device(ref); va != nil && va.lock != nil {
		va.lock(va.lock_ctx)
	}
}

@(private)
d3d11va_unlock :: proc(ref: ^ffmpeg.AVBuffer_Ref) {
	if va := d3d11va_device(ref); va != nil && va.unlock != nil {
		va.unlock(va.lock_ctx)
	}
}

@(private)
encoder_open_d3d11 :: proc(
	name: string,
	opts: Encoder_Options,
	device: ^d3d11.IDevice,
	imm: ^d3d11.IDeviceContext,
) -> (enc: ^Encoder, err: Encoder_Error) {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	codec := ffmpeg.avcodec_find_encoder_by_name(cname)
	if codec == nil {
		return nil, .Codec_Not_Found
	}
	d3d11_fmt := ffmpeg.pix_fmt("d3d11")
	if d3d11_fmt == ffmpeg.PIX_FMT_NONE {
		return nil, .Codec_Not_Found
	}

	hw := new(Encoder_D3D11)
	e := new(Encoder)
	e.hw = hw
	e.hw_encode = encoder_encode_d3d11
	e.hw_close = encoder_close_d3d11
	defer if err != .None {
		encoder_close(e)
	}
	encoder_set_name(e, name)
	e.width = opts.width
	e.height = opts.height
	e.fps = opts.fps if opts.fps > 0 else 30
	e.input_format = d3d11_fmt

	hw.hw_device = ffmpeg.av_hwdevice_ctx_alloc(.D3d11va)
	if hw.hw_device == nil {
		return nil, .Alloc_Failed
	}
	va := d3d11va_device(hw.hw_device)
	va.device = device
	va.device_context = imm
	// Pool textures are CopySubresourceRegion targets; VIDEO_ENCODER binding makes BGRA pool allocation fail on some drivers.
	va.bind_flags = u32(d3d11.BIND_FLAGS{.SHADER_RESOURCE, .RENDER_TARGET})
	// FFmpeg releases both when the device context is freed.
	device->AddRef()
	imm->AddRef()
	hw.d3d_context = imm
	if ffmpeg.av_hwdevice_ctx_init(hw.hw_device) < 0 {
		return nil, .Open_Failed
	}

	hw.hw_frames = ffmpeg.av_hwframe_ctx_alloc(hw.hw_device)
	if hw.hw_frames == nil {
		return nil, .Alloc_Failed
	}
	frames := (^ffmpeg.AVHWFramesContext)(hw.hw_frames.data)
	frames.format = d3d11_fmt
	frames.sw_format = ffmpeg.pix_fmt("bgra")
	frames.width = i32(e.width)
	frames.height = i32(e.height)
	frames.initial_pool_size = 0
	if ffmpeg.av_hwframe_ctx_init(hw.hw_frames) < 0 {
		return nil, .Open_Failed
	}

	e.ctx = ffmpeg.avcodec_alloc_context3(codec)
	if e.ctx == nil {
		return nil, .Alloc_Failed
	}
	if !encoder_configure(e.ctx, name, e.width, e.height, e.fps, opts.bitrate_kbps, d3d11_fmt, false) ||
	   !ffmpeg.codec_set_hw_frames_ctx(e.ctx, hw.hw_frames) {
		return nil, .Open_Failed
	}
	if rc := ffmpeg.avcodec_open2(e.ctx, codec, nil); rc < 0 {
		buf: [ffmpeg.AV_ERROR_MAX_STRING_SIZE]u8
		utils.log_debug("%s (d3d11): avcodec_open2: %s", name, ffmpeg.error_string(rc, buf[:]))
		return nil, .Open_Failed
	}

	e.frame = ffmpeg.av_frame_alloc()
	e.packet = ffmpeg.av_packet_alloc()
	if e.frame == nil || e.packet == nil {
		return nil, .Alloc_Failed
	}

	// Prove pool allocation works before the capture loop relies on it.
	d3d11va_lock(hw.hw_device)
	rc := ffmpeg.av_hwframe_get_buffer(hw.hw_frames, e.frame, 0)
	d3d11va_unlock(hw.hw_device)
	if rc < 0 {
		buf: [ffmpeg.AV_ERROR_MAX_STRING_SIZE]u8
		utils.log_debug("%s (d3d11): frame pool: %s", name, ffmpeg.error_string(rc, buf[:]))
		return nil, .Open_Failed
	}
	ffmpeg.av_frame_unref(e.frame)
	return e, .None
}

@(private)
encoder_close_d3d11 :: proc(enc: ^Encoder) {
	hw := (^Encoder_D3D11)(enc.hw)
	if hw == nil {
		return
	}
	if hw.hw_frames != nil {
		ffmpeg.av_buffer_unref(&hw.hw_frames)
	}
	if hw.hw_device != nil {
		// Drops FFmpeg's references to the capture's device and context.
		ffmpeg.av_buffer_unref(&hw.hw_device)
	}
	free(hw)
	enc.hw = nil
}

// Copies the captured texture into a pool frame and encodes it.
@(private)
encoder_encode_d3d11 :: proc(enc: ^Encoder, src: ^Frame, out: ^[dynamic]Encoded_AU) -> Encoder_Error {
	hw := (^Encoder_D3D11)(enc.hw)
	tex := (^d3d11.ITexture2D)(src.texture)
	if tex == nil {
		return .Bad_Frame
	}

	ffmpeg.av_frame_unref(enc.frame)

	{
		d3d11va_lock(hw.hw_device)
		defer d3d11va_unlock(hw.hw_device)

		if rc := ffmpeg.av_hwframe_get_buffer(hw.hw_frames, enc.frame, 0); rc < 0 {
			buf: [ffmpeg.AV_ERROR_MAX_STRING_SIZE]u8
			utils.log_debug("d3d11 encode: av_hwframe_get_buffer: %s", ffmpeg.error_string(rc, buf[:]))
			return .Alloc_Failed
		}

		// AV_PIX_FMT_D3D11: data[0] is the texture, data[1] the array slice index.
		dst_tex := (^d3d11.ITexture2D)(rawptr(enc.frame.data[0]))
		dst_idx := u32(uintptr(enc.frame.data[1]))
		if dst_tex == nil {
			return .Alloc_Failed
		}

		src_desc, dst_desc: d3d11.TEXTURE2D_DESC
		tex->GetDesc(&src_desc)
		dst_tex->GetDesc(&dst_desc)
		if src_desc.Width != dst_desc.Width || src_desc.Height != dst_desc.Height {
			return .Bad_Frame
		}

		hw.d3d_context->CopySubresourceRegion(
			(^d3d11.IResource)(dst_tex),
			dst_idx,
			0, 0, 0,
			(^d3d11.IResource)(tex),
			0,
			nil,
		)
	}

	return encoder_submit(enc, enc.frame, out)
}
