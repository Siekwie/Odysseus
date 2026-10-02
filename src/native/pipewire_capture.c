/* Screen capture through xdg-desktop-portal + PipeWire, and portal remote input.
 *
 * Why C: libpipewire's SPA pod builders and parsers are static inline
 * macros, which Odin cannot call. The shim keeps all of that, plus the GDBus
 * portal handshake, behind the small API in odysseus_native.h.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -c pipewire_capture.c \
 *      $(pkg-config --cflags libpipewire-0.3 gio-2.0 gio-unix-2.0)
 * Link:   $(pkg-config --libs libpipewire-0.3 gio-2.0 gio-unix-2.0)
 * Needs GLib >= 2.66 (g_file_set_contents_full) and PipeWire >= 0.3.
 *
 * Threading: ody_pw_open / ody_pw_read / ody_pw_size / ody_pw_close are called
 * from one thread (the portal's D-Bus signals are dispatched from ody_pw_read).
 * The input calls may come from any thread.
 */

#include "odysseus_native.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib/gstdio.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/utils/result.h>

#define PORTAL_BUS     "org.freedesktop.portal.Desktop"
#define PORTAL_PATH    "/org/freedesktop/portal/desktop"
#define IFACE_SCREENCAST "org.freedesktop.portal.ScreenCast"
#define IFACE_REMOTE   "org.freedesktop.portal.RemoteDesktop"
#define IFACE_REQUEST  "org.freedesktop.portal.Request"
#define IFACE_SESSION  "org.freedesktop.portal.Session"
#define IFACE_PROPS    "org.freedesktop.DBus.Properties"

#define DEVICE_KEYBOARD 1u
#define DEVICE_POINTER  2u

/* Failure kinds that decide whether retrying makes sense. */
enum { FAIL_OTHER = 0, FAIL_DENIED, FAIL_TIMEOUT };

/* ody_pw_frame.format values */
enum { FMT_BGRX = 0, FMT_BGRA = 1, FMT_RGBX = 2, FMT_RGBA = 3 };

typedef struct {
	guint8 *data;
	gsize cap;
	int width, height, stride, format;
	gint64 ts_ns;
} frame_slot;

struct ody_pw {
	/* portal */
	GMainContext *ctx;          /* private: only iterated by the calling thread */
	GDBusConnection *bus;
	char *session;              /* session handle (object path) */
	guint closed_sub;           /* Session.Closed subscription */
	guint32 node_id;
	int portal_w, portal_h;     /* logical stream size from Start, 0 if absent */
	guint32 devices;            /* RemoteDesktop devices actually granted */
	gint session_closed;        /* atomic */
	int fail_kind;
	char err[256];

	/* PipeWire */
	struct pw_thread_loop *loop;
	struct pw_context *context;
	struct pw_core *core;
	struct pw_stream *stream;
	struct spa_hook core_listener;
	struct spa_hook stream_listener;
	int loop_started;
	int core_listening;

	/* shared with the PipeWire thread, guarded by mu */
	GMutex mu;
	GCond cond;
	int fps;
	int format_ready;
	int failed;                 /* stream or core error */
	char stream_err[256];
	int vw, vh, vformat;        /* negotiated video format */
	frame_slot front;           /* last frame handed out */
	frame_slot back;            /* newest frame, written by the PipeWire thread */
	int pending;                /* back holds a frame ody_pw_read has not returned */
	gint64 next_ok_us;          /* earliest monotonic time for the next frame (fps cap) */
};

/* ---- helpers -------------------------------------------------------------- */

