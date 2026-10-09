#ifndef ODYSSEUS_NATIVE_H
#define ODYSSEUS_NATIVE_H

/* Public C API of the optional native shims linked into Odysseus
 * (libodysseus_native.a). Each platform section is implemented by its own
 * source file; keep this header free of platform includes. */

#ifdef __cplusplus
extern "C" {
#endif

/* ---- PipeWire / portal (Linux) -------------------------------------------
 * Implemented by pipewire_capture.c. Screen capture through the
 * xdg-desktop-portal ScreenCast / RemoteDesktop interfaces plus PipeWire.
 * ody_pw_open, ody_pw_read, ody_pw_size and ody_pw_close belong to one thread;
 * the ody_pw_pointer_* / ody_pw_keyboard_key calls may come from any thread
 * while the session is open (the caller must not close it concurrently). */

typedef struct ody_pw ody_pw;

typedef struct {
	int width, height, stride;      /* stride in bytes */
	int format;                     /* 0 = BGRx, 1 = BGRA, 2 = RGBx, 3 = RGBA */
	const unsigned char *data;      /* valid until the next ody_pw_read / ody_pw_close */
	long long timestamp_ns;         /* CLOCK_MONOTONIC */
} ody_pw_frame;

/* 1 when the session bus is reachable and the desktop portal offers ScreenCast,
 * 0 otherwise (reason in err). Cheap; lets the caller skip the backend quietly. */
int ody_pw_available(char *err, int err_len);

/* Runs the portal handshake and connects the PipeWire stream. Blocks until the
 * stream format is negotiated (or timeout_ms passes for the portal part; the
 * user may have to answer the desktop's "share your screen" dialog, so the
 * caller passes a long timeout).
 * remote_input != 0 asks for a RemoteDesktop session (keyboard + pointer) with
 * the screen cast attached; when the portal cannot do that the call falls back
 * to a plain ScreenCast session (ody_pw_remote_active then reports 0).
 * Returns NULL on failure with a human-readable reason in err; *denied is set
 * to 1 when the user refused the request (do not ask again right away). */
ody_pw *ody_pw_open(int cursor, int fps, int remote_input, int timeout_ms, int *denied, char *err, int err_len);
void    ody_pw_size(ody_pw *pw, int *width, int *height);

/* 1 = new frame in *out, 0 = no new frame within timeout_ms,
 * -1 = the stream failed, -2 = the portal session was closed (e.g. the user
 * stopped sharing; the saved restore token is dropped so the next share asks
 * again). Both negative results are final for this handle. */
int     ody_pw_read(ody_pw *pw, int timeout_ms, ody_pw_frame *out);
void    ody_pw_close(ody_pw *pw);

/* Remote input through the RemoteDesktop session (no-ops when it was not
 * requested or was denied). Fire-and-forget. */
int  ody_pw_remote_active(ody_pw *pw);
void ody_pw_pointer_motion(ody_pw *pw, double x, double y);   /* stream pixel coordinates */
void ody_pw_pointer_button(ody_pw *pw, int evdev_button, int pressed);
void ody_pw_pointer_axis(ody_pw *pw, double dx, double dy);   /* pixels, positive dy = down */
void ody_pw_keyboard_key(ody_pw *pw, int evdev_keycode, int pressed);

/* ---- ScreenCaptureKit (macOS) --------------------------------------------
 * Implemented by sck_capture.m (macOS 12.3+; system audio needs 13+).
 * Screen capture and system-audio capture are independent handles. */

typedef struct ody_sck ody_sck;

typedef struct {
	int width, height, stride;      /* BGRA, stride in bytes */
	const unsigned char *data;      /* valid until the next ody_sck_read / ody_sck_close */
} ody_sck_frame;

/* display_index indexes CGGetActiveDisplayList. Blocks until the stream runs or
 * fails; the first call may raise the Screen Recording permission prompt.
 * Returns NULL on failure with a human-readable reason in err. */
ody_sck *ody_sck_open(int display_index, int fps, int cursor, char *err, int err_len);
void     ody_sck_size(ody_sck *s, int *width, int *height);

/* 1 = new frame in *out, 0 = no new frame within timeout_ms (static screen),
 * -1 = the stream stopped or failed (final for this handle). */
int      ody_sck_read(ody_sck *s, int timeout_ms, ody_sck_frame *out);
void     ody_sck_close(ody_sck *s);

typedef struct ody_sck_audio ody_sck_audio;

/* Receives interleaved stereo float32 at 48 kHz on a ScreenCaptureKit queue. */
typedef void (*ody_sck_audio_cb)(void *user, const float *samples, int frame_count);

/* Starts capturing what the system plays. NULL on failure with the reason in err. */
ody_sck_audio *ody_sck_audio_start(ody_sck_audio_cb cb, void *user, char *err, int err_len);
/* Returns only after no further callback will run. */
void           ody_sck_audio_stop(ody_sck_audio *a);

#ifdef __cplusplus
}
#endif

#endif /* ODYSSEUS_NATIVE_H */
