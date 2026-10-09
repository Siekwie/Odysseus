package core

// Wayland screen capture through xdg-desktop-portal + PipeWire, and remote
// input through the portal's RemoteDesktop session. The portal handshake and
// the PipeWire stream live in a C shim (src/native/pipewire_capture.c) because
// libpipewire's pod builders are inline macros; build.sh compiles it into
// libodysseus_native.a and sets ODYSSEUS_PIPEWIRE. Without it the backend
// reports .Not_Supported and the X11 backend takes over.

import "core:c"
import "core:sync"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

ODYSSEUS_PIPEWIRE :: #config(ODYSSEUS_PIPEWIRE, false)

when ODYSSEUS_PIPEWIRE {

foreign import native "system:odysseus_native"

@(private = "file")
Native_Frame :: struct {
	width, height, stride: c.int,
	format:                c.int, // 0 = BGRx, 1 = BGRA, 2 = RGBx, 3 = RGBA
	data:                  [^]u8,
	timestamp_ns:          c.longlong,
}

@(private = "file")
@(default_calling_convention = "c")
foreign native {
	ody_pw_available :: proc(err: [^]u8, err_len: c.int) -> c.int ---
	ody_pw_open :: proc(cursor, fps, remote_input, timeout_ms: c.int, denied: ^c.int, err: [^]u8, err_len: c.int) -> rawptr ---
	ody_pw_size :: proc(pw: rawptr, width, height: ^c.int) ---
	ody_pw_read :: proc(pw: rawptr, timeout_ms: c.int, out: ^Native_Frame) -> c.int ---
	ody_pw_close :: proc(pw: rawptr) ---
	ody_pw_remote_active :: proc(pw: rawptr) -> c.int ---
	ody_pw_pointer_motion :: proc(pw: rawptr, x, y: f64) ---
	ody_pw_pointer_button :: proc(pw: rawptr, button, pressed: c.int) ---
	ody_pw_pointer_axis :: proc(pw: rawptr, dx, dy: f64) ---
	ody_pw_keyboard_key :: proc(pw: rawptr, keycode, pressed: c.int) ---
}

// The user may have to answer the desktop's "share your screen" dialog.
@(private = "file")
PORTAL_TIMEOUT_MS :: 60_000

@(private = "file")
Capture_PW :: struct {
	handle: rawptr,
	width:  int,
	height: int,
	// Pixel formats in the shim's numbering, looked up once.
	formats: [4]ffmpeg.Pixel_Format,
	// Pixels stay valid until the next ody_pw_read, so a timeout can repeat them.
	last: Frame,
}

// The session the portal_* procedures talk to; the input code calls them from other threads.
@(private = "file")
session_mu: sync.Mutex
@(private = "file")
session: rawptr

capture_open_pipewire :: proc(opts: Capture_Options) -> (cap: Capture, err: Capture_Error) {
	reason: [256]u8
	if ody_pw_available(raw_data(reason[:]), len(reason)) == 0 {
		// No session bus or no ScreenCast portal: not worth a message, X11 is tried next.
		utils.log_debug("PipeWire capture unavailable: %s", cstring(raw_data(reason[:])))
		return {}, .Not_Supported
	}

	utils.log_info("asking the desktop for a screen to share (answer its dialog if one appears)")
	fps := opts.fps if opts.fps > 0 else 30
	denied: c.int
	handle := ody_pw_open(
		1 if opts.cursor else 0,
		c.int(fps),
		1 if opts.input else 0,
		PORTAL_TIMEOUT_MS,
		&denied,
		raw_data(reason[:]),
		len(reason),
	)
	if handle == nil {
		// User-visible: this is where "screen sharing was not allowed" ends up.
		utils.log_info("screen capture through the desktop portal failed: %s", cstring(raw_data(reason[:])))
		return {}, .Denied if denied != 0 else .Failed
	}

	w, h: c.int
	ody_pw_size(handle, &w, &h)
	if w <= 0 || h <= 0 {
		ody_pw_close(handle)
		return {}, .Failed
	}

	impl := new(Capture_PW)
	impl.handle = handle
	impl.width = int(w)
	impl.height = int(h)
	impl.formats = {ffmpeg.pix_fmt("bgr0"), ffmpeg.pix_fmt("bgra"), ffmpeg.pix_fmt("rgb0"), ffmpeg.pix_fmt("rgba")}

	sync.mutex_lock(&session_mu)
	session = handle
	sync.mutex_unlock(&session_mu)

	remote := ody_pw_remote_active(handle) != 0
	if opts.input && !remote {
		utils.log_info("the desktop did not grant remote input; the viewer can watch but not control")
	}
	utils.log_debug("PipeWire capture %dx%d, remote input %v", w, h, remote)

	return Capture{
		width      = int(w),
		height     = int(h),
		self_paced = true,
		impl       = impl,
		frame_proc = capture_frame_pipewire,
		close_proc = capture_close_pipewire,
	}, .None
}

@(private = "file")
capture_close_pipewire :: proc(cap: ^Capture) {
	impl := (^Capture_PW)(cap.impl)
	// Take the session away from the input threads before it is destroyed.
	sync.mutex_lock(&session_mu)
	if session == impl.handle {
		session = nil
	}
	sync.mutex_unlock(&session_mu)
	ody_pw_close(impl.handle)
	free(impl)
	cap.impl = nil
}

@(private = "file")
capture_frame_pipewire :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	impl := (^Capture_PW)(cap.impl)

	nf: Native_Frame
	rc := ody_pw_read(impl.handle, 100, &nf)
	if rc < 0 {
		out^ = {}
		if rc == -2 {
			utils.log_info("the desktop ended the screen share")
			return .Denied
		}
		return .Device_Lost // stream failure: reopen the backend
	}
	if rc == 0 {
		out^ = impl.last
		return .Timeout
	}
	if nf.data == nil || nf.format < 0 || int(nf.format) >= len(impl.formats) {
		out^ = {}
		return .Failed
	}
	if int(nf.width) != impl.width || int(nf.height) != impl.height {
		// The monitor or window changed size; the pipeline restarts with the new geometry.
		out^ = {}
		return .Device_Lost
	}

	frame := Frame{
		width        = impl.width,
		height       = impl.height,
		format       = impl.formats[nf.format],
		timestamp_ns = now_ns(),
	}
	frame.planes[0] = nf.data
	frame.strides[0] = i32(nf.stride)
	impl.last = frame
	out^ = frame
	return .None
}

