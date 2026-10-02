package audio

import "core:sync"
import "core:time"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

// System audio capture + Opus encoding. `start` opens the platform's loopback
// source (what the speakers play), encodes 20 ms Opus frames and hands each
// packet to the sink on the capture thread.
//
// Each platform file (audio_*.odin) implements capture_start / capture_stop
// and feeds interleaved 48 kHz stereo S16 samples to push_pcm.

Config :: struct {
	device:       string, // capture device name (substring); "" picks the default output loopback
	bitrate_kbps: int,
}

// Sink receives one Opus packet and the monotonic time (time.tick_now clock,
// in nanoseconds) at which its first sample was captured.
Sink :: proc(user: rawptr, packet: []byte, capture_ns: i64)

SAMPLE_RATE   :: 48000
CHANNELS      :: 2
FRAME_SAMPLES :: 960 // 20 ms

// A capture gap longer than this (the loopback device goes quiet when nothing
// plays) restarts the sample clock instead of stretching audio over it.
@(private)
RESYNC_THRESHOLD_NS :: 60 * i64(time.Millisecond)

Stream :: struct {
	sink:     Sink,
	user:     rawptr,
	platform: rawptr, // capture backend state

	mu:      sync.Mutex, // push_pcm vs stop
	stopped: bool,

	ctx:    ^ffmpeg.AVCodecContext,
	frame:  ^ffmpeg.AVFrame,
	packet: ^ffmpeg.AVPacket,
	pts:    i64,

	pending:    [FRAME_SAMPLES * CHANNELS]i16, // samples waiting for a full frame
	pending_n:  int,                           // in samples (per channel)
	clock_base: i64,                           // capture time of sample 0 of this run
	clock_done: i64,                           // samples consumed since clock_base
	clock_set:  bool,
}

// start opens the capture device and the Opus encoder. nil means audio is
// unavailable (no device, no libopus in this FFmpeg, unknown FFmpeg ABI);
// the reason is logged and video is unaffected.
start :: proc(cfg: Config, sink: Sink, user: rawptr) -> ^Stream {
	s := new(Stream)
	s.sink = sink
	s.user = user
	if !opus_open(s, cfg.bitrate_kbps) {
		opus_close(s)
		free(s)
		return nil
	}
	if !capture_start(s, cfg.device) {
		opus_close(s)
		free(s)
		return nil
	}
	return s
}

stop :: proc(s: ^Stream) {
	if s == nil {
		return
	}
	sync.lock(&s.mu)
	s.stopped = true
	sync.unlock(&s.mu)
	capture_stop(s) // returns once the capture thread no longer calls push_pcm
	opus_close(s)
	free(s)
}

now_ns :: proc() -> i64 {
	return time.tick_now()._nsec
}

// push_pcm takes interleaved stereo S16 samples from the capture backend.
// end_ns is the capture time of the end of this chunk (now, for live devices).
push_pcm :: proc(s: ^Stream, samples: []i16, end_ns: i64) {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if s.stopped {
		return
	}

	count := len(samples) / CHANNELS
	if count == 0 {
		return
	}
	chunk_ns := i64(count) * i64(time.Second) / SAMPLE_RATE
	start_ns := end_ns - chunk_ns

	// Sample clock: timestamps advance by sample count (jitter-free) and
	// re-anchor to the wall clock after a gap.
	expected := s.clock_base + (s.clock_done + i64(s.pending_n)) * i64(time.Second) / SAMPLE_RATE
	if !s.clock_set || abs(start_ns - expected) > RESYNC_THRESHOLD_NS {
		s.clock_base = start_ns
		s.clock_done = 0
		s.pending_n = 0
		s.clock_set = true
	}

	src := samples
	for len(src) >= CHANNELS {
		room := FRAME_SAMPLES - s.pending_n
		take := min(room, len(src) / CHANNELS)
		copy(s.pending[s.pending_n * CHANNELS:], src[:take * CHANNELS])
		s.pending_n += take
		src = src[take * CHANNELS:]
		if s.pending_n == FRAME_SAMPLES {
			frame_ns := s.clock_base + s.clock_done * i64(time.Second) / SAMPLE_RATE
			opus_encode(s, frame_ns)
			s.clock_done += FRAME_SAMPLES
			s.pending_n = 0
		}
	}
}

// push_pcm_f32 is push_pcm for backends that deliver interleaved stereo float samples.
push_pcm_f32 :: proc(s: ^Stream, samples: []f32, end_ns: i64) {
	buf: [FRAME_SAMPLES * CHANNELS]i16
	src := samples
	chunk_ns_per_sample := i64(time.Second) / SAMPLE_RATE
	for len(src) > 0 {
		n := min(len(src), len(buf))
		for i in 0 ..< n {
			buf[i] = i16(clamp(src[i], -1, 1) * 32767)
		}
		src = src[n:]
		// The remaining samples were captured after this part.
		part_end := end_ns - i64(len(src) / CHANNELS) * chunk_ns_per_sample
		push_pcm(s, buf[:n], part_end)
	}
}

