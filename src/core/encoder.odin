package core

import ffmpeg "../../vendor/ffmpeg"
import "../utils"
import "core:encoding/base64"
import "core:fmt"

// H.264 encoder wrapping FFmpeg. You still own the capture -> encode -> WebRTC loop;
// this package opens the codec, converts BGRA, and returns length-prefixed (AVCC) access units.

Encoder :: struct {
	codec:     ^ffmpeg.AVCodec,
	ctx:       ^ffmpeg.AVCodecContext,
	frame:     ^ffmpeg.AVFrame,
	packet:    ^ffmpeg.AVPacket,
	sws:       ^ffmpeg.Sws_Context,
	width:     i32,
	height:    i32,
	fps:       i32,
	src_w:     i32,
	src_h:     i32,
	pix_fmt:   ffmpeg.Pixel_Format,
	pts:       i64,
	name:      string,
	force_key:  bool,
	headers:    []byte, // AVCC SPS/PPS copied from extradata or the first IDR
}

Encoded_AU :: struct {
	data:        []byte, // copy of the FFmpeg packet; free with delete()
	pts:         i64,
	is_keyframe: bool,
}

Encoder_Error :: enum {
	None,
	Codec_Not_Found,
	Alloc_Failed,
	Open_Failed,
	Scale_Failed,
	Send_Failed,
	Stub_Libs,
}

PREFERRED_ENCODERS := [?]cstring{
	"h264_nvenc",
	"h264_qsv",
	"h264_amf",
	"h264_videotoolbox",
	"h264_vaapi",
	"libx264",
}

detect_encoders :: proc() -> (found: [dynamic]string) {
	found = make([dynamic]string)
	for name in PREFERRED_ENCODERS {
		if ffmpeg.avcodec_find_encoder_by_name(name) != nil {
			append(&found, string(name))
		}
	}
	return
}

resolve_encoder_name :: proc(requested: string) -> cstring {
	if requested == "" || requested == "h264" {
		for name in PREFERRED_ENCODERS {
			if ffmpeg.avcodec_find_encoder_by_name(name) != nil {
				return name
			}
		}
		return "libx264"
	}
	return strings_to_cstring(requested)
}

@(private)
_encoder_name_buf: [64]u8

strings_to_cstring :: proc(s: string) -> cstring {
	n := min(len(s), len(_encoder_name_buf) - 1)
	copy(_encoder_name_buf[:n], s)
	_encoder_name_buf[n] = 0
	return cstring(&_encoder_name_buf[0])
}

encoder_open :: proc(cfg: utils.Config) -> (enc: Encoder, err: Encoder_Error) {
	when ffmpeg.STUB_LIBS {
		return {}, .Stub_Libs
	}

	name := resolve_encoder_name(cfg.encoder)
	codec := ffmpeg.avcodec_find_encoder_by_name(name)
	if codec == nil {
		return {}, .Codec_Not_Found
	}

	ctx := ffmpeg.avcodec_alloc_context3(codec)
	if ctx == nil {
		return {}, .Alloc_Failed
	}

	w := i32(cfg.width)
	h := i32(cfg.height)
	fps := i32(cfg.fps)
	if w <= 0 { w = 1920 }
	if h <= 0 { h = 1080 }
	if fps <= 0 { fps = 30 }

	ctx.width = w
	ctx.height = h
	ctx.pix_fmt = ffmpeg.PIX_FMT_YUV420P
	ctx.time_base = ffmpeg.rational(1, fps)
	ctx.framerate = ffmpeg.rational(fps, 1)
	ctx.bit_rate = i64(cfg.bitrate) * 1000
	ctx.flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY
	ctx.sample_aspect_ratio = ffmpeg.rational(1, 1)

	apply_encoder_options(ctx, name, fps)

	opts: ^ffmpeg.AVDictionary
	if ffmpeg.avcodec_open2(ctx, codec, &opts) < 0 {
		ffmpeg.av_dict_free(&opts)
		ffmpeg.avcodec_free_context(&ctx)
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
		encoder_close(&Encoder{ctx = ctx, frame = frame, packet = packet})
		return {}, .Alloc_Failed
	}
	frame.format = i32(ffmpeg.PIX_FMT_YUV420P)
	frame.width = w
	frame.height = h
	if ffmpeg.av_frame_get_buffer(frame, 32) < 0 {
		encoder_close(&Encoder{ctx = ctx, frame = frame, packet = packet, headers = headers})
		return {}, .Alloc_Failed
	}

	enc = {
		codec   = codec,
		ctx     = ctx,
		frame   = frame,
		packet  = packet,
		width   = w,
		height  = h,
		fps     = fps,
		pix_fmt  = ffmpeg.PIX_FMT_YUV420P,
		name     = string(name),
		headers  = headers,
	}
	return enc, .None
}

