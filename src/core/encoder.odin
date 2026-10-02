package core

import "core:strings"
import "core:sync"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

// H.264 encoding through FFmpeg. encoder_open_best walks a per-platform list
// of encoders and keeps the first one that actually opens, so a machine
// without the preferred GPU still streams (down to libx264 on the CPU).
// Access units come back as AVCC, already packed for WebRTC.

KEYFRAME_INTERVAL_SECONDS :: 4

Encoder_Error :: enum {
	None,
	Codec_Not_Found,
	Alloc_Failed,
	Open_Failed,
	Scale_Failed,
	Send_Failed,
	Bad_Frame,
}

Encoder_Options :: struct {
	width:        int,
	height:       int,
	fps:          int,
	bitrate_kbps: int,
}

Encoder :: struct {
	ctx:          ^ffmpeg.AVCodecContext,
	frame:        ^ffmpeg.AVFrame,
	packet:       ^ffmpeg.AVPacket,
	sws:          ^ffmpeg.Sws_Context,
	width:        int,
	height:       int,
	fps:          int,
	input_format: ffmpeg.Pixel_Format, // what the codec is fed (nv12 / yuv420p / d3d11)
	pts:          i64,
	name_buf:     [32]u8,
	name_len:     int,
	force_key:    bool, // atomic; set by encoder_request_keyframe from any thread
	force_tries:  int,
	headers:      []byte, // AVCC SPS/PPS from the first keyframe
	merged:       [dynamic]byte,

	// GPU input path (Windows D3D11), nil for CPU-fed encoders.
	hw:        rawptr,
	hw_encode: proc(enc: ^Encoder, src: ^Frame, out: ^[dynamic]Encoded_AU) -> Encoder_Error,
	hw_close:  proc(enc: ^Encoder),
}

Encoded_AU :: struct {
	data:        []byte, // WebRTC-ready AVCC; free with delete()
	pts:         i64,
	is_keyframe: bool,
}

// Encoders tried for "-encoder:h264", best first.
when ODIN_OS == .Windows {
	AUTO_ENCODERS := [?]string{"h264_nvenc", "h264_amf", "h264_qsv", "libx264", "h264_mf", "libopenh264"}
} else when ODIN_OS == .Darwin {
	AUTO_ENCODERS := [?]string{"h264_videotoolbox", "libx264", "libopenh264"}
} else {
	AUTO_ENCODERS := [?]string{"h264_nvenc", "h264_qsv", "libx264", "libopenh264", "h264_v4l2m2m"}
}

encoder_is_auto :: proc(requested: string) -> bool {
	return requested == "" || requested == "h264" || requested == "auto"
}

encoder_name :: proc(enc: ^Encoder) -> string {
	return string(enc.name_buf[:enc.name_len])
}

@(private)
encoder_set_name :: proc(enc: ^Encoder, name: string) {
	enc.name_len = copy(enc.name_buf[:], name)
}

encoder_exists :: proc(name: string) -> bool {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	return ffmpeg.avcodec_find_encoder_by_name(cname) != nil
}

// encoder_open_best opens the requested encoder, or the first working one of
// AUTO_ENCODERS. Names in `skip` are not tried (encoders that opened earlier
// but then failed to produce frames).
encoder_open_best :: proc(requested: string, opts: Encoder_Options, skip: []string = nil) -> (enc: ^Encoder, err: Encoder_Error) {
	// Probing encoders for absent hardware is expected to fail noisily.
	level := ffmpeg.av_log_get_level()
	if !utils.log_is_verbose() {
		ffmpeg.av_log_set_level(ffmpeg.AV_LOG_FATAL)
	}
	defer ffmpeg.av_log_set_level(level)

	skipped :: proc(name: string, skip: []string) -> bool {
		for s in skip {
			if s == name {
				return true
			}
		}
		return false
	}

	err = .Codec_Not_Found
	if !encoder_is_auto(requested) && !skipped(requested, skip) {
		if enc, err = encoder_open(requested, opts); err == .None {
			return
		}
		utils.log_debug("encoder %s: %v", requested, err)
	}
	for name in AUTO_ENCODERS {
		if name == requested || skipped(name, skip) {
			continue
		}
		e, open_err := encoder_open(name, opts)
		if open_err == .None {
			return e, .None
		}
		utils.log_debug("encoder %s: %v", name, open_err)
		if open_err != .Codec_Not_Found {
			err = open_err
		}
	}
	return nil, err
}

