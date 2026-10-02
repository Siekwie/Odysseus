// Odysseus viewer.
//
// Flow: open /signal, wait for "hello", authenticate if asked, then offer a
// recvonly WebRTC session (video, plus audio when the host has it). Everything
// else (stats, monitor switch, remote control) hangs off that connection.
(() => {
  "use strict";

  const IDLE_MS = 3000; // overlay auto-hide
  const BACKOFF_MIN_MS = 1000;
  const BACKOFF_MAX_MS = 8000;
  const DISCONNECT_GRACE_MS = 4000; // ICE "disconnected" often heals by itself
  const STATS_MS = 1000;
  const NOTICE_MS = 4000;
  const LONG_PRESS_MS = 450;
  const TAP_SLOP_PX = 10;
  const LINE_PX = 100 / 3; // Firefox reports 3 lines per wheel notch; Chrome 100 px
  const signalUrl = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/signal`;

  const $ = (id) => document.getElementById(id);
  const el = {
    video: $("stream"),
    stage: $("stage"),
    status: $("status"),
    dots: [$("dot"), $("handle-dot"), $("panel-dot")],
    panelStatus: $("panel-status"),
    stats: $("stats"),
    settingsBtn: $("settings-btn"),
    settings: $("settings"),
    dock: $("dock"),
    monitorRow: $("monitor-row"),
    monitor: $("monitor"),
    optOverlay: $("opt-overlay"),
    optStats: $("opt-stats"),
    optControl: $("opt-control"),
    controlRow: $("control-row"),
    controlPill: $("control-pill"),
    btnFs: $("btn-fs"),
    fsIcon: $("fs-icon"),
    fsLabel: $("fs-label"),
    btnAudio: $("btn-audio"),
    audioIcon: $("audio-icon"),
    audioLabel: $("audio-label"),
    unmute: $("unmute"),
    auth: $("auth"),
    authForm: $("auth-form"),
    authTitle: $("auth-title"),
    authHint: $("auth-hint"),
    authLabel: $("auth-label"),
    authInput: $("auth-input"),
    authError: $("auth-error"),
    authCancel: $("auth-cancel"),
    authSubmit: $("auth-submit"),
  };

  // ---- storage (can throw or be empty in private windows; never required) ----

  const makeStore = (area) => ({
    get(key) {
      try {
        return area().getItem(`odysseus.${key}`);
      } catch {
        return null;
      }
    },
    set(key, value) {
      try {
        if (value == null) area().removeItem(`odysseus.${key}`);
        else area().setItem(`odysseus.${key}`, value);
      } catch {
        /* ignore */
      }
    },
  });
  const local = makeStore(() => localStorage); // preferences
  const session = makeStore(() => sessionStorage); // tab-lifetime: secrets, mute

  // ---- state ----

  const state = {
    ws: null,
    pc: null,
    hello: null, // latest hello
    host: null, // latest "state" message
    monitor: null,
    mediaStream: null,
    fatal: false,
    streaming: false,
    status: { text: "Connecting…", tone: "idle" },
    notice: null,
    noticeTimer: 0,
    retryMs: BACKOFF_MIN_MS,
    retryTimer: 0,
    retryAt: 0,
    graceTimer: 0,
    remoteSet: false,
    pendingIce: [],
    statsTimer: 0,
    prev: null, // previous getStats sample, for deltas
    prefs: {
      overlay: local.get("overlay") !== "0",
      stats: local.get("stats") !== "0",
    },
    awake: true,
    idleTimer: 0,
    settingsOpen: false,
    muted: true,
    controlOn: false,
    wantControl: false, // user asked for control, waiting for a PIN
    auth: { open: null, sent: null, value: null, tried: { password: false, pin: false } },
  };

  // ---- status ----

  function setStatus(text, tone = "idle") {
    state.status = { text, tone };
    renderStatus();
  }

  // A notice replaces the status line briefly (e.g. a refused request).
  function notify(text, tone = "warn") {
    state.notice = { text, tone };
    clearTimeout(state.noticeTimer);
    state.noticeTimer = setTimeout(() => {
      state.notice = null;
      renderStatus();
    }, NOTICE_MS);
    renderStatus();
  }

  function renderStatus() {
    const s = state.notice || state.status;
    el.status.textContent = s.text;
    el.panelStatus.textContent = s.text;
    for (const d of el.dots) d.dataset.tone = s.tone;
  }

  // ---- overlay visibility ----

  function wake() {
    state.awake = true;
    clearTimeout(state.idleTimer);
    state.idleTimer = setTimeout(sleep, IDLE_MS);
    applyUi();
  }

  function sleep() {
    // Keep the chrome while it is in use.
    if (state.settingsOpen || el.dock.querySelector(":hover, :focus-visible") || el.settings.matches(":hover")) {
      state.idleTimer = setTimeout(sleep, IDLE_MS);
      return;
    }
    state.awake = false;
    applyUi();
  }

  function applyUi() {
    const body = document.body;
    body.classList.toggle("overlay-on", state.prefs.overlay);
    body.classList.toggle("ui-visible", state.awake || !state.streaming || state.settingsOpen);
    body.classList.toggle("controlling", controlActive());
    // The host draws its own cursor into the stream; two cursors would only confuse.
    body.classList.toggle("host-cursor", controlActive() && !!(state.hello && state.hello.cursor));
    el.stats.hidden = !state.prefs.stats;
    el.optOverlay.checked = state.prefs.overlay;
    el.optStats.checked = state.prefs.stats;
    el.optControl.checked = state.controlOn || state.wantControl;
    el.controlRow.hidden = !(state.hello && state.hello.input);
    el.controlPill.hidden = !controlActive();
    el.settingsBtn.setAttribute("aria-expanded", String(state.settingsOpen));
    el.settings.hidden = !state.settingsOpen;
    renderAudio();
    renderFullscreen();
    syncKeyboardLock();
  }

  function setPref(name, on) {
    state.prefs[name] = on;
    local.set(name, on ? "1" : "0");
    applyUi();
  }

  // ---- settings panel ----

  function openSettings() {
    state.settingsOpen = true;
    releaseInput();
    wake();
    const first = el.settings.querySelector("select:not([hidden]), input, button");
    (first || el.settings).focus();
  }

  function closeSettings(refocus = true) {
    if (!state.settingsOpen) return;
    state.settingsOpen = false;
    applyUi();
    if (refocus) el.settingsBtn.focus();
  }

  const toggleSettings = () => (state.settingsOpen ? closeSettings() : openSettings());

  function renderMonitors() {
    const list = (state.hello && state.hello.monitors) || [];
    el.monitorRow.hidden = list.length < 2;
    const signature = list.map((m) => `${m.index}|${m.name}|${m.width}x${m.height}|${m.primary}`).join(";");
    if (el.monitor.dataset.sig !== signature) {
      el.monitor.dataset.sig = signature;
      el.monitor.replaceChildren(
        ...list.map((m) => {
          const o = document.createElement("option");
          o.value = String(m.index);
          const parts = [String(m.index + 1)];
          if (m.name) parts.push(m.name);
          parts.push(`${m.width}×${m.height}${m.primary ? " (primary)" : ""}`);
          o.textContent = parts.join(" · ");
          return o;
        }),
      );
    }
    if (state.monitor != null) el.monitor.value = String(state.monitor);
  }

  // ---- fullscreen ----

  const fullscreenElement = () => document.fullscreenElement || document.webkitFullscreenElement || null;

  function toggleFullscreen() {
    if (fullscreenElement()) {
      (document.exitFullscreen || document.webkitExitFullscreen).call(document);
      return;
    }
    const root = document.documentElement;
    const request = root.requestFullscreen || root.webkitRequestFullscreen;
    if (request) {
      const p = request.call(root);
      if (p && p.catch) p.catch(() => {});
    } else if (el.video.webkitEnterFullscreen) {
      el.video.webkitEnterFullscreen(); // iPhone Safari: only the video can go fullscreen
    }
  }

  function renderFullscreen() {
    const root = document.documentElement;
    const supported = !!(root.requestFullscreen || root.webkitRequestFullscreen || el.video.webkitEnterFullscreen);
    el.btnFs.hidden = !supported;
    const on = !!fullscreenElement();
    el.fsIcon.setAttribute("href", on ? "#i-compress" : "#i-expand");
    el.fsLabel.textContent = on ? "Exit fullscreen" : "Fullscreen";
  }

  // In fullscreen Chromium can hand us Ctrl+W, Alt+Tab-ish keys; only worth it while controlling.
  function syncKeyboardLock() {
    const kb = navigator.keyboard;
    if (!kb || !kb.lock) return;
    if (controlActive() && fullscreenElement()) kb.lock().catch(() => {});
    else kb.unlock();
  }

  // ---- audio ----

  function renderAudio() {
    const hasAudio = !!(state.hello && state.hello.audio);
    const muted = el.video.muted;
    el.btnAudio.hidden = !hasAudio;
    el.unmute.hidden = !(hasAudio && muted && state.streaming);
    el.audioIcon.setAttribute("href", muted ? "#i-volume-off" : "#i-volume-on");
    el.audioLabel.textContent = muted ? "Unmute" : "Mute";
  }

  function setMuted(muted) {
    el.video.muted = muted;
    state.muted = muted;
    session.set("muted", muted ? "1" : "0");
    if (!muted) el.video.play().catch(() => {});
    renderAudio();
  }

  // Starts playback, honouring a remembered "unmuted" choice if the browser allows it.
  async function startPlayback() {
    if (session.get("muted") === "0") {
      el.video.muted = false;
      try {
        await el.video.play();
        state.muted = false;
        renderAudio();
        return;
      } catch {
        el.video.muted = true; // autoplay policy: wait for a click on "Unmute"
        renderAudio();
      }
    }
    try {
      await el.video.play();
    } catch {
      /* muted + playsinline normally autoplays */
    }
  }

  // ---- password / PIN prompt ----

  const AUTH_COPY = {
    password: {
      title: "Password required",
      hint: "Enter the viewing password for this host.",
      label: "Password",
      submit: "Connect",
      wrong: "Wrong password",
      autocomplete: "current-password",
    },
    pin: {
      title: "Enable remote control",
      hint: "Enter the PIN printed in the host's console.",
      label: "PIN",
      submit: "Unlock",
      wrong: "Wrong PIN",
      autocomplete: "off",
    },
  };

  function showAuth(kind, error = "") {
    const c = AUTH_COPY[kind];
    state.auth.open = kind;
    el.authTitle.textContent = c.title;
    el.authHint.textContent = c.hint;
    el.authLabel.textContent = c.label;
    el.authSubmit.textContent = c.submit;
    el.authInput.autocomplete = c.autocomplete;
    el.authCancel.hidden = kind !== "pin";
    el.authError.textContent = error;
    el.authSubmit.disabled = false;
    el.authInput.value = "";
    closeSettings(false);
    releaseInput();
    if (!el.auth.open) el.auth.showModal();
    el.authInput.focus();
    applyUi();
  }

  function closeAuth() {
    state.auth.open = null;
    if (el.auth.open) el.auth.close();
    applyUi();
  }

  function sendAuth(kind, value) {
    if (!send({ type: "auth", password: value })) return false;
    state.auth.sent = kind;
    state.auth.value = value;
    return true;
  }

  function requestPassword() {
    setStatus("Password required", "warn");
    const saved = session.get("password");
    if (saved && !state.auth.tried.password) {
      state.auth.tried.password = true;
      if (sendAuth("password", saved)) return;
    }
    if (state.auth.open !== "password") showAuth("password");
  }

  function requestPin() {
    const saved = session.get("pin");
    if (saved && !state.auth.tried.pin) {
      state.auth.tried.pin = true;
      if (sendAuth("pin", saved)) return;
    }
    if (state.auth.open !== "pin") showAuth("pin");
  }

  function cancelPin() {
    state.wantControl = false;
    closeAuth();
  }

  function onAuthError() {
    // Whatever we sent last was wrong; forget it.
    const kind = state.auth.sent || (state.hello && !state.hello.authorized ? "password" : "pin");
    session.set(kind, null);
    state.auth.sent = null;
    state.auth.value = null;
    showAuth(kind, AUTH_COPY[kind].wrong);
  }

  // The hello that follows an auth tells us it worked.
  function onAuthAccepted(hello) {
    const { sent, value } = state.auth;
    if (!sent) return;
    if (sent === "password" && hello.authorized) session.set("password", value);
    else if (sent === "pin" && hello.control) session.set("pin", value);
    else return;
    state.auth.sent = null;
    state.auth.value = null;
  }

  // ---- signaling ----

  function send(msg) {
    const ws = state.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    ws.send(JSON.stringify(msg));
    return true;
  }

  function connect() {
    clearInterval(state.retryTimer);
    state.retryTimer = 0;
    teardown();
    state.fatal = false;
    state.auth.tried = { password: false, pin: false };
    setStatus("Connecting…", "idle");

    const ws = new WebSocket(signalUrl);
    state.ws = ws;
    ws.onmessage = (e) => {
      if (ws === state.ws) onMessage(e.data);
    };
    ws.onclose = () => {
      if (ws === state.ws) scheduleReconnect();
    };
    ws.onerror = () => {}; // close always follows
  }

  // Drops the socket and the peer connection; safe to call repeatedly.
  function teardown() {
    clearTimeout(state.graceTimer);
    stopStats();
    closePeer();
    releaseInput();
    const ws = state.ws;
    state.ws = null;
    if (ws) {
      ws.onmessage = ws.onclose = ws.onerror = null;
      ws.close();
    }
    if (state.mediaStream || el.video.srcObject) {
      el.video.srcObject = null;
      state.mediaStream = null;
    }
    state.streaming = false;
    applyUi();
  }

  function scheduleReconnect(reason) {
    if (state.fatal || state.retryTimer) return;
    if (state.controlOn) {
      // Control is per connection; ask again (silently, if a PIN is remembered).
      state.controlOn = false;
      state.wantControl = true;
    }
    teardown();
    const wait = state.retryMs;
    state.retryMs = Math.min(wait * 2, BACKOFF_MAX_MS);
    state.retryAt = performance.now() + wait;
    const tick = () => {
      const left = state.retryAt - performance.now();
      if (left <= 0) {
        connect();
        return;
      }
      const secs = Math.ceil(left / 1000);
      setStatus(reason ? `${reason} — retrying in ${secs} s…` : `Reconnecting in ${secs} s…`, "warn");
    };
    tick();
    state.retryTimer = setInterval(tick, 250);
  }

  function fatal(text) {
    state.fatal = true;
    teardown();
    setStatus(text, "err");
  }

  function onMessage(raw) {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    switch (msg.type) {
      case "hello":
        onHello(msg);
        break;
      case "answer":
        onAnswer(msg);
        break;
      case "candidate":
        onRemoteCandidate(msg);
        break;
      case "state":
        state.host = msg;
        if (msg.monitor != null) state.monitor = msg.monitor;
        renderMonitors();
        renderStats();
        break;
      case "error":
        onServerError(msg);
        break;
    }
  }

  function onHello(h) {
    state.hello = h;
    if (h.monitor != null) state.monitor = h.monitor;
    if (!h.authorized) {
      requestPassword();
      return;
    }
    onAuthAccepted(h);
    if (state.auth.open === "password") closeAuth();

    if (!h.input) {
      state.controlOn = false;
      state.wantControl = false;
    } else if (h.control) {
      if (state.wantControl) {
        state.controlOn = true;
        state.wantControl = false;
      }
      if (state.auth.open === "pin") closeAuth();
    } else {
      if (state.controlOn) {
        state.controlOn = false;
        notify("Remote control was turned off");
      }
      if (state.wantControl && h.controlPin) requestPin();
      else state.wantControl = false;
    }

    renderMonitors();
    applyUi();
    if (!state.pc) negotiate();
  }

  function onServerError(e) {
    const text = e.message ? e.message.charAt(0).toUpperCase() + e.message.slice(1) : "The host refused the request";
    switch (e.code) {
      case "auth":
        onAuthError();
        break;
      case "busy":
        scheduleReconnect("The host is at its viewer limit");
        break;
      case "capture":
      case "peer":
        scheduleReconnect(text);
        break;
      case "codec":
        fatal("This browser has no H.264 decoder. Firefox may need the OpenH264 plugin.");
        break;
      case "denied":
        // Retrying would put the share dialog in front of the host again and again.
        fatal("The host is not sharing its screen. Reload this page to ask again.");
        break;
      case "monitor":
        notify(text);
        renderMonitors();
        break;
      default:
        notify(text);
    }
  }

  // ---- WebRTC ----

  function browserHasH264() {
    if (!window.RTCRtpReceiver || !RTCRtpReceiver.getCapabilities) return true;
    const caps = RTCRtpReceiver.getCapabilities("video");
    if (!caps || !caps.codecs) return true;
    return caps.codecs.some((c) => c.mimeType.toLowerCase() === "video/h264");
  }

  // The host only speaks H.264 (packetization-mode=1, constrained baseline 42e01f first).
  function preferH264(transceiver) {
    if (!transceiver || !transceiver.setCodecPreferences || !RTCRtpReceiver.getCapabilities) return;
    const caps = RTCRtpReceiver.getCapabilities("video");
    if (!caps || !caps.codecs) return;
    const isH264 = (c) => c.mimeType.toLowerCase() === "video/h264";
    const fmtp = (c) => (c.sdpFmtpLine || "").toLowerCase();
    const mode1 = caps.codecs.filter((c) => isH264(c) && fmtp(c).includes("packetization-mode=1"));
    const best = mode1.filter((c) => fmtp(c).includes("profile-level-id=42e01f"));
    const mode1Rest = mode1.filter((c) => !best.includes(c));
    const otherH264 = caps.codecs.filter((c) => isH264(c) && !mode1.includes(c));
    const rest = caps.codecs.filter((c) => !isH264(c));
    try {
      transceiver.setCodecPreferences([...best, ...mode1Rest, ...otherH264, ...rest]);
    } catch (err) {
      console.warn("setCodecPreferences", err);
    }
  }

  // Chrome decodes Opus as mono unless its own (local) fmtp says stereo=1.
  function enableOpusStereo(sdp) {
    const m = /a=rtpmap:(\d+) opus\/48000\/2/i.exec(sdp);
    if (!m) return sdp;
    const fmtp = new RegExp(`^a=fmtp:${m[1]} ([^\r\n]*)`, "m");
    const found = fmtp.exec(sdp);
    if (found) {
      if (/(^|;)\s*stereo=1/.test(found[1])) return sdp;
      return sdp.replace(fmtp, (line) => `${line};stereo=1`);
    }
    return sdp.replace(m[0], `${m[0]}
a=fmtp:${m[1]} stereo=1`);
  }

  async function negotiate() {
    if (!browserHasH264()) {
      fatal("This browser has no H.264 decoder. Firefox may need the OpenH264 plugin.");
      return;
    }
    const pc = new RTCPeerConnection({ iceServers: [] });
    state.pc = pc;
    state.remoteSet = false;
    state.pendingIce.length = 0;
    state.prev = null;

    pc.ontrack = (ev) => onTrack(pc, ev);
    pc.onicecandidate = (ev) => {
      if (ev.candidate && ev.candidate.candidate) {
        send({ type: "candidate", candidate: ev.candidate.candidate, sdpMid: ev.candidate.sdpMid ?? "0" });
      }
    };
    pc.onconnectionstatechange = () => onPeerState(pc);

    // Order matters: the host expects video as mid "0" and audio as mid "1".
    const video = pc.addTransceiver("video", { direction: "recvonly" });
    preferH264(video);
    if (state.hello && state.hello.audio) pc.addTransceiver("audio", { direction: "recvonly" });

    setStatus("Waiting for the host…", "warn");
    try {
      const offer = await pc.createOffer();
      if (pc !== state.pc) return;
      offer.sdp = enableOpusStereo(offer.sdp);
      await pc.setLocalDescription(offer);
      if (pc !== state.pc) return;
      send({ type: "offer", sdp: offer.sdp });
    } catch (err) {
      if (pc !== state.pc) return;
      console.warn("offer", err);
      scheduleReconnect("Could not start the connection");
    }
  }

  function closePeer() {
    const pc = state.pc;
    state.pc = null;
    state.remoteSet = false;
    state.pendingIce.length = 0;
    if (pc) {
      pc.ontrack = pc.onicecandidate = pc.onconnectionstatechange = null;
      pc.close();
    }
  }

  function onTrack(pc, ev) {
    if (pc !== state.pc) return;
    let stream = ev.streams[0];
    if (!stream) {
      state.mediaStream = state.mediaStream || new MediaStream();
      state.mediaStream.addTrack(ev.track);
      stream = state.mediaStream;
    }
    if (el.video.srcObject !== stream) el.video.srcObject = stream;
    if (ev.track.kind !== "video") return;
    try {
      if ("playoutDelayHint" in ev.receiver) ev.receiver.playoutDelayHint = 0;
    } catch {
      /* optional API */
    }
    el.video.disableRemotePlayback = true;
    startPlayback();
    send({ type: "keyframe" });
    startStats();
  }

  function onPeerState(pc) {
    if (pc !== state.pc) return;
    switch (pc.connectionState) {
      case "connected":
        clearTimeout(state.graceTimer);
        if (state.streaming) setStatus("Streaming", "ok");
        break;
      case "disconnected":
        setStatus("Connection interrupted — waiting…", "warn");
        clearTimeout(state.graceTimer);
        state.graceTimer = setTimeout(() => scheduleReconnect(), DISCONNECT_GRACE_MS);
        break;
      case "failed":
        scheduleReconnect();
        break;
    }
  }

  function markStreaming() {
    if (state.streaming) return;
    state.streaming = true;
    state.retryMs = BACKOFF_MIN_MS;
    setStatus("Streaming", "ok");
    applyUi();
  }

  async function onAnswer(msg) {
    const pc = state.pc;
    if (!pc || !msg.sdp) return;
    try {
      await pc.setRemoteDescription({ type: "answer", sdp: msg.sdp });
    } catch (err) {
      if (pc !== state.pc) return;
      console.warn("setRemoteDescription", err);
      scheduleReconnect("The host sent an unusable answer");
      return;
    }
    if (pc !== state.pc) return;
    state.remoteSet = true;
    if (!state.streaming) setStatus("Waiting for video…", "warn");
    const queued = state.pendingIce.splice(0);
    for (const init of queued) await addCandidate(pc, init);
  }

  function onRemoteCandidate(msg) {
    const pc = state.pc;
    if (!pc || !msg.candidate) return;
    const init = { candidate: msg.candidate, sdpMid: msg.sdpMid ?? "0" };
    const line = pc.getTransceivers().findIndex((t) => t.mid === init.sdpMid);
    init.sdpMLineIndex = line >= 0 ? line : 0;
    if (!state.remoteSet) state.pendingIce.push(init); // addIceCandidate needs the answer first
    else addCandidate(pc, init);
  }

  async function addCandidate(pc, init) {
    try {
      await pc.addIceCandidate(init);
    } catch (err) {
      if (pc === state.pc) console.warn("addIceCandidate", err);
    }
  }

  // ---- statistics ----

  function startStats() {
    stopStats();
    state.statsTimer = setInterval(pollStats, STATS_MS);
    pollStats();
  }

  function stopStats() {
    clearInterval(state.statsTimer);
    state.statsTimer = 0;
    state.prev = null;
    state.live = null;
  }

  async function pollStats() {
    const pc = state.pc;
    if (!pc) return;
    let report;
    try {
      report = await pc.getStats();
    } catch {
      return;
    }
    if (pc !== state.pc) return;
    let v = null;
    report.forEach((s) => {
      if (s.type === "inbound-rtp" && (s.kind || s.mediaType) === "video") v = s;
    });
    if (!v) return;
    if ((v.framesDecoded || 0) > 0) markStreaming();

    const cur = {
      t: v.timestamp,
      bytes: v.bytesReceived || 0,
      frames: v.framesDecoded || 0,
      lost: Math.max(0, v.packetsLost || 0),
      recv: v.packetsReceived || 0,
      jbd: v.jitterBufferDelay,
      jbc: v.jitterBufferEmittedCount,
    };
    const p = state.prev;
    state.prev = cur;
    const s = state.live || (state.live = {});
    s.width = v.frameWidth;
    s.height = v.frameHeight;
    s.decoder = v.decoderImplementation;
    if (p && cur.t > p.t) {
      const dt = (cur.t - p.t) / 1000;
      s.fps = (cur.frames - p.frames) / dt;
      s.kbps = ((cur.bytes - p.bytes) * 8) / 1000 / dt;
      const dPackets = cur.lost - p.lost + (cur.recv - p.recv);
      s.loss = dPackets > 0 ? ((cur.lost - p.lost) / dPackets) * 100 : 0;
      const dCount = cur.jbc - p.jbc;
      if (dCount > 0) s.jitterMs = ((cur.jbd - p.jbd) / dCount) * 1000;
    }
    renderStats();
  }

  function renderStats() {
    if (!state.prefs.stats) return;
    const s = state.live || {};
    const h = state.host || {};
    const num = (n, digits = 0) => (Number.isFinite(n) ? n.toFixed(digits) : "–");
    const width = s.width || h.width;
    const height = s.height || h.height;
    $("st-res").textContent = width && height ? `${width}×${height}` : "–";
    $("st-fps").textContent = Number.isFinite(s.fps) ? `${num(s.fps)}${h.fps ? ` / ${h.fps}` : ""}` : "–";
    $("st-rate").textContent = Number.isFinite(s.kbps) ? `${num(s.kbps)} kbit/s` : "–";
    $("st-loss").textContent = Number.isFinite(s.loss) ? `${num(s.loss, 1)} %` : "–";
    $("st-jit").textContent = Number.isFinite(s.jitterMs) ? `${num(s.jitterMs)} ms` : "–";
    $("st-dec").textContent = s.decoder || "–";
    $("st-enc").textContent = h.encoder || "–";
    $("st-cap").textContent = h.capture || "–";
    $("st-view").textContent = h.viewers != null ? String(h.viewers) : "–";
  }

  // ---- remote control ----

  const input = {
    keys: new Set(), // KeyboardEvent.code currently held on the host
    buttons: new Set(), // MouseEvent.button currently held on the host
    last: { x: 0.5, y: 0.5 },
    move: null, // coalesced until the next animation frame
    wheel: null,
    raf: 0,
  };

  const controlActive = () =>
    state.controlOn &&
    !!(state.hello && state.hello.control) &&
    !!state.ws &&
    state.ws.readyState === WebSocket.OPEN &&
    !state.settingsOpen &&
    !state.auth.open;

  // Pointer position -> 0..1 across the video *content* (the captured monitor),
  // accounting for the letterbox bars object-fit: contain adds. `box` is a
  // {left, top, width, height} rect (a DOMRect works). Returns null outside the
  // content unless `clamp` is set (used while dragging).
  function mapPoint(clientX, clientY, box, videoW, videoH, clamp = false) {
    if (!(videoW > 0 && videoH > 0 && box.width > 0 && box.height > 0)) return null;
    const scale = Math.min(box.width / videoW, box.height / videoH);
    const w = videoW * scale;
    const h = videoH * scale;
    let x = (clientX - (box.left + (box.width - w) / 2)) / w;
    let y = (clientY - (box.top + (box.height - h) / 2)) / h;
    if (x < 0 || x > 1 || y < 0 || y > 1) {
      if (!clamp) return null;
      x = Math.min(1, Math.max(0, x));
      y = Math.min(1, Math.max(0, y));
    }
    return { x: Math.round(x * 1e5) / 1e5, y: Math.round(y * 1e5) / 1e5 };
  }

  const pointOf = (e, clamp = false) =>
    mapPoint(e.clientX, e.clientY, el.video.getBoundingClientRect(), el.video.videoWidth, el.video.videoHeight, clamp);

  function sendInput(msg) {
    send({ type: "input", ...msg });
  }

  function flushInput() {
    cancelAnimationFrame(input.raf);
    input.raf = 0;
    if (input.move) {
      sendInput({ ev: "move", ...input.move });
      input.last = input.move;
      input.move = null;
    }
    if (input.wheel) {
      sendInput({ ev: "wheel", ...input.wheel });
      input.wheel = null;
    }
  }

  const scheduleFlush = () => {
    if (!input.raf) input.raf = requestAnimationFrame(flushInput);
  };

  function queueMove(p) {
    input.move = p;
    scheduleFlush();
  }

  function buttonEvent(ev, button, p) {
    flushInput();
    input.last = p;
    if (ev === "down") input.buttons.add(button);
    else input.buttons.delete(button);
    sendInput({ ev, button, ...p });
  }

  // Lets go of everything the host might think is still pressed.
  function releaseInput() {
    cancelAnimationFrame(input.raf);
    input.raf = 0;
    input.move = null;
    input.wheel = null;
    for (const button of input.buttons) sendInput({ ev: "up", button, ...input.last });
    for (const key of input.keys) sendInput({ ev: "key", key, down: false });
    input.buttons.clear();
    input.keys.clear();
    resetTouch();
  }

  function setControl(on) {
    if (!on) {
      releaseInput();
      state.controlOn = false;
      state.wantControl = false;
      applyUi();
      return;
    }
    const h = state.hello;
    if (!h || !h.input) return;
    if (h.control) {
      state.controlOn = true;
      closeSettings(false);
      applyUi();
    } else if (h.controlPin) {
      state.wantControl = true;
      requestPin();
    }
  }

  // mouse and pen
  function onPointerDown(e) {
    if (state.settingsOpen || !controlActive()) return;
    if (e.pointerType === "touch") return touchDown(e);
    const p = pointOf(e);
    if (!p) return;
    e.preventDefault();
    el.stage.setPointerCapture(e.pointerId);
    buttonEvent("down", e.button, p);
  }

  function onPointerMove(e) {
    if (!controlActive()) return;
    if (e.pointerType === "touch") return touchMove(e);
    const p = pointOf(e, input.buttons.size > 0);
    if (p) queueMove(p);
  }

  function onPointerUp(e) {
    if (e.pointerType === "touch") return touchUp(e);
    if (!input.buttons.has(e.button)) return;
    const p = pointOf(e, true) || input.last;
    e.preventDefault();
    buttonEvent("up", e.button, p);
  }

  function onPointerCancel(e) {
    if (e.pointerType === "touch") resetTouch();
    else releaseInput();
  }

  function onWheel(e) {
    if (!controlActive()) return;
    e.preventDefault();
    const p = pointOf(e);
    if (!p) return;
    const k = e.deltaMode === 1 ? LINE_PX : e.deltaMode === 2 ? window.innerHeight : 1;
    const w = input.wheel || { dx: 0, dy: 0 };
    input.wheel = { dx: w.dx + e.deltaX * k, dy: w.dy + e.deltaY * k, ...p };
    scheduleFlush();
  }

  const isEscapeChord = (e) => e.ctrlKey && e.altKey && e.shiftKey && e.code === "KeyQ";

  function onKeyDown(e) {
    if (!controlActive()) return;
    e.preventDefault();
    if (isEscapeChord(e)) {
      setControl(false);
      return;
    }
    if (!e.code) return;
    flushInput();
    input.keys.add(e.code);
    sendInput({ ev: "key", key: e.code, down: true });
  }

  function onKeyUp(e) {
    if (!controlActive()) return;
    e.preventDefault();
    if (input.keys.delete(e.code)) sendInput({ ev: "key", key: e.code, down: false });
  }

  // touch: tap = left click, two-finger tap = right click, press-and-hold then drag = drag
  const touch = { pts: new Map(), startT: 0, moved: false, peak: 0, anchor: null, dragging: false, timer: 0 };

  function resetTouch() {
    clearTimeout(touch.timer);
    touch.pts.clear();
    touch.dragging = false;
    touch.moved = false;
    touch.peak = 0;
  }

  function touchDown(e) {
    e.preventDefault();
    el.stage.setPointerCapture(e.pointerId);
    if (touch.pts.size === 0) {
      touch.startT = e.timeStamp;
      touch.moved = false;
      touch.peak = 0;
      touch.dragging = false;
      touch.anchor = { x: e.clientX, y: e.clientY };
    }
    touch.pts.set(e.pointerId, { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY });
    touch.peak = Math.max(touch.peak, touch.pts.size);
    clearTimeout(touch.timer);
    if (touch.pts.size === 1) {
      touch.timer = setTimeout(() => {
        if (touch.moved || touch.pts.size !== 1) return;
        const p = pointOf(touch.anchor, true);
        if (!p) return;
        touch.dragging = true;
        if (navigator.vibrate) navigator.vibrate(12);
        sendInput({ ev: "move", ...p });
        buttonEvent("down", 0, p);
      }, LONG_PRESS_MS);
    }
  }

  function touchMove(e) {
    const pt = touch.pts.get(e.pointerId);
    if (!pt) return;
    pt.x = e.clientX;
    pt.y = e.clientY;
    if (Math.hypot(pt.x - pt.sx, pt.y - pt.sy) > TAP_SLOP_PX && !touch.dragging) {
      touch.moved = true;
      clearTimeout(touch.timer);
    }
    if (touch.pts.size === 1 && (touch.moved || touch.dragging)) {
      const p = pointOf(e, true);
      if (p) queueMove(p);
    }
  }

  function touchUp(e) {
    if (!touch.pts.delete(e.pointerId)) return;
    clearTimeout(touch.timer);
    if (touch.pts.size > 0) return; // wait for the last finger
    if (touch.dragging) {
      touch.dragging = false;
      buttonEvent("up", 0, pointOf(e, true) || input.last);
      return;
    }
    if (touch.moved || e.timeStamp - touch.startT > LONG_PRESS_MS + 50) return;
    const p = pointOf(touch.anchor);
    if (!p) return;
    const button = touch.peak >= 2 ? 2 : 0;
    flushInput();
    sendInput({ ev: "move", ...p });
    buttonEvent("down", button, p);
    buttonEvent("up", button, p);
  }

  // ---- wiring ----

  function bindUi() {
    el.optOverlay.addEventListener("change", () => setPref("overlay", el.optOverlay.checked));
    el.optStats.addEventListener("change", () => {
      setPref("stats", el.optStats.checked);
      renderStats();
    });
    el.optControl.addEventListener("change", () => setControl(el.optControl.checked));
    el.controlPill.addEventListener("click", () => setControl(false));
    el.settingsBtn.addEventListener("click", toggleSettings);
    el.btnFs.addEventListener("click", toggleFullscreen);
    el.btnAudio.addEventListener("click", () => setMuted(!el.video.muted));
    el.unmute.addEventListener("click", () => setMuted(false));
    el.monitor.addEventListener("change", () => send({ type: "monitor", index: Number(el.monitor.value) }));

    el.authForm.addEventListener("submit", (e) => {
      e.preventDefault();
      const value = el.authInput.value;
      if (!value || !state.auth.open) return;
      el.authError.textContent = "";
      if (sendAuth(state.auth.open, value)) el.authSubmit.disabled = true;
      else el.authError.textContent = "Not connected yet. Try again in a moment.";
    });
    el.authCancel.addEventListener("click", cancelPin);
    el.auth.addEventListener("cancel", (e) => {
      // Escape: the viewing password cannot be skipped, the control PIN can.
      if (state.auth.open === "pin") cancelPin();
      else e.preventDefault();
    });

    el.video.addEventListener("playing", markStreaming);
    el.video.addEventListener("volumechange", renderAudio);
    el.stage.addEventListener("dblclick", () => {
      if (!state.controlOn) toggleFullscreen();
    });

    for (const ev of ["fullscreenchange", "webkitfullscreenchange"]) document.addEventListener(ev, applyUi);

    // overlay wake-up
    for (const ev of ["pointermove", "pointerdown"]) document.addEventListener(ev, wake, { passive: true });
    document.addEventListener("focusin", wake);

    // settings: close on outside click / Escape
    document.addEventListener("pointerdown", (e) => {
      if (state.settingsOpen && !el.settings.contains(e.target) && !el.settingsBtn.contains(e.target)) closeSettings(false);
    });

    document.addEventListener("keydown", onShortcut);

    // control mode
    const s = el.stage;
    s.addEventListener("pointerdown", onPointerDown);
    s.addEventListener("pointermove", onPointerMove);
    s.addEventListener("pointerup", onPointerUp);
    s.addEventListener("pointercancel", onPointerCancel);
    s.addEventListener("wheel", onWheel, { passive: false });
    s.addEventListener("contextmenu", (e) => {
      if (controlActive()) e.preventDefault();
    });
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("keyup", onKeyUp, true);
    window.addEventListener("blur", releaseInput);
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) releaseInput();
      else send({ type: "keyframe" }); // the video may have frozen in the background
    });

    window.addEventListener("pagehide", () => {
      send({ type: "bye" });
      teardown();
    });
    window.addEventListener("pageshow", (e) => {
      if (e.persisted) connect(); // restored from the back/forward cache
    });
  }

  // Single-key shortcuts, only while keys are not being forwarded to the host.
  function onShortcut(e) {
    if (e.key === "Escape" && state.settingsOpen) {
      e.preventDefault();
      closeSettings();
      return;
    }
    if (controlActive() || state.auth.open || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.target instanceof Element && e.target.closest("input:not([type=checkbox]), select, textarea")) return;
    switch (e.key.toLowerCase()) {
      case "o":
        setPref("overlay", !state.prefs.overlay);
        break;
      case "s":
        setPref("stats", !state.prefs.stats);
        renderStats();
        break;
      case "f":
        toggleFullscreen();
        break;
      case "m":
        if (state.hello && state.hello.audio) setMuted(!el.video.muted);
        break;
      default:
        return;
    }
    wake();
  }

  // #pin=... / #password=... are accepted once and then removed from the address bar.
  function consumeHash() {
    if (!location.hash) return;
    const params = new URLSearchParams(location.hash.slice(1));
    const password = params.get("password");
    const pin = params.get("pin");
    if (!password && !pin) return;
    if (password) session.set("password", password);
    if (pin) {
      session.set("pin", pin);
      state.wantControl = true;
    }
    history.replaceState(null, "", location.pathname + location.search);
  }

  window.odysseus = {
    get pc() {
      return state.pc;
    },
    get ws() {
      return state.ws;
    },
    state,
    mapPoint,
    setControl,
    receive: (msg) => onMessage(JSON.stringify(msg)), // test hook: pretend the host sent `msg`
  };

  if (session.get("muted") === "0") state.muted = false;
  consumeHash();
  bindUi();
  renderStatus();
  applyUi();
  wake();
  connect();
})();