@(private)
apply_encoder_options :: proc(ctx: ^ffmpeg.AVCodecContext, name: cstring, fps: i32) {
	child: i32 = ffmpeg.AV_OPT_SEARCH_CHILDREN
	gop := i64(fps)
	if gop <= 0 {
		gop = 30
	}
	// GOP on the codec context (not only private encoder options).
	ffmpeg.av_opt_set_int(ctx, "g", gop, 0)
	ffmpeg.av_opt_set_int(ctx, "g", gop, child)
	ffmpeg.av_opt_set_int(ctx, "bf", 0, 0)
	ffmpeg.av_opt_set_int(ctx, "bf", 0, child)
	ffmpeg.av_opt_set_int(ctx, "profile", 578, 0) // constrained baseline
	ffmpeg.av_opt_set(ctx, "profile", "baseline", child)
	ffmpeg.av_opt_set(ctx, "level", "4.1", child)
	// Length-prefixed NALs so RTP packetization does not scan 00 00 01 inside slices.
	ffmpeg.av_opt_set(ctx, "annexb", "0", child)
	ffmpeg.av_opt_set(ctx, "aud", "0", child)
	ffmpeg.av_opt_set(ctx, "coder", "cavlc", child)
	br := ctx.bit_rate
	if br > 0 {
		ffmpeg.av_opt_set_int(ctx, "maxrate", br, child)
		ffmpeg.av_opt_set_int(ctx, "bufsize", br, child)
	}

	switch name {
	case "h264_nvenc":
		// NVENC tune is hq/ll/ull/lossless — not x264's zerolatency.
		ffmpeg.av_opt_set(ctx, "preset", "p1", child)
		ffmpeg.av_opt_set(ctx, "tune", "ull", child)
		ffmpeg.av_opt_set(ctx, "rc", "cbr", child)
		ffmpeg.av_opt_set_int(ctx, "delay", 0, child)
		ffmpeg.av_opt_set(ctx, "zerolatency", "1", child)
		ffmpeg.av_opt_set(ctx, "repeat-headers", "1", child)
		ffmpeg.av_opt_set_int(ctx, "gop", gop, child)
		ffmpeg.av_opt_set_int(ctx, "b_adapt", 0, child)
		ffmpeg.av_opt_set_int(ctx, "rc-lookahead", 0, child)
	case "h264_qsv":
		ffmpeg.av_opt_set(ctx, "preset", "veryfast", child)
		ffmpeg.av_opt_set_int(ctx, "look_ahead", 0, child)
		ffmpeg.av_opt_set(ctx, "repeat_headers", "1", child)
	case "h264_amf":
		ffmpeg.av_opt_set(ctx, "usage", "ultralowlatency", child)
		ffmpeg.av_opt_set(ctx, "profile", "constrained_baseline", child)
		ffmpeg.av_opt_set(ctx, "header_insertion_mode", "gop", child)
	case "libx264":
		ffmpeg.av_opt_set(ctx, "preset", "ultrafast", child)
		ffmpeg.av_opt_set(ctx, "tune", "zerolatency", child)
		ffmpeg.av_opt_set(ctx, "repeat_headers", "1", child)
	}
}

