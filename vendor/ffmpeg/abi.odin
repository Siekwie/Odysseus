package ffmpeg

// Version-dependent pieces of the FFmpeg ABI.
//
// AVFrame lost its deprecated `key_frame`, `interlaced_frame`, ... fields in
// libavutil 60 (FFmpeg 8), which moved `pict_type` and `buf`:
//
//   libavutil   FFmpeg   pict_type   pts   buf
//   58          6.x      124         136   224
//   59          7.x      124         136   200
//   60          8.x      120         136   184
//   61          9.x      120         136   184
//
// The 60 and 61 rows are measured against the n8.1 and n9.0 headers;
// `frame_buf_slot` re-checks the buf offset at runtime before anything relies on it.

Versions :: struct {
	avutil:   u32,
	avcodec:  u32,
	avformat: u32,
}

versions :: proc() -> Versions {
	return {
		avutil   = avutil_version() >> 16,
		avcodec  = avcodec_version() >> 16,
		avformat = avformat_version() >> 16,
	}
}

AVUTIL_MAJOR_MIN   :: 58
AVUTIL_MAJOR_MAX   :: 61
AVFORMAT_MAJOR_MIN :: 60

// supported reports whether the loaded FFmpeg libraries are a release these bindings understand.
supported :: proc() -> bool {
	v := versions()
	return v.avutil >= AVUTIL_MAJOR_MIN && v.avutil <= AVUTIL_MAJOR_MAX && v.avformat >= AVFORMAT_MAJOR_MIN
}

@(private)
FRAME_PTS_OFFSET :: 136

@(private)
frame_pict_type_offset :: proc() -> uintptr {
	return 120 if avutil_version() >> 16 >= 60 else 124
}

@(private)
frame_buf_offset :: proc() -> uintptr {
	switch avutil_version() >> 16 {
	case 58: return 224
	case 59: return 200
	case:    return 184
	}
}

frame_set_pict_type :: proc(frame: ^AVFrame, pict_type: i32) {
	(^i32)(uintptr(frame) + frame_pict_type_offset())^ = pict_type
}

frame_set_pts :: proc(frame: ^AVFrame, pts: i64) {
	(^i64)(uintptr(frame) + FRAME_PTS_OFFSET)^ = pts
}

@(private)
_frame_buf_checked: bool
@(private)
_frame_buf_ok: bool

// frame_buf_slot returns the address of AVFrame.buf[0], or nil when the
// expected offset does not hold for the loaded libavutil. The check allocates
// a small video frame once and confirms the slot holds the buffer that backs
// data[0].
frame_buf_slot :: proc(frame: ^AVFrame) -> ^^AVBuffer_Ref {
	off := frame_buf_offset()
	if !_frame_buf_checked {
		_frame_buf_ok = frame_buf_probe(off)
		_frame_buf_checked = true
	}
	if !_frame_buf_ok {
		return nil
	}
	return (^^AVBuffer_Ref)(uintptr(frame) + off)
}

@(private)
frame_buf_probe :: proc(off: uintptr) -> bool {
	gray := av_get_pix_fmt("gray")
	if gray == PIX_FMT_NONE {
		return false
	}
	probe := av_frame_alloc()
	if probe == nil {
		return false
	}
	defer av_frame_free(&probe)
	probe.width = 16
	probe.height = 16
	probe.format = i32(gray)
	if av_frame_get_buffer(probe, 0) < 0 {
		return false
	}
	// The slot before buf[0] holds small integers (repeat_pict/sample_rate),
	// never a pointer; a wrong offset shows up as a nil or implausible value here.
	slot := (^uintptr)(uintptr(probe) + off)^
	data0 := uintptr(probe.data[0])
	if slot == 0 || slot & 7 != 0 || data0 == 0 {
		return false
	}
	// Heap pointers from the same allocator share their upper bits.
	if slot >> 40 != data0 >> 40 {
		return false
	}
	ref := (^AVBuffer_Ref)(slot)
	start := uintptr(ref.data)
	return data0 >= start && data0 < start + uintptr(ref.size)
}

// AVCodecContext.hw_frames_ctx has no AVOption. Its offset is measured for
// libavcodec 62 (FFmpeg 8, Windows x86-64) and 63 (FFmpeg 9, Linux x86-64);
// the struct has no long/size_t members before it, so the two ABIs agree.
@(private)
HW_FRAMES_CTX_OFFSET :: 552

@(private)
hw_frames_offset_known :: proc() -> bool {
	when ODIN_ARCH == .amd64 {
		major := avcodec_version() >> 16
		return major == 62 || major == 63
	} else {
		return false
	}
}

codec_hw_frames_slot :: proc(ctx: ^AVCodecContext) -> ^^AVBuffer_Ref {
	if !hw_frames_offset_known() {
		return nil
	}
	return (^^AVBuffer_Ref)(uintptr(ctx) + HW_FRAMES_CTX_OFFSET)
}

// codec_hw_frames_supported reports whether hw_frames_ctx can be set on this FFmpeg.
codec_hw_frames_supported :: proc() -> bool {
	return hw_frames_offset_known()
}

// codec_set_hw_frames_ctx stores a new reference to frames in the codec context.
codec_set_hw_frames_ctx :: proc(ctx: ^AVCodecContext, frames: ^AVBuffer_Ref) -> bool {
	dst := codec_hw_frames_slot(ctx)
	if dst == nil {
		return false
	}
	if dst^ != nil {
		av_buffer_unref(dst)
	}
	dst^ = av_buffer_ref(frames)
	return dst^ != nil
}

// AVCodecContext.sample_fmt has no AVOption either, and its offset differs per
// release. It directly follows sample_rate (after the deprecated `channels`
// int in libavcodec 60), and sample_rate *is* an option ("ar"): write a
// sentinel through the option, find it in the struct, and take the first
// following slot that still holds the default AV_SAMPLE_FMT_NONE (-1).
codec_set_sample_fmt :: proc(ctx: ^AVCodecContext, sample_rate: int, fmt: Sample_Format) -> bool {
	SENTINEL   :: 0x5A17_C0DE
	SCAN_BYTES :: 640 // sample_rate sits well inside this in FFmpeg 6-8; the struct is larger

	if av_opt_set_int(ctx, "ar", SENTINEL, 0) < 0 {
		return false
	}
	words := ([^]i32)(ctx)[:SCAN_BYTES / 4]
	at := -1
	for w, i in words {
		if w == SENTINEL {
			if at >= 0 {
				at = -1 // ambiguous
				break
			}
			at = i
		}
	}
	if av_opt_set_int(ctx, "ar", i64(sample_rate), 0) < 0 || at < 0 {
		return false
	}
	for slot in at + 1 ..= at + 2 {
		if words[slot] == i32(SAMPLE_FMT_NONE) {
			words[slot] = i32(fmt)
			return true
		}
	}
	return false
}