// encoder_exists_working reports whether the named encoder opens when fed CPU frames.
encoder_exists_working :: proc(name: string, opts: Encoder_Options, skip: []string = nil) -> bool {
	for s in skip {
		if s == name {
			return false
		}
	}
	level := ffmpeg.av_log_get_level()
	if !utils.log_is_verbose() {
		ffmpeg.av_log_set_level(ffmpeg.AV_LOG_FATAL)
	}
	defer ffmpeg.av_log_set_level(level)
	enc, err := encoder_open(name, opts)
	if err != .None {
		return false
	}
	encoder_close(enc)
	return true
}

// encoder_open opens one named FFmpeg encoder fed with CPU frames.
encoder_open :: proc(name: string, opts: Encoder_Options) -> (enc: ^Encoder, err: Encoder_Error) {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	codec := ffmpeg.avcodec_find_encoder_by_name(cname)
	if codec == nil {
		return nil, .Codec_Not_Found
	}

	input := encoder_input_format(name)
	if input == ffmpeg.PIX_FMT_NONE {
		return nil, .Open_Failed
	}

	e := new(Encoder)
	defer if err != .None {
		encoder_close(e)
	}
	encoder_set_name(e, name)
	e.width = opts.width
	e.height = opts.height
	e.fps = opts.fps if opts.fps > 0 else 30
	e.input_format = input

	e.ctx = ffmpeg.avcodec_alloc_context3(codec)
	if e.ctx == nil {
		return nil, .Alloc_Failed
	}
	if !encoder_configure(e.ctx, name, e.width, e.height, e.fps, opts.bitrate_kbps, input, true) {
		return nil, .Open_Failed
	}
	if rc := ffmpeg.avcodec_open2(e.ctx, codec, nil); rc < 0 {
		buf: [ffmpeg.AV_ERROR_MAX_STRING_SIZE]u8
		utils.log_debug("%s: avcodec_open2: %s", name, ffmpeg.error_string(rc, buf[:]))
		return nil, .Open_Failed
	}

	e.frame = ffmpeg.av_frame_alloc()
	e.packet = ffmpeg.av_packet_alloc()
	if e.frame == nil || e.packet == nil {
		return nil, .Alloc_Failed
	}
	e.frame.format = i32(input)
	e.frame.width = i32(e.width)
	e.frame.height = i32(e.height)
	if ffmpeg.av_frame_get_buffer(e.frame, 0) < 0 {
		return nil, .Alloc_Failed
	}
	return e, .None
}

encoder_close :: proc(enc: ^Encoder) {
	if enc == nil {
		return
	}
	if enc.sws != nil {
		ffmpeg.sws_freeContext(enc.sws)
	}
	if enc.frame != nil {
		ffmpeg.av_frame_free(&enc.frame)
	}
	if enc.packet != nil {
		ffmpeg.av_packet_free(&enc.packet)
	}
	if enc.ctx != nil {
		ffmpeg.avcodec_free_context(&enc.ctx)
	}
	// After the codec context: it holds references into the hardware frame pool.
	if enc.hw_close != nil {
		enc.hw_close(enc)
	}
	delete(enc.headers)
	delete(enc.merged)
	free(enc)
}

// encoder_request_keyframe makes the next encoded frame an IDR. Safe from any thread.
encoder_request_keyframe :: proc(enc: ^Encoder) {
	sync.atomic_store(&enc.force_key, true)
}

// Software frame layout each encoder is fed with.
@(private)
encoder_input_format :: proc(name: string) -> ffmpeg.Pixel_Format {
	switch name {
	case "libx264", "libopenh264":
		return ffmpeg.pix_fmt("yuv420p")
	}
	return ffmpeg.pix_fmt("nv12")
}