encoder_close :: proc(enc: ^Encoder) {
	if enc.headers != nil {
		delete(enc.headers)
		enc.headers = nil
	}
	if enc.sws != nil {
		ffmpeg.sws_freeContext(enc.sws)
		enc.sws = nil
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
}

encoder_request_keyframe :: proc(enc: ^Encoder) {
	enc.force_key = true
}

// Convert a BGRA desktop frame to the encoder size/format and produce H.264 access units.
encoder_encode_bgra :: proc(enc: ^Encoder, bgra: []byte, src_w, src_h, stride: int, packets: ^[dynamic]Encoded_AU) -> Encoder_Error {
	if enc.ctx == nil || enc.frame == nil {
		return .Alloc_Failed
	}

	src_w_i := i32(src_w if src_w > 0 else int(enc.width))
	src_h_i := i32(src_h if src_h > 0 else int(enc.height))
	src_stride := i32(stride)

	enc.sws = ffmpeg.sws_getCachedContext(
		enc.sws,
		src_w_i, src_h_i, ffmpeg.PIX_FMT_BGRA,
		enc.width, enc.height, enc.pix_fmt,
		ffmpeg.SWS_FAST_BILINEAR,
		nil, nil, nil,
	)
	if enc.sws == nil {
		return .Scale_Failed
	}

	src_planes: [1]^u8 = { raw_data(bgra) }
	src_strides: [1]i32 = { src_stride }
	dst_planes := ([^]^u8)(&enc.frame.data[0])
	dst_strides := ([^]i32)(&enc.frame.linesize[0])
	scaled := ffmpeg.sws_scale(
		enc.sws,
		raw_data(src_planes[:]),
		raw_data(src_strides[:]),
		0,
		src_h_i,
		dst_planes,
		dst_strides,
	)
	if scaled <= 0 {
		return .Scale_Failed
	}

	enc.frame.pts = enc.pts
	enc.pts += 1
	if enc.force_key {
		enc.frame.pict_type = ffmpeg.AV_PICTURE_TYPE_I
	} else {
		enc.frame.pict_type = 0
	}

	send := ffmpeg.avcodec_send_frame(enc.ctx, enc.frame)
	if send < 0 && !ffmpeg.is_again(send) {
		return .Send_Failed
	}

	merged: [dynamic]byte
	defer delete(merged)
	is_key := false
	pts: i64
	got := false
	for {
		ffmpeg.av_packet_unref(enc.packet)
		recv := ffmpeg.avcodec_receive_packet(enc.ctx, enc.packet)
		if ffmpeg.is_again(recv) || ffmpeg.is_eof(recv) {
			break
		}
		if recv < 0 {
			return .Send_Failed
		}
		n := int(enc.packet.size)
		raw := enc.packet.data[:n]
		data := h264_to_avcc(raw)
		append(&merged, ..data)
		delete(data)
		if (enc.packet.flags & ffmpeg.AV_PKT_FLAG_KEY) != 0 {
			is_key = true
		}
		pts = enc.packet.pts
		got = true
	}
	if !got || len(merged) == 0 {
		return .None
	}

	out := make([]byte, len(merged))
	copy(out, merged[:])
	if is_key {
		out = ensure_param_sets(enc, out)
		enc.force_key = false
	}
	is_key = avcc_has_nal(out, 5)

	append(packets, Encoded_AU{
		data        = out,
		pts         = pts,
		is_keyframe = is_key,
	})
	return .None
}

@(private)
avcc_append_length_nal :: proc(out: ^[dynamic]byte, nal: []byte) {
	n := len(nal)
	if n <= 0 {
		return
	}
	append(out, u8((n >> 24) & 0xFF), u8((n >> 16) & 0xFF), u8((n >> 8) & 0xFF), u8(n & 0xFF))
	append(out, ..nal)
}

// Build an RFC 6184 STAP-A NAL (type 24) containing SPS + PPS. Chrome drops isolated
// SPS/PPS RTP packets, so they must share one RTP packet before the IDR.
@(private)
h264_build_stap_a :: proc(sps, pps: []byte) -> []byte {
	if len(sps) == 0 || len(pps) == 0 {
		return nil
	}
	out := make([]byte, 1 + 2 + len(sps) + 2 + len(pps))
	out[0] = 0x78 // F=0, NRI=3, type=24 (STAP-A)
	i := 1
	out[i] = u8((len(sps) >> 8) & 0xFF)
	out[i + 1] = u8(len(sps) & 0xFF)
	i += 2
	copy(out[i:], sps)
	i += len(sps)
	out[i] = u8((len(pps) >> 8) & 0xFF)
	out[i + 1] = u8(len(pps) & 0xFF)
	i += 2
	copy(out[i:], pps)
	return out
}

// Repack AVCC access units for WebRTC: STAP-A (SPS+PPS) before IDR on keyframes,
// strip SEI/AUD/filler, keep slice NALs only.
h264_avcc_prepare_for_webrtc :: proc(src: []byte, is_keyframe: bool) -> []byte {
	if len(src) == 0 {
		return nil
	}

	sps: []byte
	pps: []byte
	slices: [dynamic][]byte
	defer delete(slices)

	i := 0
	for i + 4 <= len(src) {
		n := int(src[i]) << 24 | int(src[i + 1]) << 16 | int(src[i + 2]) << 8 | int(src[i + 3])
		i += 4
		if n <= 0 || i + n > len(src) {
			break
		}
		nal := src[i:i + n]
		t := nal[0] & 0x1F
		switch t {
		case 7:
			if sps == nil {
				sps = make([]byte, n)
				copy(sps, nal)
			}
		case 8:
			if pps == nil {
				pps = make([]byte, n)
				copy(pps, nal)
			}
		case 6, 9, 12, 0:
			// drop SEI, AUD, filler, reserved
		case:
			s := make([]byte, n)
			copy(s, nal)
			append(&slices, s)
		}
		i += n
	}

	out: [dynamic]byte
	if is_keyframe {
		if stap := h264_build_stap_a(sps, pps); stap != nil {
			avcc_append_length_nal(&out, stap)
			delete(stap)
		}
	}
	delete(sps)
	delete(pps)

	for s in slices {
		avcc_append_length_nal(&out, s)
		delete(s)
	}

	if len(out) == 0 {
		if h264_valid_length_prefixed_avcc(src) {
			return avcc_copy_filtered(src)
		}
		if h264_is_single_nal(src) {
			return avcc_wrap_single_nal(src)
		}
		return nil
	}
	return out[:]
}

// WebRTC fmtp line including optional sprop-parameter-sets from cached SPS/PPS.
h264_webrtc_profile :: proc(headers: []byte) -> string {
	base := "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
	if sprop := h264_sprop_parameter_sets(headers); sprop != "" {
		return fmt.tprintf("%s;sprop-parameter-sets=%s", base, sprop)
	}
	return base
}

h264_sprop_parameter_sets :: proc(avcc: []byte) -> string {
	sps, pps := h264_avcc_param_sets(avcc)
	if len(sps) == 0 || len(pps) == 0 {
		return ""
	}
	defer delete(sps)
	defer delete(pps)
	sps_b64, _ := base64.encode(sps)
	pps_b64, _ := base64.encode(pps)
	defer delete(sps_b64)
	defer delete(pps_b64)
	return fmt.tprintf("%s,%s", sps_b64, pps_b64)
}

h264_avcc_param_sets :: proc(src: []byte) -> (sps, pps: []byte) {
	i := 0
	for i + 4 <= len(src) {
		n := int(src[i]) << 24 | int(src[i + 1]) << 16 | int(src[i + 2]) << 8 | int(src[i + 3])
		i += 4
		if n <= 0 || i + n > len(src) {
			break
		}
		nal := src[i:i + n]
		t := nal[0] & 0x1F
		if t == 7 && sps == nil {
			sps = make([]byte, n)
			copy(sps, nal)
		} else if t == 8 && pps == nil {
			pps = make([]byte, n)
			copy(pps, nal)
		}
		i += n
	}
	return
}

@(private)
h264_is_single_nal :: proc(src: []byte) -> bool {
	if len(src) < 1 {
		return false
	}
	nal_type := src[0] & 0x1F
	return nal_type > 0 && nal_type < 24
}

@(private)
h264_valid_length_prefixed_avcc :: proc(src: []byte) -> bool {
	i := 0
	for i + 4 <= len(src) {
		n := int(src[i]) << 24 | int(src[i + 1]) << 16 | int(src[i + 2]) << 8 | int(src[i + 3])
		i += 4
		if n <= 0 || i + n > len(src) {
			return false
		}
		i += n
	}
	return i == len(src) && len(src) >= 5
}

@(private)
avcc_wrap_single_nal :: proc(nal: []byte) -> []byte {
	n := len(nal)
	out := make([]byte, 4 + n)
	out[0] = u8((n >> 24) & 0xFF)
	out[1] = u8((n >> 16) & 0xFF)
	out[2] = u8((n >> 8) & 0xFF)
	out[3] = u8(n & 0xFF)
	copy(out[4:], nal)
	return out
}

@(private)
avcc_append_nal :: proc(out: ^[dynamic]byte, nal: []byte) {
	n := len(nal)
	if n <= 0 {
		return
	}
	t := nal[0] & 0x1F
	if t == 0 || t == 6 || t == 9 || t == 12 {
		return
	}
	append(out, u8((n >> 24) & 0xFF), u8((n >> 16) & 0xFF), u8((n >> 8) & 0xFF), u8(n & 0xFF))
	append(out, ..nal)
}

@(private)
param_sets_from_extradata :: proc(src: []byte) -> []byte {
	if len(src) == 0 {
		return nil
	}
	if start_code_len(src, 0) > 0 {
		avcc := h264_to_avcc(src)
		sets := extract_param_sets(avcc)
		delete(avcc)
		return sets
	}
	if src[0] != 1 || len(src) < 7 {
		return h264_to_avcc(src)
	}

	out: [dynamic]byte
	i := 6
	nsps := int(src[5] & 0x1F)
	for _ in 0 ..< nsps {
		if i + 2 > len(src) {
			break
		}
		n := int(src[i]) << 8 | int(src[i + 1])
		i += 2
		if n < 0 || i + n > len(src) {
			break
		}
		avcc_append_nal(&out, src[i:i + n])
		i += n
	}
	if i >= len(src) {
		return out[:]
	}
	npps := int(src[i])
	i += 1
	for _ in 0 ..< npps {
		if i + 2 > len(src) {
			break
		}
		n := int(src[i]) << 8 | int(src[i + 1])
		i += 2
		if n < 0 || i + n > len(src) {
			break
		}
		avcc_append_nal(&out, src[i:i + n])
		i += n
	}
	if len(out) == 0 {
		return nil
	}
	return out[:]
}

@(private)
ensure_param_sets :: proc(enc: ^Encoder, data: []byte) -> []byte {
	has_sps := avcc_has_nal(data, 7)
	has_pps := avcc_has_nal(data, 8)
	if has_sps && has_pps {
		if len(enc.headers) == 0 {
			enc.headers = extract_param_sets(data)
		}
		return data
	}
	if len(enc.headers) == 0 {
		return data
	}
	out := make([]byte, len(enc.headers) + len(data))
	copy(out, enc.headers)
	copy(out[len(enc.headers):], data)
	delete(data)
	return out
}

@(private)
extract_param_sets :: proc(data: []byte) -> []byte {
	out: [dynamic]byte
	i := 0
	for i + 4 <= len(data) {
		n := int(data[i]) << 24 | int(data[i + 1]) << 16 | int(data[i + 2]) << 8 | int(data[i + 3])
		i += 4
		if n <= 0 || i + n > len(data) {
			break
		}
		t := data[i] & 0x1F
		if t == 7 || t == 8 {
			avcc_append_nal(&out, data[i:i + n])
		}
		i += n
	}
	if len(out) == 0 {
		return nil
	}
	return out[:]
}

@(private)
avcc_has_nal :: proc(data: []byte, nal_type: u8) -> bool {
	i := 0
	for i + 4 <= len(data) {
		n := int(data[i]) << 24 | int(data[i + 1]) << 16 | int(data[i + 2]) << 8 | int(data[i + 3])
		i += 4
		if n <= 0 || i + n > len(data) {
			return false
		}
		if (data[i] & 0x1F) == nal_type {
			return true
		}
		i += n
	}
	return false
}

@(private)
start_code_len :: proc(data: []byte, i: int) -> int {
	if i + 4 <= len(data) && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
		return 4
	}
	if i + 3 <= len(data) && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
		return 3
	}
	return 0
}