static void dbg(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void dbg(const char *fmt, ...)
{
	static int enabled = -1;
	va_list ap;

	if (enabled < 0) {
		enabled = g_getenv("ODYSSEUS_PW_DEBUG") != NULL;
	}
	if (!enabled) {
		return;
	}
	fputs("odysseus-pw: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static void pw_fail(ody_pw *pw, int kind, const char *fmt, ...) G_GNUC_PRINTF(3, 4);
static void pw_fail(ody_pw *pw, int kind, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(pw->err, sizeof(pw->err), fmt, ap);
	va_end(ap);
	pw->fail_kind = kind;
	dbg("failure: %s", pw->err);
}

/* Consumes the error. */
static void fail_gerror(ody_pw *pw, const char *what, GError *error)
{
	if (error != NULL) {
		g_dbus_error_strip_remote_error(error);
		pw_fail(pw, FAIL_OTHER, "%s: %s", what, error->message);
		g_error_free(error);
	} else {
		pw_fail(pw, FAIL_OTHER, "%s failed", what);
	}
}

static void copy_err(char *dst, int len, const char *src)
{
	if (dst != NULL && len > 0) {
		snprintf(dst, (size_t)len, "%s", src);
	}
}

static gint64 now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (gint64)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* "odysseus_<pid>_<n>": a valid object path element, unique per call. */
static void new_token(char *buf, size_t len)
{
	static gint counter = 0;

	snprintf(buf, len, "odysseus_%d_%d", (int)getpid(), g_atomic_int_add(&counter, 1));
}

/* ---- restore token -------------------------------------------------------- */

/* One file per session type: a ScreenCast token is not valid for a RemoteDesktop session. */
static char *token_path(int remote)
{
	return g_build_filename(g_get_user_config_dir(), "odysseus",
		remote ? "portal-restore-token-input" : "portal-restore-token", NULL);
}

static char *load_restore_token(int remote)
{
	char *path = token_path(remote);
	char *data = NULL;
	char *token = NULL;

	if (g_file_get_contents(path, &data, NULL, NULL)) {
		g_strstrip(data);
		if (data[0] != '\0') {
			token = g_strdup(data);
		}
		g_free(data);
	}
	g_free(path);
	return token;
}

static void save_restore_token(int remote, const char *token)
{
	char *path = token_path(remote);
	char *dir = g_path_get_dirname(path);
	GError *error = NULL;

	g_mkdir_with_parents(dir, 0700);
	if (!g_file_set_contents_full(path, token, -1, G_FILE_SET_CONTENTS_CONSISTENT, 0600, &error)) {
		dbg("cannot save the restore token: %s", error->message);
		g_error_free(error);
	}
	g_free(dir);
	g_free(path);
}

static void forget_restore_token(int remote)
{
	char *path = token_path(remote);

	g_unlink(path);
	g_free(path);
}

/* ---- portal requests ------------------------------------------------------ */

typedef struct {
	GMainLoop *loop;
	gboolean done;
	gboolean timed_out;
	guint32 response;
	GVariant *results;
} request_state;

static void request_response_cb(GDBusConnection *conn G_GNUC_UNUSED, const gchar *sender G_GNUC_UNUSED,
	const gchar *path G_GNUC_UNUSED, const gchar *iface G_GNUC_UNUSED, const gchar *name G_GNUC_UNUSED,
	GVariant *parameters, gpointer data)
{
	request_state *rs = data;

	if (rs->done) {
		return;
	}
	g_variant_get(parameters, "(u@a{sv})", &rs->response, &rs->results);
	rs->done = TRUE;
	g_main_loop_quit(rs->loop);
}

static gboolean request_timeout_cb(gpointer data)
{
	request_state *rs = data;

	rs->timed_out = TRUE;
	g_main_loop_quit(rs->loop);
	return G_SOURCE_REMOVE;
}

static void session_closed_cb(GDBusConnection *conn G_GNUC_UNUSED, const gchar *sender G_GNUC_UNUSED,
	const gchar *path G_GNUC_UNUSED, const gchar *iface G_GNUC_UNUSED, const gchar *name G_GNUC_UNUSED,
	GVariant *parameters G_GNUC_UNUSED, gpointer data)
{
	ody_pw *pw = data;

	dbg("portal session closed");
	g_atomic_int_set(&pw->session_closed, 1);
}

/* /org/freedesktop/portal/desktop/request/<sender>/<token>, sender = unique name without ':' and '.' -> '_'. */
static char *request_path(GDBusConnection *bus, const char *token)
{
	const char *unique = g_dbus_connection_get_unique_name(bus);
	char *sender = g_strdup(unique != NULL && unique[0] == ':' ? unique + 1 : (unique != NULL ? unique : ""));
	char *path;
	char *p;

	for (p = sender; *p != '\0'; p++) {
		if (*p == '.') {
			*p = '_';
		}
	}
	path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
	g_free(sender);
	return path;
}

static guint subscribe_request(ody_pw *pw, const char *path, request_state *rs)
{
	return g_dbus_connection_signal_subscribe(pw->bus, PORTAL_BUS, IFACE_REQUEST, "Response", path, NULL,
		G_DBUS_SIGNAL_FLAGS_NONE, request_response_cb, rs, NULL);
}

/* Calls a portal method that answers through a Request, and waits for the
 * Response signal while iterating the private main context. `params` is a
 * floating tuple whose options dict contains handle_token == token. On success
 * (response 0) *results_out receives the results dict (caller unrefs). */
static gboolean portal_request(ody_pw *pw, const char *iface, const char *method, GVariant *params,
	const char *token, gint64 deadline_us, GVariant **results_out)
{
	request_state rs;
	GError *error = NULL;
	GVariant *reply;
	GSource *timeout;
	char *expected;
	const char *handle = NULL;
	guint sub;
	gint64 remaining_ms;
	gboolean ok = FALSE;

	memset(&rs, 0, sizeof(rs));
	remaining_ms = (deadline_us - g_get_monotonic_time()) / 1000;
	if (remaining_ms < 2000) {
		remaining_ms = 2000; /* quick steps still get a fair chance after a slow dialog */
	}

	/* Subscribe before the call: the Response can arrive before the reply does. */
	expected = request_path(pw->bus, token);
	rs.loop = g_main_loop_new(pw->ctx, FALSE);
	sub = subscribe_request(pw, expected, &rs);

	reply = g_dbus_connection_call_sync(pw->bus, PORTAL_BUS, PORTAL_PATH, iface, method, params,
		G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 30000, NULL, &error);
	if (reply == NULL) {
		fail_gerror(pw, method, error);
		goto out;
	}

	/* Portals that predate the handle_token convention answer on another path. */
	g_variant_get(reply, "(&o)", &handle);
	if (g_strcmp0(handle, expected) != 0) {
		dbg("%s: request path differs (%s)", method, handle);
		g_dbus_connection_signal_unsubscribe(pw->bus, sub);
		sub = subscribe_request(pw, handle, &rs);
	}

	timeout = g_timeout_source_new((guint)remaining_ms);
	g_source_set_callback(timeout, request_timeout_cb, &rs, NULL);
	g_source_attach(timeout, pw->ctx);
	if (!rs.done) {
		g_main_loop_run(rs.loop);
	}
	g_source_destroy(timeout);
	g_source_unref(timeout);

	if (!rs.done) {
		pw_fail(pw, FAIL_TIMEOUT, "the desktop did not answer %s in time (is the screen share dialog still open?)", method);
	} else if (rs.response == 0) {
		ok = TRUE;
	} else if (rs.response == 1) {
		pw_fail(pw, FAIL_DENIED, "screen sharing was not allowed (the request was cancelled)");
	} else {
		pw_fail(pw, FAIL_OTHER, "the desktop portal ended %s with an error (response %u)", method, rs.response);
	}

out:
	if (sub != 0) {
		g_dbus_connection_signal_unsubscribe(pw->bus, sub);
	}
	if (reply != NULL) {
		g_variant_unref(reply);
	}
	g_main_loop_unref(rs.loop);
	g_free(expected);
	if (ok && results_out != NULL) {
		*results_out = rs.results;
	} else if (rs.results != NULL) {
		g_variant_unref(rs.results);
	}
	return ok;
}

/* Reads a u32 property of the portal's interface. */
static gboolean get_u32_property(GDBusConnection *bus, const char *iface, const char *name, guint32 *out, GError **error)
{
	GVariant *reply = g_dbus_connection_call_sync(bus, PORTAL_BUS, PORTAL_PATH, IFACE_PROPS, "Get",
		g_variant_new("(ss)", iface, name), G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 10000, NULL, error);
	GVariant *value = NULL;
	gboolean ok = FALSE;

	if (reply == NULL) {
		return FALSE;
	}
	g_variant_get(reply, "(v)", &value);
	if (g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) {
		*out = g_variant_get_uint32(value);
		ok = TRUE;
	}
	g_variant_unref(value);
	g_variant_unref(reply);
	return ok;
}

static void builder_begin(GVariantBuilder *b, const char *token)
{
	g_variant_builder_init(b, G_VARIANT_TYPE_VARDICT);
	g_variant_builder_add(b, "{sv}", "handle_token", g_variant_new_string(token));
}

static void portal_close_session(ody_pw *pw)
{
	if (pw->closed_sub != 0) {
		g_dbus_connection_signal_unsubscribe(pw->bus, pw->closed_sub);
		pw->closed_sub = 0;
	}
	if (pw->session != NULL) {
		GVariant *reply = g_dbus_connection_call_sync(pw->bus, PORTAL_BUS, pw->session, IFACE_SESSION, "Close",
			NULL, NULL, G_DBUS_CALL_FLAGS_NONE, 2000, NULL, NULL);

		if (reply != NULL) {
			g_variant_unref(reply);
		}
		g_free(pw->session);
		pw->session = NULL;
	}
}

/* One full handshake. On success pw->session / node_id / devices are set and
 * *fd_out is the PipeWire remote socket. On failure the session may be left
 * open; the caller closes it. */
static gboolean portal_start(ody_pw *pw, int cursor, int remote, const char *restore_token,
	gint64 deadline_us, int *fd_out)
{
	const char *iface = remote ? IFACE_REMOTE : IFACE_SCREENCAST;
	guint32 sc_version = 0, rd_version = 0, cursor_modes = 0, device_types = 0, cursor_mode;
	char token[64], session_token[64];
	GVariantBuilder b;
	GVariant *results = NULL;
	GVariant *v;
	GError *error = NULL;
	GUnixFDList *fds = NULL;
	GVariant *reply;
	gint idx = -1;
	int fd;

	if (!get_u32_property(pw->bus, IFACE_SCREENCAST, "version", &sc_version, &error)) {
		fail_gerror(pw, "the desktop portal has no ScreenCast interface", error);
		return FALSE;
	}
	if (!get_u32_property(pw->bus, IFACE_SCREENCAST, "AvailableCursorModes", &cursor_modes, &error)) {
		cursor_modes = 0; /* unknown: send the preferred mode and let the portal validate it */
		g_clear_error(&error);
	}
	if (remote) {
		if (!get_u32_property(pw->bus, IFACE_REMOTE, "AvailableDeviceTypes", &device_types, &error)) {
			fail_gerror(pw, "the desktop portal has no RemoteDesktop interface", error);
			return FALSE;
		}
		if ((device_types & (DEVICE_KEYBOARD | DEVICE_POINTER)) == 0) {
			pw_fail(pw, FAIL_OTHER, "the desktop portal offers no remote keyboard or pointer");
			return FALSE;
		}
		if (!get_u32_property(pw->bus, IFACE_REMOTE, "version", &rd_version, &error)) {
			rd_version = 1;
			g_clear_error(&error);
		}
	}
	dbg("portal: ScreenCast v%u, cursor modes 0x%x, remote %d (RemoteDesktop v%u, devices 0x%x)",
		sc_version, cursor_modes, remote, rd_version, device_types);

	/* 1. CreateSession */
	new_token(token, sizeof(token));
	new_token(session_token, sizeof(session_token));
	builder_begin(&b, token);
	g_variant_builder_add(&b, "{sv}", "session_handle_token", g_variant_new_string(session_token));
	if (!portal_request(pw, iface, "CreateSession", g_variant_new("(a{sv})", &b), token, deadline_us, &results)) {
		return FALSE;
	}
	v = g_variant_lookup_value(results, "session_handle", NULL);
	if (v != NULL && (g_variant_is_of_type(v, G_VARIANT_TYPE_STRING) || g_variant_is_of_type(v, G_VARIANT_TYPE_OBJECT_PATH))) {
		pw->session = g_strdup(g_variant_get_string(v, NULL));
	}
	if (v != NULL) {
		g_variant_unref(v);
	}
	g_variant_unref(results);
	results = NULL;
	if (pw->session == NULL) {
		pw_fail(pw, FAIL_OTHER, "the portal did not return a session handle");
		return FALSE;
	}
	dbg("session %s", pw->session);

	/* 2. SelectDevices (RemoteDesktop). Its restore token covers the screen cast too. */
	if (remote) {
		new_token(token, sizeof(token));
		builder_begin(&b, token);
		g_variant_builder_add(&b, "{sv}", "types", g_variant_new_uint32(DEVICE_KEYBOARD | DEVICE_POINTER));
		if (rd_version >= 2) {
			g_variant_builder_add(&b, "{sv}", "persist_mode", g_variant_new_uint32(2));
			if (restore_token != NULL) {
				g_variant_builder_add(&b, "{sv}", "restore_token", g_variant_new_string(restore_token));
			}
		}
		if (!portal_request(pw, IFACE_REMOTE, "SelectDevices", g_variant_new("(oa{sv})", pw->session, &b),
			token, deadline_us, NULL)) {
			return FALSE;
		}
	}

	/* 3. SelectSources */
	cursor_mode = cursor ? 2u : 1u; /* embedded / hidden */
	if (cursor_modes != 0 && (cursor_modes & cursor_mode) == 0) {
		guint32 other = cursor ? 1u : 2u;

		cursor_mode = (cursor_modes & other) != 0 ? other : 0;
	}
	new_token(token, sizeof(token));
	builder_begin(&b, token);
	g_variant_builder_add(&b, "{sv}", "types", g_variant_new_uint32(1)); /* monitor */
	g_variant_builder_add(&b, "{sv}", "multiple", g_variant_new_boolean(FALSE));
	if (cursor_mode != 0) {
		g_variant_builder_add(&b, "{sv}", "cursor_mode", g_variant_new_uint32(cursor_mode));
	}
	if (!remote && sc_version >= 4) {
		g_variant_builder_add(&b, "{sv}", "persist_mode", g_variant_new_uint32(2));
		if (restore_token != NULL) {
			g_variant_builder_add(&b, "{sv}", "restore_token", g_variant_new_string(restore_token));
		}
	}
	if (!portal_request(pw, IFACE_SCREENCAST, "SelectSources", g_variant_new("(oa{sv})", pw->session, &b),
		token, deadline_us, NULL)) {
		return FALSE;
	}

	/* 4. Start: the desktop shows its dialog here (unless a restore token is accepted). */
	new_token(token, sizeof(token));
	builder_begin(&b, token);
	if (!portal_request(pw, iface, "Start", g_variant_new("(osa{sv})", pw->session, "", &b), token, deadline_us, &results)) {
		return FALSE;
	}
	v = g_variant_lookup_value(results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
	if (v != NULL && g_variant_n_children(v) > 0) {
		GVariant *stream = g_variant_get_child_value(v, 0);
		GVariant *props = NULL;
		gint w = 0, h = 0;

		g_variant_get(stream, "(u@a{sv})", &pw->node_id, &props);
		if (g_variant_lookup(props, "size", "(ii)", &w, &h)) {
			pw->portal_w = w;
			pw->portal_h = h;
		}
		g_variant_unref(props);
		g_variant_unref(stream);
	}
	if (v != NULL) {
		g_variant_unref(v);
	}
	if (pw->node_id == 0) {
		pw_fail(pw, FAIL_OTHER, "the portal returned no screen to capture");
		g_variant_unref(results);
		return FALSE;
	}
	if (remote) {
		guint32 granted = 0;

		if (!g_variant_lookup(results, "devices", "u", &granted)) {
			granted = DEVICE_KEYBOARD | DEVICE_POINTER; /* not reported: assume what we asked for */
		}
		pw->devices = granted & (DEVICE_KEYBOARD | DEVICE_POINTER);
	}
	{
		const char *new_restore = NULL;

		if (g_variant_lookup(results, "restore_token", "&s", &new_restore) && new_restore != NULL && new_restore[0] != '\0') {
			save_restore_token(remote, new_restore);
		}
	}
	g_variant_unref(results);
	results = NULL;
	dbg("stream node %u, portal size %dx%d, devices 0x%x", pw->node_id, pw->portal_w, pw->portal_h, pw->devices);

	/* 5. OpenPipeWireRemote */
	g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
	reply = g_dbus_connection_call_with_unix_fd_list_sync(pw->bus, PORTAL_BUS, PORTAL_PATH, IFACE_SCREENCAST,
		"OpenPipeWireRemote", g_variant_new("(oa{sv})", pw->session, &b), G_VARIANT_TYPE("(h)"),
		G_DBUS_CALL_FLAGS_NONE, 10000, NULL, &fds, NULL, &error);
	if (reply == NULL) {
		fail_gerror(pw, "OpenPipeWireRemote", error);
		return FALSE;
	}
	g_variant_get(reply, "(h)", &idx);
	fd = g_unix_fd_list_get(fds, idx, &error);
	g_variant_unref(reply);
	g_object_unref(fds);
	if (fd < 0) {
		fail_gerror(pw, "OpenPipeWireRemote returned no socket", error);
		return FALSE;
	}
	*fd_out = fd;

	/* The user can end the share from the desktop; ody_pw_read notices through this. */
	pw->closed_sub = g_dbus_connection_signal_subscribe(pw->bus, PORTAL_BUS, IFACE_SESSION, "Closed", pw->session,
		NULL, G_DBUS_SIGNAL_FLAGS_NONE, session_closed_cb, pw, NULL);
	return TRUE;
}

/* ---- PipeWire stream ------------------------------------------------------ */

static void store_buffer(ody_pw *pw, struct spa_buffer *buf)
{
	const struct spa_data *d;
	frame_slot *s;
	const guint8 *src;
	gsize row, stride, offset, needed, total;
	int w, h, fmt, y;

	if (buf->n_datas < 1) {
		return;
	}
	d = &buf->datas[0];
	/* data == NULL: a DMA-BUF we cannot map (the Buffers param excludes them, but be safe).
	 * size == 0 / CORRUPTED: cursor-only or damaged update, nothing to show. */
	if (d->data == NULL || d->chunk == NULL || d->chunk->size == 0 || (d->chunk->flags & SPA_CHUNK_FLAG_CORRUPTED)) {
		return;
	}

	g_mutex_lock(&pw->mu);
	w = pw->vw;
	h = pw->vh;
	fmt = pw->vformat;
	if (w <= 0 || h <= 0) {
		g_mutex_unlock(&pw->mu);
		return;
	}
	row = (gsize)w * 4;
	stride = d->chunk->stride > 0 ? (gsize)d->chunk->stride : row;
	offset = d->chunk->offset;
	needed = stride * (gsize)(h - 1) + row;
	if (stride < row || offset > d->maxsize || needed > d->maxsize - offset) {
		g_mutex_unlock(&pw->mu);
		return;
	}

	/* The reader only touches `front`, so writing `back` under the mutex is enough. */
	s = &pw->back;
	total = row * (gsize)h;
	if (s->cap < total) {
		s->data = g_realloc(s->data, total);
		s->cap = total;
	}
	src = (const guint8 *)d->data + offset;
	if (stride == row) {
		memcpy(s->data, src, total);
	} else {
		for (y = 0; y < h; y++) {
			memcpy(s->data + (gsize)y * row, src + (gsize)y * stride, row);
		}
	}
	s->width = w;
	s->height = h;
	s->stride = (int)row;
	s->format = fmt;
	s->ts_ns = now_ns();
	pw->pending = 1;
	g_cond_broadcast(&pw->cond);
	g_mutex_unlock(&pw->mu);
}

static void on_process(void *data)
{
	ody_pw *pw = data;
	struct pw_buffer *b = NULL;
	struct pw_buffer *next;

	/* Keep only the newest buffer; hand the older ones straight back. */
	while ((next = pw_stream_dequeue_buffer(pw->stream)) != NULL) {
		if (b != NULL) {
			pw_stream_queue_buffer(pw->stream, b);
		}
		b = next;
	}
	if (b == NULL) {
		return;
	}
	store_buffer(pw, b->buffer);
	pw_stream_queue_buffer(pw->stream, b);
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
	ody_pw *pw = data;
	struct spa_video_info_raw raw;
	uint32_t media_type, media_subtype;
	uint8_t buffer[512];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	const struct spa_pod *params[1];
	int fmt;

	if (param == NULL || id != SPA_PARAM_Format) {
		return;
	}
	if (spa_format_parse(param, &media_type, &media_subtype) < 0 ||
		media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw) {
		return;
	}
	memset(&raw, 0, sizeof(raw));
	if (spa_format_video_raw_parse(param, &raw) < 0) {
		return;
	}
	switch (raw.format) {
	case SPA_VIDEO_FORMAT_BGRx: fmt = FMT_BGRX; break;
	case SPA_VIDEO_FORMAT_BGRA: fmt = FMT_BGRA; break;
	case SPA_VIDEO_FORMAT_RGBx: fmt = FMT_RGBX; break;
	case SPA_VIDEO_FORMAT_RGBA: fmt = FMT_RGBA; break;
	default:
		g_mutex_lock(&pw->mu);
		snprintf(pw->stream_err, sizeof(pw->stream_err), "unsupported pixel format %u", (unsigned)raw.format);
		pw->failed = 1;
		g_cond_broadcast(&pw->cond);
		g_mutex_unlock(&pw->mu);
		return;
	}

	g_mutex_lock(&pw->mu);
	pw->vw = (int)raw.size.width;
	pw->vh = (int)raw.size.height;
	pw->vformat = fmt;
	pw->format_ready = 1;
	g_cond_broadcast(&pw->cond);
	g_mutex_unlock(&pw->mu);
	dbg("stream format %dx%d format %d", (int)raw.size.width, (int)raw.size.height, fmt);

	/* Shared memory only: no DMA-BUF, so the buffers can be mapped and copied. */
	params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
		SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(8, 2, 16),
		SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
		SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
	pw_stream_update_params(pw->stream, params, 1);
}

static void on_state_changed(void *data, enum pw_stream_state old G_GNUC_UNUSED, enum pw_stream_state state,
	const char *error)
{
	ody_pw *pw = data;

	dbg("stream state %s%s%s", pw_stream_state_as_string(state), error != NULL ? ": " : "", error != NULL ? error : "");
	if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
		g_mutex_lock(&pw->mu);
		snprintf(pw->stream_err, sizeof(pw->stream_err), "%s",
			error != NULL ? error : (state == PW_STREAM_STATE_ERROR ? "stream error" : "stream disconnected"));
		pw->failed = 1;
		g_cond_broadcast(&pw->cond);
		g_mutex_unlock(&pw->mu);
	}
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
	.param_changed = on_param_changed,
	.process = on_process,
};

static void on_core_error(void *data, uint32_t id, int seq G_GNUC_UNUSED, int res, const char *message)
{
	ody_pw *pw = data;

	dbg("core error id %u: %s (%d)", id, message != NULL ? message : "", res);
	/* A broken connection to the PipeWire daemon is fatal; errors on single objects are reported by their own events. */
	if (id == PW_ID_CORE && (res == -EPIPE || res == -ECONNRESET)) {
		g_mutex_lock(&pw->mu);
		snprintf(pw->stream_err, sizeof(pw->stream_err), "lost the connection to PipeWire");
		pw->failed = 1;
		g_cond_broadcast(&pw->cond);
		g_mutex_unlock(&pw->mu);
	}
}

static const struct pw_core_events core_events = {
	PW_VERSION_CORE_EVENTS,
	.error = on_core_error,
};

static void pw_init_once(void)
{
	static gsize once = 0;

	if (g_once_init_enter(&once)) {
		pw_init(NULL, NULL);
		g_once_init_leave(&once, 1);
	}
}

/* Builds the EnumFormat param: the four 32-bit formats, any size, up to `fps`. */
static const struct spa_pod *build_enum_format(struct spa_pod_builder *b, int fps)
{
	static const uint32_t formats[] = { SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA };
	struct spa_pod_frame frames[2];
	size_t i;

	spa_pod_builder_push_object(b, &frames[0], SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
	spa_pod_builder_add(b,
		SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
		SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
		0);
	spa_pod_builder_prop(b, SPA_FORMAT_VIDEO_format, 0);
	spa_pod_builder_push_choice(b, &frames[1], SPA_CHOICE_Enum, 0);
	spa_pod_builder_id(b, formats[0]); /* the first value is the default */
	for (i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
		spa_pod_builder_id(b, formats[i]);
	}
	spa_pod_builder_pop(b, &frames[1]);
	spa_pod_builder_add(b,
		SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(
			&SPA_RECTANGLE(1920, 1080), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(16384, 16384)),
		SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(
			&SPA_FRACTION((uint32_t)fps, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION((uint32_t)fps, 1)),
		0);
	return spa_pod_builder_pop(b, &frames[0]);
}

/* Connects to the portal's PipeWire socket and starts the stream. Takes ownership of fd. */
static gboolean pw_connect(ody_pw *pw, int fd, int fps)
{
	uint8_t buffer[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	const struct spa_pod *params[1];
	int pwfd, res;

	pw_init_once();

	pw->loop = pw_thread_loop_new("odysseus-pipewire", NULL);
	if (pw->loop == NULL) {
		pw_fail(pw, FAIL_OTHER, "cannot create the PipeWire loop");
		close(fd);
		return FALSE;
	}
	pw->context = pw_context_new(pw_thread_loop_get_loop(pw->loop), NULL, 0);
	if (pw->context == NULL) {
		pw_fail(pw, FAIL_OTHER, "cannot create the PipeWire context");
		close(fd);
		return FALSE;
	}
	if (pw_thread_loop_start(pw->loop) < 0) {
		pw_fail(pw, FAIL_OTHER, "cannot start the PipeWire loop");
		close(fd);
		return FALSE;
	}
	pw->loop_started = 1;

	pw_thread_loop_lock(pw->loop);
	pwfd = fcntl(fd, F_DUPFD_CLOEXEC, 3);
	close(fd);
	if (pwfd < 0) {
		pw_thread_loop_unlock(pw->loop);
		pw_fail(pw, FAIL_OTHER, "cannot duplicate the PipeWire socket: %s", strerror(errno));
		return FALSE;
	}
	pw->core = pw_context_connect_fd(pw->context, pwfd, NULL, 0); /* owns pwfd from here on */
	if (pw->core == NULL) {
		int e = errno;

		close(pwfd);
		pw_thread_loop_unlock(pw->loop);
		pw_fail(pw, FAIL_OTHER, "cannot connect to PipeWire: %s", strerror(e));
		return FALSE;
	}
	pw_core_add_listener(pw->core, &pw->core_listener, &core_events, pw);
	pw->core_listening = 1;

	pw->stream = pw_stream_new(pw->core, "Odysseus screen capture",
		pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Screen", NULL));
	if (pw->stream == NULL) {
		pw_thread_loop_unlock(pw->loop);
		pw_fail(pw, FAIL_OTHER, "cannot create the PipeWire stream");
		return FALSE;
	}
	pw_stream_add_listener(pw->stream, &pw->stream_listener, &stream_events, pw);

	params[0] = build_enum_format(&b, fps);
	res = pw_stream_connect(pw->stream, PW_DIRECTION_INPUT, pw->node_id,
		PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
	pw_thread_loop_unlock(pw->loop);
	if (res < 0) {
		pw_fail(pw, FAIL_OTHER, "cannot connect the PipeWire stream: %s", spa_strerror(res));
		return FALSE;
	}
	return TRUE;
}

/* Waits for the first format negotiation. */
static gboolean wait_for_format(ody_pw *pw, int timeout_ms)
{
	gint64 end = g_get_monotonic_time() + (gint64)timeout_ms * 1000;
	gboolean ok;

	g_mutex_lock(&pw->mu);
	while (!pw->format_ready && !pw->failed) {
		if (!g_cond_wait_until(&pw->cond, &pw->mu, end)) {
			break;
		}
	}
	ok = pw->format_ready && !pw->failed;
	if (!ok) {
		pw_fail(pw, FAIL_OTHER, "PipeWire stream did not start: %s",
			pw->failed ? pw->stream_err : "no video format was negotiated in time");
	}
	g_mutex_unlock(&pw->mu);
	return ok;
}

/* ---- public API ----------------------------------------------------------- */

int ody_pw_available(char *err, int err_len)
{
	GError *error = NULL;
	GDBusConnection *bus;
	guint32 version = 0;
	int ok;

	bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
	if (bus == NULL) {
		char msg[256];

		snprintf(msg, sizeof(msg), "no D-Bus session bus: %s", error->message);
		copy_err(err, err_len, msg);
		g_error_free(error);
		return 0;
	}
	ok = get_u32_property(bus, IFACE_SCREENCAST, "version", &version, &error);
	if (!ok) {
		char msg[256];

		snprintf(msg, sizeof(msg), "no ScreenCast portal: %s", error != NULL ? error->message : "bad version property");
		copy_err(err, err_len, msg);
		g_clear_error(&error);
	}
	g_object_unref(bus);
	return ok;
}

static void pw_destroy(ody_pw *pw)
{
	if (pw->loop != NULL) {
		if (pw->loop_started) {
			pw_thread_loop_lock(pw->loop);
		}
		if (pw->stream != NULL) {
			pw_stream_destroy(pw->stream);
			pw->stream = NULL;
		}
		if (pw->core != NULL) {
			if (pw->core_listening) {
				spa_hook_remove(&pw->core_listener);
				pw->core_listening = 0;
			}
			pw_core_disconnect(pw->core);
			pw->core = NULL;
		}
		if (pw->loop_started) {
			pw_thread_loop_unlock(pw->loop);
			pw_thread_loop_stop(pw->loop);
		}
		if (pw->context != NULL) {
			pw_context_destroy(pw->context);
			pw->context = NULL;
		}
		pw_thread_loop_destroy(pw->loop);
		pw->loop = NULL;
	}

	if (pw->bus != NULL) {
		portal_close_session(pw);
		g_object_unref(pw->bus);
		pw->bus = NULL;
	}
	if (pw->ctx != NULL) {
		g_main_context_unref(pw->ctx);
		pw->ctx = NULL;
	}
	g_free(pw->front.data);
	g_free(pw->back.data);
	g_mutex_clear(&pw->mu);
	g_cond_clear(&pw->cond);
	g_free(pw);
}

ody_pw *ody_pw_open(int cursor, int fps, int remote_input, int timeout_ms, int *denied, char *err, int err_len)
{
	ody_pw *pw;
	GError *error = NULL;
	gint64 deadline_us;
	gboolean remote = remote_input != 0;
	gboolean ok = FALSE;
	int fd = -1;

	if (err != NULL && err_len > 0) {
		err[0] = '\0';
	}
	if (denied != NULL) {
		*denied = 0;
	}
	if (fps <= 0) {
		fps = 30;
	}
	if (timeout_ms <= 0) {
		timeout_ms = 60000;
	}

	pw = g_new0(ody_pw, 1);
	g_mutex_init(&pw->mu);
	g_cond_init(&pw->cond);
	pw->fps = fps;
	pw->ctx = g_main_context_new();
	pw->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
	if (pw->bus == NULL) {
		fail_gerror(pw, "cannot reach the D-Bus session bus", error);
		goto fail;
	}

	deadline_us = g_get_monotonic_time() + (gint64)timeout_ms * 1000;

	/* Signal subscriptions made here are dispatched in the private context. */
	g_main_context_push_thread_default(pw->ctx);
	for (;;) {
		char *token = load_restore_token(remote);
		gboolean had_token = token != NULL;

		ok = portal_start(pw, cursor, remote, token, deadline_us, &fd);
		g_free(token);
		if (ok) {
			break;
		}
		portal_close_session(pw);
		pw->node_id = 0;
		pw->portal_w = pw->portal_h = 0;
		pw->devices = 0;
		if (pw->fail_kind != FAIL_OTHER) {
			break; /* denied or timed out: asking again would only nag the user */
		}
		if (had_token) {
			dbg("retrying without the saved restore token");
			forget_restore_token(remote); /* stale or from another setup */
		} else if (remote) {
			dbg("RemoteDesktop failed, falling back to a plain screen cast");
			remote = FALSE;
		} else {
			break;
		}
	}
	g_main_context_pop_thread_default(pw->ctx);
	if (!ok) {
		goto fail;
	}

	if (!pw_connect(pw, fd, fps) || !wait_for_format(pw, 10000)) {
		goto fail;
	}
	return pw;

fail:
	copy_err(err, err_len, pw->err[0] != '\0' ? pw->err : "unknown error");
	if (denied != NULL) {
		*denied = pw->fail_kind == FAIL_DENIED;
	}
	pw_destroy(pw);
	return NULL;
}

void ody_pw_size(ody_pw *pw, int *width, int *height)
{
	int w = 0, h = 0;

	if (pw != NULL) {
		g_mutex_lock(&pw->mu);
		w = pw->vw;
		h = pw->vh;
		g_mutex_unlock(&pw->mu);
	}
	if (width != NULL) {
		*width = w;
	}
	if (height != NULL) {
		*height = h;
	}
}

int ody_pw_read(ody_pw *pw, int timeout_ms, ody_pw_frame *out)
{
	gint64 deadline;
	int rc = 0;

	if (pw == NULL || out == NULL) {
		return -1;
	}

	/* Dispatch the portal's pending signals (Session.Closed). */
	while (g_main_context_iteration(pw->ctx, FALSE)) {
	}
	if (g_atomic_int_get(&pw->session_closed)) {
		/* The user ended the share: it must not come back silently next time. */
		forget_restore_token(0);
		forget_restore_token(1);
		return -2;
	}

	deadline = g_get_monotonic_time() + (gint64)(timeout_ms > 0 ? timeout_ms : 0) * 1000;
	g_mutex_lock(&pw->mu);
	for (;;) {
		gint64 now = g_get_monotonic_time();
		gint64 until = deadline;

		if (pw->failed) {
			rc = -1;
			break;
		}
		if (pw->pending && now >= pw->next_ok_us) {
			frame_slot tmp = pw->front;

			/* The slot handed out last time becomes the next write target. */
			pw->front = pw->back;
			pw->back = tmp;
			pw->pending = 0;
			pw->next_ok_us = now + (pw->fps > 0 ? (G_USEC_PER_SEC / pw->fps) * 9 / 10 : 0);
			out->width = pw->front.width;
			out->height = pw->front.height;
			out->stride = pw->front.stride;
			out->format = pw->front.format;
			out->data = pw->front.data;
			out->timestamp_ns = pw->front.ts_ns;
			rc = 1;
			break;
		}
		if (now >= deadline) {
			break;
		}
		if (pw->pending && pw->next_ok_us < until) {
			until = pw->next_ok_us; /* a frame is waiting; only the fps cap holds it back */
		}
		g_cond_wait_until(&pw->cond, &pw->mu, until);
	}
	g_mutex_unlock(&pw->mu);
	return rc;
}

void ody_pw_close(ody_pw *pw)
{
	if (pw != NULL) {
		pw_destroy(pw);
	}
}

/* ---- remote input --------------------------------------------------------- */

int ody_pw_remote_active(ody_pw *pw)
{
	return pw != NULL && pw->devices != 0 && pw->session != NULL && !g_atomic_int_get(&pw->session_closed);
}

/* Fire-and-forget: the portal's empty replies are not interesting. */
static void notify(ody_pw *pw, const char *method, GVariant *params)
{
	g_dbus_connection_call(pw->bus, PORTAL_BUS, PORTAL_PATH, IFACE_REMOTE, method, params, NULL,
		G_DBUS_CALL_FLAGS_NO_AUTO_START, -1, NULL, NULL, NULL);
}

void ody_pw_pointer_motion(ody_pw *pw, double x, double y)
{
	GVariantBuilder opts;
	int vw, vh;

	if (!ody_pw_remote_active(pw) || (pw->devices & DEVICE_POINTER) == 0) {
		return;
	}
	/* The portal wants the stream's logical coordinates, which differ from the
	 * buffer's pixels on scaled outputs. */
	g_mutex_lock(&pw->mu);
	vw = pw->vw;
	vh = pw->vh;
	g_mutex_unlock(&pw->mu);
	if (pw->portal_w > 0 && vw > 0 && pw->portal_w != vw) {
		x = x * pw->portal_w / vw;
	}
	if (pw->portal_h > 0 && vh > 0 && pw->portal_h != vh) {
		y = y * pw->portal_h / vh;
	}
	g_variant_builder_init(&opts, G_VARIANT_TYPE_VARDICT);
	notify(pw, "NotifyPointerMotionAbsolute", g_variant_new("(oa{sv}udd)", pw->session, &opts, pw->node_id, x, y));
}

void ody_pw_pointer_button(ody_pw *pw, int evdev_button, int pressed)
{
	GVariantBuilder opts;

	if (!ody_pw_remote_active(pw) || (pw->devices & DEVICE_POINTER) == 0) {
		return;
	}
	g_variant_builder_init(&opts, G_VARIANT_TYPE_VARDICT);
	notify(pw, "NotifyPointerButton",
		g_variant_new("(oa{sv}iu)", pw->session, &opts, (gint32)evdev_button, (guint32)(pressed ? 1 : 0)));
}

void ody_pw_pointer_axis(ody_pw *pw, double dx, double dy)
{
	GVariantBuilder opts;

	if (!ody_pw_remote_active(pw) || (pw->devices & DEVICE_POINTER) == 0) {
		return;
	}
	g_variant_builder_init(&opts, G_VARIANT_TYPE_VARDICT);
	notify(pw, "NotifyPointerAxis", g_variant_new("(oa{sv}dd)", pw->session, &opts, dx, dy));
}

void ody_pw_keyboard_key(ody_pw *pw, int evdev_keycode, int pressed)
{
	GVariantBuilder opts;

	if (!ody_pw_remote_active(pw) || (pw->devices & DEVICE_KEYBOARD) == 0) {
		return;
	}
	g_variant_builder_init(&opts, G_VARIANT_TYPE_VARDICT);
	notify(pw, "NotifyKeyboardKeycode",
		g_variant_new("(oa{sv}iu)", pw->session, &opts, (gint32)evdev_keycode, (guint32)(pressed ? 1 : 0)));
}
