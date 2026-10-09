// ScreenCaptureKit capture for Odysseus: screen frames (macOS 12.3+) and
// system audio (macOS 13+). Plain C API, declared in odysseus_native.h.
//
// Build: clang -O2 -fobjc-arc -mmacosx-version-min=12.3 -c sck_capture.m
// Link:  -framework ScreenCaptureKit (or -weak_framework, see below) plus
//        CoreMedia, CoreVideo, CoreGraphics, Foundation.
//
// Both capture objects are Objective-C classes whose retained pointer is the
// opaque handle handed to C; close/stop release it. Every entry point catches
// Objective-C exceptions so nothing unwinds into Odin.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "odysseus_native.h"

#define ODY_PERMISSION_HINT \
	"Screen Recording permission missing (System Settings \xE2\x86\x92 Privacy & Security \xE2\x86\x92 Screen Recording)"

// Handshakes with ScreenCaptureKit (permission prompt, stream start) wait at
// most this long, so a stuck prompt cannot hang the caller forever.
#define ODY_START_TIMEOUT_SEC 30
#define ODY_STOP_TIMEOUT_SEC  5

static void ody_errf(char *err, int err_len, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

static void ody_errf(char *err, int err_len, const char *fmt, ...)
{
	if (err == NULL || err_len <= 0) {
		return;
	}
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(err, (size_t)err_len, fmt, ap);
	va_end(ap);
}

static const char *ody_cstr(NSString *s)
{
	const char *c = (s != nil) ? [s UTF8String] : NULL;
	return (c != NULL) ? c : "";
}

// Blocks until the completion handler of a stop/start call has run, or the timeout expires.
static BOOL ody_wait(dispatch_semaphore_t sem, int seconds)
{
	return dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * (int64_t)NSEC_PER_SEC)) == 0;
}

// The shareable displays, fetched synchronously. nil with a message in err on failure.
static SCShareableContent *ody_shareable_content(char *err, int err_len) API_AVAILABLE(macos(12.3));

static SCShareableContent *ody_shareable_content(char *err, int err_len)
{
	__block SCShareableContent *content = nil;
	__block NSError *error = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[SCShareableContent getShareableContentExcludingDesktopWindows:YES
	                                           onScreenWindowsOnly:YES
	                                             completionHandler:^(SCShareableContent *c, NSError *e) {
		content = c;
		error = e;
		dispatch_semaphore_signal(done);
	}];
	if (!ody_wait(done, ODY_START_TIMEOUT_SEC)) {
		ody_errf(err, err_len, "ScreenCaptureKit did not answer in time. %s", ODY_PERMISSION_HINT);
		return nil;
	}
	if (content == nil) {
		ody_errf(err, err_len, "ScreenCaptureKit: %s. %s",
		         ody_cstr([error localizedDescription]), ODY_PERMISSION_HINT);
		return nil;
	}
	return content;
}

static SCDisplay *ody_find_display(SCShareableContent *content, CGDirectDisplayID id) API_AVAILABLE(macos(12.3));

static SCDisplay *ody_find_display(SCShareableContent *content, CGDirectDisplayID id)
{
	for (SCDisplay *d in [content displays]) {
		if ([d displayID] == id) {
			return d;
		}
	}
	return nil;
}

// ============================================================================
// Video
// ============================================================================

API_AVAILABLE(macos(12.3))
@interface OdySCKVideo : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
- (instancetype)initWithWidth:(int)width height:(int)height;
- (BOOL)startOnDisplay:(SCDisplay *)display fps:(int)fps cursor:(BOOL)cursor err:(char *)err errLen:(int)errLen;
- (int)readWithTimeoutMs:(int)timeoutMs frame:(ody_sck_frame *)out;
- (void)shutdown;
@end

@implementation OdySCKVideo {
	SCStream *_stream;
	dispatch_queue_t _queue;

	NSCondition *_cond; // guards everything below
	uint8_t *_buf[2];   // width * height * 4 bytes each
	int _latest;        // buffer holding the newest frame
	int _held;          // buffer handed to the reader, -1 when none; the writer never touches it
	BOOL _fresh;        // _latest has not been handed out yet
	BOOL _dead;         // stream stopped by the system
}