// Length-prefixed NALs for libdatachannel's Length separator.
// Valid AVCC is classified first: a 256..65535-byte length prefix is 00 00 01 xx
// and would otherwise be mistaken for a 3-byte Annex-B start code.
h264_to_avcc :: proc(src: []byte) -> []byte {
	if len(src) == 0 {
		return nil
	}
	if h264_valid_length_prefixed_avcc(src) {
		return avcc_copy_filtered(src)
	}
	if start_code_len(src, 0) > 0 {
		return h264_annexb_to_avcc(src)
	}
	if h264_is_single_nal(src) {
		return avcc_wrap_single_nal(src)
	}
	return nil
}

@(private)
avcc_copy_filtered :: proc(src: []byte) -> []byte {
	out: [dynamic]byte
	i := 0
	ok := false
	for i + 4 <= len(src) {
		n := int(src[i]) << 24 | int(src[i + 1]) << 16 | int(src[i + 2]) << 8 | int(src[i + 3])
		i += 4
		if n <= 0 || i + n > len(src) {
			ok = false
			break
		}
		avcc_append_nal(&out, src[i:i + n])
		i += n
		ok = true
	}
	if !ok || len(out) == 0 {
		delete(out)
		if h264_is_single_nal(src) {
			return avcc_wrap_single_nal(src)
		}
		return nil
	}
	return out[:]
}

h264_annexb_to_avcc :: proc(src: []byte) -> []byte {
	if len(src) == 0 {
		return nil
	}
	out: [dynamic]byte
	i := 0
	for i < len(src) {
		sc := start_code_len(src, i)
		if sc == 0 {
			i += 1
			continue
		}
		nal := i + sc
		next := len(src)
		j := nal
		for j < len(src) {
			if start_code_len(src, j) > 0 {
				next = j
				break
			}
			j += 1
		}
		if nal < next {
			avcc_append_nal(&out, src[nal:next])
		}
		i = next
	}
	if len(out) == 0 {
		return nil
	}
	return out[:]
}