// Remote input through the portal's RemoteDesktop session (Wayland).

// portal_remote_active reports whether a RemoteDesktop portal session is running and accepts input.
portal_remote_active :: proc() -> bool {
	sync.mutex_lock(&session_mu)
	defer sync.mutex_unlock(&session_mu)
	return session != nil && ody_pw_remote_active(session) != 0
}

// Pointer position in pixels of the captured stream.
portal_pointer_motion :: proc(x, y: f64) {
	sync.mutex_lock(&session_mu)
	defer sync.mutex_unlock(&session_mu)
	if session != nil {
		ody_pw_pointer_motion(session, x, y)
	}
}

// Linux evdev button code (BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112, BTN_SIDE = 0x113, BTN_EXTRA = 0x114).
portal_pointer_button :: proc(button: i32, pressed: bool) {
	sync.mutex_lock(&session_mu)
	defer sync.mutex_unlock(&session_mu)
	if session != nil {
		ody_pw_pointer_button(session, c.int(button), 1 if pressed else 0)
	}
}

// Scroll deltas in pixels; positive dy scrolls down.
portal_pointer_axis :: proc(dx, dy: f64) {
	sync.mutex_lock(&session_mu)
	defer sync.mutex_unlock(&session_mu)
	if session != nil {
		ody_pw_pointer_axis(session, dx, dy)
	}
}

// Linux evdev key code (KEY_A = 30, ...).
portal_keyboard_key :: proc(keycode: i32, pressed: bool) {
	sync.mutex_lock(&session_mu)
	defer sync.mutex_unlock(&session_mu)
	if session != nil {
		ody_pw_keyboard_key(session, c.int(keycode), 1 if pressed else 0)
	}
}

} else {

// Keeps the imports above in use without the shim, so -vet stays quiet.
@(private = "file")
_Unused :: struct {
	_: c.int,
	_: sync.Mutex,
	_: ffmpeg.Pixel_Format,
}

capture_open_pipewire :: proc(opts: Capture_Options) -> (cap: Capture, err: Capture_Error) {
	utils.log_debug("this build has no PipeWire support (build with ODYSSEUS_PIPEWIRE=true)")
	return {}, .Not_Supported
}

// Remote input through the portal's RemoteDesktop session (Wayland).

// portal_remote_active reports whether a RemoteDesktop portal session is running and accepts input.
portal_remote_active :: proc() -> bool {
	return false
}

// Pointer position in pixels of the captured stream.
portal_pointer_motion :: proc(x, y: f64) {
}

// Linux evdev button code (BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112, BTN_SIDE = 0x113, BTN_EXTRA = 0x114).
portal_pointer_button :: proc(button: i32, pressed: bool) {
}

// Scroll deltas in pixels; positive dy scrolls down.
portal_pointer_axis :: proc(dx, dy: f64) {
}

// Linux evdev key code (KEY_A = 30, ...).
portal_keyboard_key :: proc(keycode: i32, pressed: bool) {
}

}