@synthesize width = _width;
@synthesize height = _height;

- (instancetype)initWithWidth:(int)width height:(int)height
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_width = width;
	_height = height;
	_cond = [[NSCondition alloc] init];
	_held = -1;
	_latest = 0;
	size_t bytes = (size_t)width * (size_t)height * 4;
	_buf[0] = (uint8_t *)calloc(1, bytes);
	_buf[1] = (uint8_t *)calloc(1, bytes);
	if (_buf[0] == NULL || _buf[1] == NULL) {
		return nil; // dealloc frees whichever allocation succeeded
	}
	return self;
}

- (void)dealloc
{
	free(_buf[0]);
	free(_buf[1]);
}

- (BOOL)startOnDisplay:(SCDisplay *)display fps:(int)fps cursor:(BOOL)cursor err:(char *)err errLen:(int)errLen
{
	SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

	SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
	config.width = (size_t)_width;
	config.height = (size_t)_height;
	config.pixelFormat = kCVPixelFormatType_32BGRA;
	config.minimumFrameInterval = CMTimeMake(1, fps);
	config.showsCursor = cursor;
	config.queueDepth = 5;
	config.colorSpaceName = kCGColorSpaceSRGB;

	_queue = dispatch_queue_create("odysseus.sck.video", DISPATCH_QUEUE_SERIAL);
	_stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
	if (_stream == nil) {
		ody_errf(err, errLen, "could not create the ScreenCaptureKit stream");
		return NO;
	}

	NSError *addError = nil;
	if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&addError]) {
		ody_errf(err, errLen, "could not attach the screen output: %s", ody_cstr([addError localizedDescription]));
		[self shutdown];
		return NO;
	}

	__block NSError *startError = nil;
	dispatch_semaphore_t started = dispatch_semaphore_create(0);
	[_stream startCaptureWithCompletionHandler:^(NSError *e) {
		startError = e;
		dispatch_semaphore_signal(started);
	}];
	if (!ody_wait(started, ODY_START_TIMEOUT_SEC)) {
		ody_errf(err, errLen, "ScreenCaptureKit did not start in time. %s", ODY_PERMISSION_HINT);
		[self shutdown];
		return NO;
	}
	if (startError != nil) {
		ody_errf(err, errLen, "ScreenCaptureKit could not start: %s. %s",
		         ody_cstr([startError localizedDescription]), ODY_PERMISSION_HINT);
		[self shutdown];
		return NO;
	}
	return YES;
}

// Stops the stream and returns once no callback of this object can run any more.
- (void)shutdown
{
	SCStream *stream = _stream;
	if (stream != nil) {
		dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
		[stream stopCaptureWithCompletionHandler:^(NSError *e) {
			dispatch_semaphore_signal(stopped);
		}];
		ody_wait(stopped, ODY_STOP_TIMEOUT_SEC);
		[stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
	}
	if (_queue != nil) {
		dispatch_sync(_queue, ^{
		});
	}
	// Drops the stream's references to self; there is no retain cycle left.
	_stream = nil;
	_queue = nil;

	[_cond lock];
	_dead = YES;
	[_cond broadcast];
	[_cond unlock];
}

- (int)readWithTimeoutMs:(int)timeoutMs frame:(ody_sck_frame *)out
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(timeoutMs > 0 ? (double)timeoutMs / 1000.0 : 0.0)];
	int rc;

	[_cond lock];
	while (!_fresh && !_dead) {
		if (![_cond waitUntilDate:deadline]) {
			break; // timed out
		}
	}
	if (_fresh) {
		_held = _latest;
		_fresh = NO;
		out->width = _width;
		out->height = _height;
		out->stride = _width * 4;
		out->data = _buf[_held];
		rc = 1;
	} else if (_dead) {
		rc = -1;
	} else {
		rc = 0;
	}
	[_cond unlock];
	return rc;
}

