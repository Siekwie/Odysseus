package core

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

// Screen capture through FFmpeg's grab devices. One code path serves
//   gdigrab       Windows fallback (RDP sessions, rotated monitors, no DXGI)
//   x11grab       Linux X11 / XWayland
//   avfoundation  macOS
// The device hands back one raw image per packet, which is exposed as a Frame
// without copying.

Capture_AV :: struct {
	fmt_ctx: ^ffmpeg.AVFormatContext,
	packet:  ^ffmpeg.AVPacket,
	width:   int,
	height:  int,
	format:  ffmpeg.Pixel_Format,
	bmp:     bool, // gdigrab wraps every frame in a BMP file
}

@(private)
AV_Device :: struct {
	format: cstring, // FFmpeg input format name
	url:    string,
	opts:   ^ffmpeg.AVDictionary,
	bmp:    bool,
}

@(private)
_avdevice_registered: bool

// capture_open_avdevice opens `backend` (GDI, X11 or AVFoundation) on the monitor in opts.
capture_open_avdevice :: proc(backend: Capture_Backend, opts: Capture_Options) -> (cap: Capture, err: Capture_Error) {
	if !_avdevice_registered {
		ffmpeg.avdevice_register_all()
		_avdevice_registered = true
	}

	dev, dev_err := av_device_for(backend, opts)
	if dev_err != .None {
		return {}, dev_err
	}
	defer ffmpeg.av_dict_free(&dev.opts)

	input := ffmpeg.av_find_input_format(dev.format)
	if input == nil {
		utils.log_debug("this FFmpeg build has no %s device", dev.format)
		return {}, .Not_Supported
	}

	url := strings.clone_to_cstring(dev.url, context.temp_allocator)
	fmt_ctx: ^ffmpeg.AVFormatContext
	if rc := ffmpeg.avformat_open_input(&fmt_ctx, url, input, &dev.opts); rc < 0 {
		buf: [ffmpeg.AV_ERROR_MAX_STRING_SIZE]u8
		utils.log_debug("%s open '%s': %s", dev.format, dev.url, ffmpeg.error_string(rc, buf[:]))
		return {}, .Failed
	}
	if fmt_ctx.nb_streams < 1 || fmt_ctx.streams[0] == nil || fmt_ctx.streams[0].codecpar == nil {
		ffmpeg.avformat_close_input(&fmt_ctx)
		return {}, .Failed
	}

	// Read the stream geometry through a scratch codec context: AVOptions are
	// stable across FFmpeg releases, AVCodecParameters' layout is not.
	w, h: i32
	pix := ffmpeg.PIX_FMT_NONE
	scratch := ffmpeg.avcodec_alloc_context3(nil)
	if scratch != nil {
		if ffmpeg.avcodec_parameters_to_context(scratch, fmt_ctx.streams[0].codecpar) >= 0 {
			ffmpeg.av_opt_get_image_size(scratch, "video_size", 0, &w, &h)
			ffmpeg.av_opt_get_pixel_fmt(scratch, "pixel_format", 0, &pix)
		}
		ffmpeg.avcodec_free_context(&scratch)
	}
	packet := ffmpeg.av_packet_alloc()
	if packet == nil {
		ffmpeg.avformat_close_input(&fmt_ctx)
		return {}, .Failed
	}
	if dev.bmp && (w <= 0 || h <= 0) {
		// gdigrab leaves the stream parameters empty; the size is in each frame's BMP header.
		first: Frame
		if ffmpeg.av_read_frame(fmt_ctx, packet) >= 0 && packet.size > 0 && frame_from_bmp(&first, packet.data[:packet.size]) {
			w, h = i32(first.width), i32(first.height)
		}
		ffmpeg.av_packet_unref(packet)
	}
	if w <= 0 || h <= 0 || (!dev.bmp && pix == ffmpeg.PIX_FMT_NONE) {
		utils.log_debug("%s reported no usable video format (%dx%d)", dev.format, w, h)
		ffmpeg.av_packet_free(&packet)
		ffmpeg.avformat_close_input(&fmt_ctx)
		return {}, .Failed
	}

	impl := new(Capture_AV)
	impl.fmt_ctx = fmt_ctx
	impl.packet = packet
	impl.width = int(w)
	impl.height = int(h)
	impl.format = pix
	impl.bmp = dev.bmp

	return Capture{
		width      = int(w),
		height     = int(h),
		self_paced = true,
		impl       = impl,
		frame_proc = capture_frame_avdevice,
		close_proc = capture_close_avdevice,
	}, .None
}