// Applies every setting through AVOptions; AVCodecContext's layout differs
// between FFmpeg releases, the option names do not.
@(private)
encoder_configure :: proc(
	ctx: ^ffmpeg.AVCodecContext,
	name: string,
	w, h, fps, bitrate_kbps: int,
	input: ffmpeg.Pixel_Format,
	yuv_input: bool,
) -> bool {
	child: i32 = ffmpeg.AV_OPT_SEARCH_CHILDREN
	bitrate := i64(bitrate_kbps) * 1000
	gop := i64(fps * KEYFRAME_INTERVAL_SECONDS)
	level := h264_pick_level(w, h, fps)

	if ffmpeg.av_opt_set_image_size(ctx, "video_size", i32(w), i32(h), 0) < 0 ||
	   ffmpeg.av_opt_set_pixel_fmt(ctx, "pixel_format", input, 0) < 0 ||
	   ffmpeg.av_opt_set_q(ctx, "time_base", ffmpeg.rational(1, i32(fps)), 0) < 0 {
		utils.log_error("this FFmpeg build does not expose the codec options Odysseus needs")
		return false
	}
	ffmpeg.av_opt_set_int(ctx, "b", bitrate, 0)
	ffmpeg.av_opt_set_int(ctx, "maxrate", bitrate, 0)
	ffmpeg.av_opt_set_int(ctx, "bufsize", bitrate, 0)
	ffmpeg.av_opt_set_int(ctx, "g", gop, 0)
	ffmpeg.av_opt_set_int(ctx, "bf", 0, 0)
	ffmpeg.av_opt_set(ctx, "flags", "+low_delay", 0)

	// Constrained baseline, the one profile every WebRTC browser decodes.
	ffmpeg.av_opt_set_int(ctx, "profile", 578, 0)
	ffmpeg.av_opt_set(ctx, "profile", "baseline", child)
	ffmpeg.av_opt_set_int(ctx, "level", i64(level.idc), 0)
	ffmpeg.av_opt_set(ctx, "level", level.name, child)
	ffmpeg.av_opt_set(ctx, "aud", "0", child)
	// A requested keyframe must be an IDR with parameter sets, not a plain I-frame,
	// or a viewer that just joined has nothing to start decoding from.
	ffmpeg.av_opt_set(ctx, "forced-idr", "1", child)
	ffmpeg.av_opt_set(ctx, "forced_idr", "1", child)

	if yuv_input {
		// swscale converts desktop RGB to limited-range BT.709; say so in the VUI.
		ffmpeg.av_opt_set(ctx, "colorspace", "bt709", 0)
		ffmpeg.av_opt_set(ctx, "color_primaries", "bt709", 0)
		ffmpeg.av_opt_set(ctx, "color_trc", "bt709", 0)
		ffmpeg.av_opt_set(ctx, "color_range", "tv", 0)
	}

	switch name {
	case "h264_nvenc":
		// NVENC tune is hq/ll/ull/lossless, not x264's zerolatency.
		ffmpeg.av_opt_set(ctx, "preset", "p1", child)
		ffmpeg.av_opt_set(ctx, "tune", "ull", child)
		ffmpeg.av_opt_set(ctx, "rc", "cbr", child)
		ffmpeg.av_opt_set_int(ctx, "delay", 0, child)
		ffmpeg.av_opt_set(ctx, "zerolatency", "1", child)
		ffmpeg.av_opt_set_int(ctx, "rc-lookahead", 0, child)
		ffmpeg.av_opt_set(ctx, "coder", "cavlc", child)
	case "h264_qsv":
		ffmpeg.av_opt_set(ctx, "preset", "veryfast", child)
		ffmpeg.av_opt_set_int(ctx, "look_ahead", 0, child)
		ffmpeg.av_opt_set_int(ctx, "async_depth", 1, child)
	case "h264_amf":
		ffmpeg.av_opt_set(ctx, "usage", "ultralowlatency", child)
		ffmpeg.av_opt_set(ctx, "profile", "constrained_baseline", child)
		ffmpeg.av_opt_set(ctx, "rc", "cbr", child)
		ffmpeg.av_opt_set(ctx, "header_insertion_mode", "idr", child)
	case "h264_videotoolbox":
		ffmpeg.av_opt_set(ctx, "realtime", "1", child)
		ffmpeg.av_opt_set(ctx, "allow_sw", "1", child)
		ffmpeg.av_opt_set(ctx, "prio_speed", "1", child)
	case "h264_mf":
		ffmpeg.av_opt_set(ctx, "rate_control", "cbr", child)
		ffmpeg.av_opt_set(ctx, "scenario", "display_remoting", child)
	case "libx264":
		ffmpeg.av_opt_set(ctx, "preset", "ultrafast", child)
		ffmpeg.av_opt_set(ctx, "tune", "zerolatency", child)
		ffmpeg.av_opt_set(ctx, "coder", "cavlc", child)
	case "libopenh264":
		ffmpeg.av_opt_set(ctx, "profile", "constrained_baseline", child)
		ffmpeg.av_opt_set(ctx, "rc_mode", "bitrate", child)
	}
	return true
}