- (void)storePixelBuffer:(CVPixelBufferRef)pb
{
	if (CVPixelBufferIsPlanar(pb) || CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) {
		return;
	}
	if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
		return;
	}
	const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
	size_t srcStride = CVPixelBufferGetBytesPerRow(pb);
	// Copy the overlap if the delivered size ever differs from the configured one.
	size_t cols = CVPixelBufferGetWidth(pb);
	size_t rows = CVPixelBufferGetHeight(pb);
	if (cols > (size_t)_width) {
		cols = (size_t)_width;
	}
	if (rows > (size_t)_height) {
		rows = (size_t)_height;
	}
	if (src != NULL && cols > 0 && rows > 0) {
		size_t dstStride = (size_t)_width * 4;
		[_cond lock];
		int wi = (_held == 0) ? 1 : 0;
		uint8_t *dst = _buf[wi];
		if (srcStride == dstStride && cols == (size_t)_width && rows == (size_t)_height) {
			memcpy(dst, src, dstStride * rows);
		} else {
			for (size_t y = 0; y < rows; y++) {
				memcpy(dst + y * dstStride, src + y * srcStride, cols * 4);
			}
		}
		_latest = wi;
		_fresh = YES;
		[_cond signal];
		[_cond unlock];
	}
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

#pragma mark SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type
{
	if (type != SCStreamOutputTypeScreen) {
		return;
	}
	if (!CMSampleBufferIsValid(sampleBuffer) || !CMSampleBufferDataIsReady(sampleBuffer)) {
		return;
	}

	// Idle / blank / suspended frames carry no new image.
	CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
	if (attachments == NULL || CFArrayGetCount(attachments) == 0) {
		return;
	}
	NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
	NSNumber *status = [info objectForKey:SCStreamFrameInfoStatus];
	if (status == nil || (SCFrameStatus)[status integerValue] != SCFrameStatusComplete) {
		return;
	}

	CVImageBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
	if (image == NULL) {
		return;
	}
	[self storePixelBuffer:(CVPixelBufferRef)image];
}

#pragma mark SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
	[_cond lock];
	_dead = YES;
	[_cond broadcast];
	[_cond unlock];
}

@end

ody_sck *ody_sck_open(int display_index, int fps, int cursor, char *err, int err_len)
{
	@autoreleasepool {
		@try {
			if (@available(macOS 12.3, *)) {
				if (fps < 1) {
					fps = 30;
				} else if (fps > 120) {
					fps = 120;
				}

				CGDirectDisplayID ids[16];
				uint32_t count = 0;
				if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || display_index < 0 ||
				    (uint32_t)display_index >= count) {
					ody_errf(err, err_len, "display %d does not exist", display_index);
					return NULL;
				}
				CGDirectDisplayID display_id = ids[display_index];

				// Native pixels, not points: Retina displays are captured at full resolution.
				size_t pixel_w = 0;
				size_t pixel_h = 0;
				CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display_id);
				if (mode != NULL) {
					pixel_w = CGDisplayModeGetPixelWidth(mode);
					pixel_h = CGDisplayModeGetPixelHeight(mode);
					CGDisplayModeRelease(mode);
				}
				if (pixel_w == 0 || pixel_h == 0) {
					pixel_w = CGDisplayPixelsWide(display_id);
					pixel_h = CGDisplayPixelsHigh(display_id);
				}
				if (pixel_w == 0 || pixel_h == 0 || pixel_w > 16384 || pixel_h > 16384) {
					ody_errf(err, err_len, "display %d reports an unusable size", display_index);
					return NULL;
				}

				SCShareableContent *content = ody_shareable_content(err, err_len);
				if (content == nil) {
					return NULL;
				}
				SCDisplay *display = ody_find_display(content, display_id);
				if (display == nil) {
					ody_errf(err, err_len, "ScreenCaptureKit does not list display %d", display_index);
					return NULL;
				}

				OdySCKVideo *video = [[OdySCKVideo alloc] initWithWidth:(int)pixel_w height:(int)pixel_h];
				if (video == nil) {
					ody_errf(err, err_len, "out of memory for the frame buffers");
					return NULL;
				}
				if (![video startOnDisplay:display fps:fps cursor:(cursor != 0) err:err errLen:err_len]) {
					return NULL;
				}
				return (ody_sck *)CFBridgingRetain(video);
			}
			ody_errf(err, err_len, "ScreenCaptureKit needs macOS 12.3 or newer");
			return NULL;
		} @catch (NSException *e) {
			ody_errf(err, err_len, "ScreenCaptureKit exception: %s", ody_cstr([e reason]));
			return NULL;
		}
	}
}