@(private)
av_device_for :: proc(backend: Capture_Backend, opts: Capture_Options) -> (dev: AV_Device, err: Capture_Error) {
	fps := opts.fps if opts.fps > 0 else 30
	fps_s := fmt.tprintf("%d", fps)
	cursor := "1" if opts.cursor else "0"

	#partial switch backend {
	case .GDI, .X11:
		mon, ok := monitor_by_index(opts.monitor)
		if !ok {
			return {}, .No_Output
		}
		ffmpeg.dict_set(&dev.opts, "framerate", fps_s)
		ffmpeg.dict_set(&dev.opts, "draw_mouse", cursor)
		if mon.width > 0 && mon.height > 0 {
			ffmpeg.dict_set(&dev.opts, "video_size", fmt.tprintf("%dx%d", mon.width, mon.height))
		}
		if backend == .GDI {
			dev.format = "gdigrab"
			dev.url = "desktop"
			dev.bmp = true
			ffmpeg.dict_set(&dev.opts, "offset_x", fmt.tprintf("%d", mon.x))
			ffmpeg.dict_set(&dev.opts, "offset_y", fmt.tprintf("%d", mon.y))
		} else {
			dev.format = "x11grab"
			dev.url = fmt.tprintf("%s+%d,%d", x11_display_name(), mon.x, mon.y)
		}
	case .AVFoundation:
		dev.format = "avfoundation"
		dev.url = fmt.tprintf("Capture screen %d:none", opts.monitor)
		ffmpeg.dict_set(&dev.opts, "framerate", fps_s)
		ffmpeg.dict_set(&dev.opts, "capture_cursor", cursor)
		ffmpeg.dict_set(&dev.opts, "pixel_format", "bgr0")
	case:
		return {}, .Not_Supported
	}
	return dev, .None
}

// X display to grab, without a trailing screen offset.
@(private)
x11_display_name :: proc() -> string {
	if name := os.get_env("DISPLAY", context.temp_allocator); name != "" {
		return name
	}
	return ":0"
}

@(private)
capture_close_avdevice :: proc(cap: ^Capture) {
	impl := (^Capture_AV)(cap.impl)
	if impl.packet != nil {
		ffmpeg.av_packet_free(&impl.packet)
	}
	if impl.fmt_ctx != nil {
		ffmpeg.avformat_close_input(&impl.fmt_ctx)
	}
	free(impl)
	cap.impl = nil
}

@(private)
capture_frame_avdevice :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	impl := (^Capture_AV)(cap.impl)

	// The previous frame's pixels live in the packet released here, so there
	// is nothing to repeat when this call does not produce a frame.
	out^ = {}
	pkt := impl.packet
	ffmpeg.av_packet_unref(pkt)
	rc := ffmpeg.av_read_frame(impl.fmt_ctx, pkt)
	if ffmpeg.is_again(rc) {
		// avfoundation is non-blocking: no frame has been delivered yet.
		time.sleep(2 * time.Millisecond)
		return .Timeout
	}
	if rc < 0 {
		return .Device_Lost
	}
	if pkt.size <= 0 || pkt.data == nil {
		return .Timeout
	}

	frame := Frame{
		width        = impl.width,
		height       = impl.height,
		timestamp_ns = now_ns(),
	}
	data := pkt.data[:pkt.size]
	if impl.bmp {
		if !frame_from_bmp(&frame, data) {
				return .Failed
		}
	} else {
		stride := len(data) / impl.height
		if stride <= 0 {
				return .Failed
		}
		frame.format = impl.format
		frame.planes[0] = raw_data(data)
		frame.strides[0] = i32(stride)
	}
	if frame.width != impl.width || frame.height != impl.height {
		// The display mode changed underneath the device.
		return .Device_Lost
	}

	out^ = frame
	return .None
}

// frame_from_bmp points frame at the pixel data of an uncompressed BMP file image.
@(private)
frame_from_bmp :: proc(frame: ^Frame, data: []byte) -> bool {
	le16 :: proc(b: []byte, off: int) -> int { return int(b[off]) | int(b[off + 1]) << 8 }
	le32 :: proc(b: []byte, off: int) -> int { return int(i32(u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24)) }

	if len(data) < 54 || data[0] != 'B' || data[1] != 'M' {
		return false
	}
	pixels := le32(data, 10)
	w := le32(data, 18)
	h := le32(data, 22)
	bpp := le16(data, 28)
	bottom_up := h > 0
	if h < 0 {
		h = -h
	}
	name: cstring
	switch bpp {
	case 32: name = "bgr0"
	case 24: name = "bgr24"
	case 16: name = "rgb555le"
	case:    return false
	}
	stride := ((w * bpp + 31) / 32) * 4
	if w <= 0 || h <= 0 || pixels < 54 || pixels + stride * h > len(data) {
		return false
	}
	frame.width = w
	frame.height = h
	frame.format = ffmpeg.pix_fmt(name)
	if bottom_up {
		frame.planes[0] = raw_data(data[pixels + stride * (h - 1):])
		frame.strides[0] = i32(-stride)
	} else {
		frame.planes[0] = raw_data(data[pixels:])
		frame.strides[0] = i32(stride)
	}
	return frame.format != ffmpeg.PIX_FMT_NONE
}