// encoder_encode converts one captured frame to the codec's input and appends
// the resulting access units to `out` (usually zero or one).
encoder_encode :: proc(enc: ^Encoder, src: ^Frame, out: ^[dynamic]Encoded_AU) -> Encoder_Error {
	if enc.hw_encode != nil {
		return enc.hw_encode(enc, src, out)
	}
	if src.planes[0] == nil || src.width <= 0 || src.height <= 0 {
		return .Bad_Frame
	}

	scaling := src.width != enc.width || src.height != enc.height
	prev := enc.sws
	enc.sws = ffmpeg.sws_getCachedContext(
		enc.sws,
		i32(src.width), i32(src.height), src.format,
		i32(enc.width), i32(enc.height), enc.input_format,
		ffmpeg.SWS_BILINEAR if scaling else ffmpeg.SWS_FAST_BILINEAR,
		nil, nil, nil,
	)
	if enc.sws == nil {
		return .Scale_Failed
	}
	if enc.sws != prev {
		// Full-range RGB in, limited-range BT.709 out (matches the VUI set in encoder_configure).
		bt709 := ffmpeg.sws_getCoefficients(ffmpeg.SWS_CS_ITU709)
		ffmpeg.sws_setColorspaceDetails(enc.sws, bt709, 1, bt709, 0, 0, 1 << 16, 1 << 16)
	}

	// The codec may still hold the buffers of the previous frame.
	if ffmpeg.av_frame_make_writable(enc.frame) < 0 {
		return .Alloc_Failed
	}
	planes := src.planes
	strides := src.strides
	scaled := ffmpeg.sws_scale(
		enc.sws,
		raw_data(planes[:]),
		raw_data(strides[:]),
		0,
		i32(src.height),
		raw_data(enc.frame.data[:]),
		raw_data(enc.frame.linesize[:]),
	)
	if scaled <= 0 {
		return .Scale_Failed
	}
	return encoder_submit(enc, out)
}

// Stamps enc.frame, sends it to the codec and collects the packets.
encoder_submit :: proc(enc: ^Encoder, out: ^[dynamic]Encoded_AU) -> Encoder_Error {
	ffmpeg.frame_set_pts(enc.frame, enc.pts)
	enc.pts += 1

	want_key := sync.atomic_load(&enc.force_key)
	ffmpeg.frame_set_pict_type(enc.frame, ffmpeg.AV_PICTURE_TYPE_I if want_key else ffmpeg.AV_PICTURE_TYPE_NONE)

	send := ffmpeg.avcodec_send_frame(enc.ctx, enc.frame)
	if ffmpeg.is_again(send) {
		// Output queue is full: drain it, then the frame is accepted.
		if err := encoder_drain(enc, out); err != .None {
			return err
		}
		send = ffmpeg.avcodec_send_frame(enc.ctx, enc.frame)
	}
	if send < 0 {
		buf: [ffmpeg.AV_ERROR_MAX_STRING_SIZE]u8
		utils.log_debug("%s: send_frame: %s", encoder_name(enc), ffmpeg.error_string(send, buf[:]))
		return .Send_Failed
	}
	if want_key {
		// Give up after a few frames if this codec cannot be forced, rather than
		// asking for an intra frame forever.
		enc.force_tries += 1
		if enc.force_tries >= 3 {
			enc.force_tries = 0
			sync.atomic_store(&enc.force_key, false)
		}
	}
	return encoder_drain(enc, out)
}

@(private)
encoder_drain :: proc(enc: ^Encoder, out: ^[dynamic]Encoded_AU) -> Encoder_Error {
	clear(&enc.merged)
	pts: i64
	for {
		ffmpeg.av_packet_unref(enc.packet)
		recv := ffmpeg.avcodec_receive_packet(enc.ctx, enc.packet)
		if ffmpeg.is_again(recv) || ffmpeg.is_eof(recv) {
			break
		}
		if recv < 0 {
			return .Send_Failed
		}
		if enc.packet.size <= 0 || enc.packet.data == nil {
			continue
		}
		avcc := h264_to_avcc(enc.packet.data[:enc.packet.size], context.temp_allocator)
		append(&enc.merged, ..avcc)
		pts = enc.packet.pts
	}
	ffmpeg.av_packet_unref(enc.packet)
	if len(enc.merged) == 0 {
		return .None
	}

	if enc.headers == nil {
		enc.headers = h264_extract_param_sets(enc.merged[:])
	}
	data, is_key := h264_prepare_for_webrtc(enc.merged[:], enc.headers)
	if data == nil {
		return .None
	}
	if is_key {
		enc.force_tries = 0
		sync.atomic_store(&enc.force_key, false)
	}
	append(out, Encoded_AU{data = data, pts = pts, is_keyframe = is_key})
	return .None
}

// probe_encoders returns the AUTO_ENCODERS that open on this machine (names are static).
probe_encoders :: proc(allocator := context.allocator) -> [dynamic]string {
	level := ffmpeg.av_log_get_level()
	ffmpeg.av_log_set_level(ffmpeg.AV_LOG_QUIET)
	defer ffmpeg.av_log_set_level(level)

	working := make([dynamic]string, allocator)
	for name in AUTO_ENCODERS {
		enc, err := encoder_open(name, {width = 1280, height = 720, fps = 30, bitrate_kbps = 4000})
		if err == .None {
			append(&working, name)
			encoder_close(enc)
		}
	}
	return working
}