void ody_sck_size(ody_sck *s, int *width, int *height)
{
	if (width != NULL) {
		*width = 0;
	}
	if (height != NULL) {
		*height = 0;
	}
	if (s == NULL) {
		return;
	}
	if (@available(macOS 12.3, *)) {
		OdySCKVideo *video = (__bridge OdySCKVideo *)(void *)s;
		if (width != NULL) {
			*width = [video width];
		}
		if (height != NULL) {
			*height = [video height];
		}
	}
}

int ody_sck_read(ody_sck *s, int timeout_ms, ody_sck_frame *out)
{
	if (s == NULL || out == NULL) {
		return -1;
	}
	@autoreleasepool {
		@try {
			if (@available(macOS 12.3, *)) {
				OdySCKVideo *video = (__bridge OdySCKVideo *)(void *)s;
				return [video readWithTimeoutMs:timeout_ms frame:out];
			}
		} @catch (NSException *e) {
		}
	}
	return -1;
}

void ody_sck_close(ody_sck *s)
{
	if (s == NULL) {
		return;
	}
	@autoreleasepool {
		@try {
			if (@available(macOS 12.3, *)) {
				OdySCKVideo *video = (__bridge_transfer OdySCKVideo *)(void *)s;
				[video shutdown];
			}
		} @catch (NSException *e) {
		}
	}
}

// ============================================================================
// System audio
// ============================================================================

// Writes interleaved stereo floats for the PCM in `abl` to dst and returns the
// frame count. Handles interleaved and planar float32 with any channel count
// (mono is duplicated, extra channels beyond the first two are dropped).
// dst holds `dst_frames` stereo frames. Returns 0 for an unusable layout.
static size_t ody_interleave_stereo(const AudioBufferList *abl, const AudioStreamBasicDescription *asbd,
                                    float *dst, size_t dst_frames)
{
	uint32_t channels = asbd->mChannelsPerFrame;
	if (abl->mNumberBuffers == 0 || channels == 0) {
		return 0;
	}
	BOOL planar = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

	if (planar) {
		const float *left = (const float *)abl->mBuffers[0].mData;
		size_t frames = abl->mBuffers[0].mDataByteSize / sizeof(float);
		const float *right = left;
		if (abl->mNumberBuffers >= 2) {
			right = (const float *)abl->mBuffers[1].mData;
			size_t frames_r = abl->mBuffers[1].mDataByteSize / sizeof(float);
			if (frames_r < frames) {
				frames = frames_r;
			}
		}
		if (left == NULL || right == NULL || frames == 0 || frames > dst_frames) {
			return 0;
		}
		for (size_t i = 0; i < frames; i++) {
			dst[2 * i] = left[i];
			dst[2 * i + 1] = right[i];
		}
		return frames;
	}

	const float *src = (const float *)abl->mBuffers[0].mData;
	size_t frames = abl->mBuffers[0].mDataByteSize / (sizeof(float) * channels);
	if (src == NULL || frames == 0 || frames > dst_frames) {
		return 0;
	}
	for (size_t i = 0; i < frames; i++) {
		float l = src[i * channels];
		float r = (channels >= 2) ? src[i * channels + 1] : l;
		dst[2 * i] = l;
		dst[2 * i + 1] = r;
	}
	return frames;
}

API_AVAILABLE(macos(13.0))
@interface OdySCKAudio : NSObject <SCStreamOutput, SCStreamDelegate>
- (instancetype)initWithCallback:(ody_sck_audio_cb)cb user:(void *)user;
- (BOOL)startOnDisplay:(SCDisplay *)display err:(char *)err errLen:(int)errLen;
- (void)shutdown;
@end

