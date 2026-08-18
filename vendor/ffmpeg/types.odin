package ffmpeg

// Minimal FFmpeg 8.x types for encoding BGRA/NV12/YUV420P to H.264.
// Struct layouts match FFmpeg n8.1. Do not stack-allocate AVCodecContext or
// AVFrame; only use pointers returned by avcodec_alloc_context3 / av_frame_alloc.

AV_NUM_DATA_POINTERS         :: 8
AV_INPUT_BUFFER_PADDING_SIZE :: 64
AV_ERROR_MAX_STRING_SIZE     :: 64
AV_OPT_SEARCH_CHILDREN       :: 1
AV_PKT_FLAG_KEY              :: 0x0001
AV_CODEC_FLAG_LOW_DELAY      :: 1 << 19
AV_CODEC_FLAG_GLOBAL_HEADER  :: 1 << 22
AV_PICTURE_TYPE_I            :: 1

AV_LOG_QUIET   :: -8
AV_LOG_ERROR   :: 16
AV_LOG_WARNING :: 24
AV_LOG_INFO    :: 32
AV_LOG_VERBOSE :: 40
AV_LOG_DEBUG   :: 48

SWS_FAST_BILINEAR :: 1
SWS_BILINEAR      :: 2
SWS_BICUBIC       :: 4

// POSIX EAGAIN; FFmpeg's Windows compat headers use the same value.
AVERROR_EAGAIN :: i32(-11)
AVERROR_EOF    :: i32(-0x20464F45) // FFERRTAG('E','O','F',' ')

Pixel_Format :: distinct i32

PIX_FMT_NONE    :: Pixel_Format(-1)
PIX_FMT_YUV420P :: Pixel_Format(0)
PIX_FMT_NV12    :: Pixel_Format(23)
PIX_FMT_BGRA    :: Pixel_Format(28)

HW_Device_Type :: enum i32 {
	None         = 0,
	Vdpau        = 1,
	Cuda         = 2,
	Vaapi        = 3,
	Dxva2        = 4,
	Qsv          = 5,
	Videotoolbox = 6,
	D3d11va      = 7,
	Drm          = 8,
	Opencl       = 9,
	Mediacodec   = 10,
	Vulkan       = 11,
	D3d12va      = 12,
}

AVRational :: struct {
	num: i32,
	den: i32,
}

AVDictionary    :: struct {}
AVBuffer_Ref    :: struct {}
Sws_Context     :: struct {}
Sws_Filter      :: struct {}

// Public fields only. Name/id are enough to list available encoders.
AVCodec :: struct {
	name:         cstring,
	long_name:    cstring,
	type:         i32,
	id:           i32,
	capabilities: i32,
}

// FFmpeg 7.1 prefix of AVCodecContext. Remaining C fields exist past pix_fmt;
// never size_of() this or allocate it yourself.
AVCodecContext :: struct {
	av_class:            rawptr,
	log_level_offset:    i32,
	codec_type:          i32,
	codec:               ^AVCodec,
	codec_id:            i32,
	codec_tag:           u32,
	priv_data:           rawptr,
	internal:            rawptr,
	opaque:              rawptr,
	bit_rate:            i64,
	flags:               i32,
	flags2:              i32,
	extradata:           [^]u8,
	extradata_size:      i32,
	time_base:           AVRational,
	pkt_timebase:        AVRational,
	framerate:           AVRational,
	delay:               i32,
	width:               i32,
	height:              i32,
	coded_width:         i32,
	coded_height:        i32,
	sample_aspect_ratio: AVRational,
	pix_fmt:             Pixel_Format,
}

// FFmpeg 7.1 prefix through time_base. Never size_of() this.
AVFrame :: struct {
	data:                [AV_NUM_DATA_POINTERS][^]u8,
	linesize:            [AV_NUM_DATA_POINTERS]i32,
	extended_data:       [^][^]u8,
	width:               i32,
	height:              i32,
	nb_samples:          i32,
	format:              i32,
	pict_type:           i32,
	sample_aspect_ratio: AVRational,
	pts:                 i64,
	pkt_dts:             i64,
	time_base:           AVRational,
}

// Full FFmpeg 7.1 AVPacket ABI.
AVPacket :: struct {
	buf:             ^AVBuffer_Ref,
	pts:             i64,
	dts:             i64,
	data:            [^]u8,
	size:            i32,
	stream_index:    i32,
	flags:           i32,
	side_data:       rawptr,
	side_data_elems: i32,
	duration:        i64,
	pos:             i64,
	opaque:          rawptr,
	opaque_ref:      ^AVBuffer_Ref,
	time_base:       AVRational,
}