@(private)
opus_open :: proc(s: ^Stream, bitrate_kbps: int) -> bool {
	codec := ffmpeg.avcodec_find_encoder_by_name("libopus")
	if codec == nil {
		utils.log_warn("audio disabled: this FFmpeg build has no libopus encoder")
		return false
	}
	s.frame = ffmpeg.av_frame_alloc()
	s.packet = ffmpeg.av_packet_alloc()
	s.ctx = ffmpeg.avcodec_alloc_context3(codec)
	if s.frame == nil || s.packet == nil || s.ctx == nil {
		return false
	}
	// Audio frames are attached through AVFrame.buf, whose offset depends on the FFmpeg release.
	if ffmpeg.frame_buf_slot(s.frame) == nil {
		utils.log_warn("audio disabled: unknown AVFrame layout in this FFmpeg release")
		return false
	}

	child: i32 = ffmpeg.AV_OPT_SEARCH_CHILDREN
	bitrate := i64(bitrate_kbps if bitrate_kbps > 0 else 128) * 1000
	if ffmpeg.av_opt_set(s.ctx, "ch_layout", "stereo", 0) < 0 ||
	   !ffmpeg.codec_set_sample_fmt(s.ctx, SAMPLE_RATE, ffmpeg.SAMPLE_FMT_S16) {
		utils.log_warn("audio disabled: could not configure the Opus encoder on this FFmpeg release")
		return false
	}
	ffmpeg.av_opt_set_int(s.ctx, "b", bitrate, 0)
	ffmpeg.av_opt_set_q(s.ctx, "time_base", ffmpeg.rational(1, SAMPLE_RATE), 0)
	ffmpeg.av_opt_set(s.ctx, "application", "lowdelay", child)
	ffmpeg.av_opt_set(s.ctx, "frame_duration", "20", child)
	ffmpeg.av_opt_set(s.ctx, "vbr", "on", child)

	if rc := ffmpeg.avcodec_open2(s.ctx, codec, nil); rc < 0 {
		buf: [ffmpeg.AV_ERROR_MAX_STRING_SIZE]u8
		utils.log_warn("audio disabled: libopus: %s", ffmpeg.error_string(rc, buf[:]))
		return false
	}
	return true
}

@(private)
opus_close :: proc(s: ^Stream) {
	if s.ctx != nil && s.packet != nil {
		// Flush so libopus does not complain about frames left in its queue.
		if ffmpeg.avcodec_send_frame(s.ctx, nil) >= 0 {
			for ffmpeg.avcodec_receive_packet(s.ctx, s.packet) >= 0 {
				ffmpeg.av_packet_unref(s.packet)
			}
		}
	}
	if s.frame != nil {
		ffmpeg.av_frame_free(&s.frame)
	}
	if s.packet != nil {
		ffmpeg.av_packet_free(&s.packet)
	}
	if s.ctx != nil {
		ffmpeg.avcodec_free_context(&s.ctx)
	}
}

// Encodes s.pending (one full frame) and passes the packets to the sink.
@(private)
opus_encode :: proc(s: ^Stream, capture_ns: i64) {
	BYTES :: FRAME_SAMPLES * CHANNELS * size_of(i16)

	// A reference-counted frame: the codec keeps its own reference, so the
	// buffer is fresh for every frame.
	ffmpeg.av_frame_unref(s.frame)
	buf := ffmpeg.av_buffer_alloc(BYTES)
	if buf == nil {
		return
	}
	copy(buf.data[:BYTES], ([^]u8)(&s.pending[0])[:BYTES])
	ffmpeg.frame_buf_slot(s.frame)^ = buf
	s.frame.data[0] = buf.data
	s.frame.linesize[0] = BYTES
	s.frame.nb_samples = FRAME_SAMPLES
	s.frame.format = i32(ffmpeg.SAMPLE_FMT_S16)
	ffmpeg.frame_set_pts(s.frame, s.pts)
	s.pts += FRAME_SAMPLES

	rc := ffmpeg.avcodec_send_frame(s.ctx, s.frame)
	ffmpeg.av_frame_unref(s.frame)
	if rc < 0 && !ffmpeg.is_again(rc) {
		return
	}
	for {
		recv := ffmpeg.avcodec_receive_packet(s.ctx, s.packet)
		if recv < 0 {
			break
		}
		if s.packet.size > 0 && s.packet.data != nil {
			s.sink(s.user, s.packet.data[:s.packet.size], capture_ns)
		}
		ffmpeg.av_packet_unref(s.packet)
	}
}