@implementation OdySCKAudio {
	SCStream *_stream;
	dispatch_queue_t _queue;
	ody_sck_audio_cb _cb;
	void *_user;
	_Atomic int _stopping; // set before shutdown drains the queue; later callbacks return at once
	float *_scratch;       // only touched on _queue
	size_t _scratchFrames;
}

- (instancetype)initWithCallback:(ody_sck_audio_cb)cb user:(void *)user
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_cb = cb;
	_user = user;
	atomic_store(&_stopping, 0);
	return self;
}

- (void)dealloc
{
	free(_scratch);
}

- (BOOL)startOnDisplay:(SCDisplay *)display err:(char *)err errLen:(int)errLen
{
	SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

	// A stream cannot be audio-only: it needs a display filter and produces
	// video frames, so the video part is cut down to a tiny, slow stream and
	// its frames are discarded in the handler. A screen output is attached as
	// well; without one ScreenCaptureKit logs "stream output NOT found" for
	// every dropped frame.
	SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
	config.width = 16;
	config.height = 16;
	config.pixelFormat = kCVPixelFormatType_32BGRA;
	config.minimumFrameInterval = CMTimeMake(1, 1);
	config.showsCursor = NO;
	config.capturesAudio = YES;
	config.sampleRate = 48000;
	config.channelCount = 2;
	config.excludesCurrentProcessAudio = YES;

	_queue = dispatch_queue_create("odysseus.sck.audio", DISPATCH_QUEUE_SERIAL);
	_stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
	if (_stream == nil) {
		ody_errf(err, errLen, "could not create the ScreenCaptureKit audio stream");
		return NO;
	}

	NSError *addError = nil;
	if (![_stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:_queue error:&addError]) {
		ody_errf(err, errLen, "could not attach the audio output: %s", ody_cstr([addError localizedDescription]));
		[self shutdown];
		return NO;
	}
	addError = nil;
	if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&addError]) {
		ody_errf(err, errLen, "could not attach the placeholder screen output: %s", ody_cstr([addError localizedDescription]));
		[self shutdown];
		return NO;
	}

	__block NSError *startError = nil;
	dispatch_semaphore_t started = dispatch_semaphore_create(0);
	[_stream startCaptureWithCompletionHandler:^(NSError *e) {
		startError = e;
		dispatch_semaphore_signal(started);
	}];
	if (!ody_wait(started, ODY_START_TIMEOUT_SEC)) {
		ody_errf(err, errLen, "ScreenCaptureKit audio did not start in time. %s", ODY_PERMISSION_HINT);
		[self shutdown];
		return NO;
	}
	if (startError != nil) {
		ody_errf(err, errLen, "ScreenCaptureKit audio could not start: %s. %s",
		         ody_cstr([startError localizedDescription]), ODY_PERMISSION_HINT);
		[self shutdown];
		return NO;
	}
	return YES;
}

