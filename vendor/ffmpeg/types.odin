package ffmpeg

// Types shared by the bindings. Structs that FFmpeg changes between releases
// are declared opaque or as a stable prefix only; never size_of() them and
// only use pointers returned by the matching FFmpeg allocator.

AV_NUM_DATA_POINTERS     :: 8
AV_ERROR_MAX_STRING_SIZE :: 64
AV_OPT_SEARCH_CHILDREN   :: 1
AV_PKT_FLAG_KEY          :: 0x0001
AV_PICTURE_TYPE_NONE     :: 0
AV_PICTURE_TYPE_I        :: 1

AV_LOG_QUIET   :: -8
AV_LOG_PANIC   :: 0
AV_LOG_FATAL   :: 8
AV_LOG_ERROR   :: 16
AV_LOG_WARNING :: 24
AV_LOG_INFO    :: 32
AV_LOG_VERBOSE :: 40
AV_LOG_DEBUG   :: 48

SWS_FAST_BILINEAR :: 1
SWS_BILINEAR      :: 2
SWS_BICUBIC       :: 4

SWS_CS_ITU709 :: 1
SWS_CS_ITU601 :: 5

// AVERROR(EAGAIN): errno values differ per platform.
when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
	AVERROR_EAGAIN :: i32(-35)
} else {
	AVERROR_EAGAIN :: i32(-11)
}
AVERROR_EOF :: i32(-0x20464F45) // FFERRTAG('E','O','F',' ')

Pixel_Format :: distinct i32
PIX_FMT_NONE :: Pixel_Format(-1)

Sample_Format :: distinct i32
SAMPLE_FMT_NONE :: Sample_Format(-1)
SAMPLE_FMT_S16  :: Sample_Format(1) // interleaved signed 16 bit; stable since FFmpeg 0.x
SAMPLE_FMT_FLT  :: Sample_Format(3) // interleaved 32 bit float

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

AVBuffer_Ref :: struct {
	buffer: rawptr,
	data:   [^]u8,
	size:   uint,
}

AVDictionary      :: struct {}
AVCodec           :: struct {}
AVCodecContext    :: struct {}
AVCodecParameters :: struct {}
AVInputFormat     :: struct {}
Sws_Context       :: struct {}
Sws_Filter        :: struct {}

// Prefix of AVFrame that has not moved since FFmpeg 5. Later fields
// (pict_type, pts, buf) are reached through the accessors in abi.odin.
AVFrame :: struct {
	data:          [AV_NUM_DATA_POINTERS][^]u8,
	linesize:      [AV_NUM_DATA_POINTERS]i32,
	extended_data: [^][^]u8,
	width:         i32,
	height:        i32,
	nb_samples:    i32,
	format:        i32,
}

#assert(offset_of(AVFrame, width) == 104)
#assert(offset_of(AVFrame, format) == 116)

// Prefix of AVPacket, unchanged since FFmpeg 5.
AVPacket :: struct {
	buf:          ^AVBuffer_Ref,
	pts:          i64,
	dts:          i64,
	data:         [^]u8,
	size:         i32,
	stream_index: i32,
	flags:        i32,
}

// Prefix of AVFormatContext, unchanged since FFmpeg 4.
AVFormatContext :: struct {
	av_class:   rawptr,
	iformat:    ^AVInputFormat,
	oformat:    rawptr,
	priv_data:  rawptr,
	pb:         rawptr,
	ctx_flags:  i32,
	nb_streams: u32,
	streams:    [^]^AVStream,
}

// Prefix of AVStream as of libavformat 60 (FFmpeg 6.0). Older releases have no av_class.
AVStream :: struct {
	av_class: rawptr,
	index:    i32,
	id:       i32,
	codecpar: ^AVCodecParameters,
}