// Stops the stream and returns once no callback can be running any more.
- (void)shutdown
{
	atomic_store(&_stopping, 1);
	SCStream *stream = _stream;
	if (stream != nil) {
		dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
		[stream stopCaptureWithCompletionHandler:^(NSError *e) {
			dispatch_semaphore_signal(stopped);
		}];
		ody_wait(stopped, ODY_STOP_TIMEOUT_SEC);
		[stream removeStreamOutput:self type:SCStreamOutputTypeAudio error:nil];
		[stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
	}
	if (_queue != nil) {
		// Waits for a callback that is already running; later ones see _stopping.
		dispatch_sync(_queue, ^{
		});
	}
	_stream = nil;
	_queue = nil;
}

#pragma mark SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type
{
	if (type != SCStreamOutputTypeAudio) {
		return; // the placeholder video frames
	}
	if (atomic_load(&_stopping) != 0) {
		return;
	}
	if (!CMSampleBufferIsValid(sampleBuffer) || !CMSampleBufferDataIsReady(sampleBuffer)) {
		return;
	}

	CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
	if (format == NULL) {
		return;
	}
	const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
	if (asbd == NULL || asbd->mFormatID != kAudioFormatLinearPCM ||
	    (asbd->mFormatFlags & kAudioFormatFlagIsFloat) == 0 || asbd->mBitsPerChannel != 32 ||
	    asbd->mSampleRate != 48000.0) {
		return; // not what was asked for; the consumer expects 48 kHz float
	}

	// A planar stereo buffer list has two AudioBuffers, one more than the struct declares.
	union {
		AudioBufferList list;
		uint8_t storage[sizeof(AudioBufferList) + 15 * sizeof(AudioBuffer)];
	} u;
	memset(&u, 0, sizeof(u));
	size_t needed = 0;
	CMBlockBufferRef block = NULL;
	OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
		sampleBuffer, &needed, &u.list, sizeof(u), kCFAllocatorDefault, kCFAllocatorDefault,
		kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
	if (st != noErr) {
		if (block != NULL) {
			CFRelease(block);
		}
		return;
	}

	CMItemCount samples = CMSampleBufferGetNumSamples(sampleBuffer);
	size_t capacity = (samples > 0) ? (size_t)samples : 0;
	// Prefer the buffer's own size over the sample count in case they disagree.
	if (u.list.mNumberBuffers > 0 && asbd->mBytesPerFrame > 0) {
		size_t from_bytes = u.list.mBuffers[0].mDataByteSize / asbd->mBytesPerFrame;
		if (from_bytes > capacity) {
			capacity = from_bytes;
		}
	}
	if (capacity > 0) {
		if (capacity > _scratchFrames) {
			float *grown = (float *)realloc(_scratch, capacity * 2 * sizeof(float));
			if (grown == NULL) {
				if (block != NULL) {
					CFRelease(block);
				}
				return;
			}
			_scratch = grown;
			_scratchFrames = capacity;
		}
		size_t frames = ody_interleave_stereo(&u.list, asbd, _scratch, _scratchFrames);
		if (frames > 0 && _cb != NULL) {
			_cb(_user, _scratch, (int)frames);
		}
	}
	if (block != NULL) {
		CFRelease(block);
	}
}

#pragma mark SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
	// Nothing to do: the consumer just stops receiving samples. A restart is the caller's decision.
}

@end

ody_sck_audio *ody_sck_audio_start(ody_sck_audio_cb cb, void *user, char *err, int err_len)
{
	if (cb == NULL) {
		ody_errf(err, err_len, "no audio callback");
		return NULL;
	}
	@autoreleasepool {
		@try {
			if (@available(macOS 13.0, *)) {
				SCShareableContent *content = ody_shareable_content(err, err_len);
				if (content == nil) {
					return NULL;
				}
				// System audio is not tied to a display; use the main one for the required filter.
				SCDisplay *display = ody_find_display(content, CGMainDisplayID());
				if (display == nil) {
					display = [[content displays] firstObject];
				}
				if (display == nil) {
					ody_errf(err, err_len, "ScreenCaptureKit lists no display");
					return NULL;
				}
				OdySCKAudio *audio = [[OdySCKAudio alloc] initWithCallback:cb user:user];
				if (audio == nil) {
					ody_errf(err, err_len, "out of memory");
					return NULL;
				}
				if (![audio startOnDisplay:display err:err errLen:err_len]) {
					return NULL;
				}
				return (ody_sck_audio *)CFBridgingRetain(audio);
			}
			ody_errf(err, err_len, "system audio capture needs macOS 13 or newer");
			return NULL;
		} @catch (NSException *e) {
			ody_errf(err, err_len, "ScreenCaptureKit exception: %s", ody_cstr([e reason]));
			return NULL;
		}
	}
}

void ody_sck_audio_stop(ody_sck_audio *a)
{
	if (a == NULL) {
		return;
	}
	@autoreleasepool {
		@try {
			if (@available(macOS 13.0, *)) {
				OdySCKAudio *audio = (__bridge_transfer OdySCKAudio *)(void *)a;
				[audio shutdown];
			}
		} @catch (NSException *e) {
		}
	}
}
