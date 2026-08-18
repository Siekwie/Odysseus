const statusEl = document.getElementById("status");
const videoEl = document.getElementById("stream");

const proto = location.protocol === "https:" ? "wss" : "ws";
const signalUrl = `${proto}://${location.host}/signal`;

let pc = null;
let ws = null;
let retryMs = 1000;
let remoteSet = false;
let hasTrack = false;
let statsTimer = null;
const pendingIce = [];

function setStatus(text) {
  statusEl.textContent = text;
}

function send(msg) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function stopStats() {
  if (statsTimer) {
    clearInterval(statsTimer);
    statsTimer = null;
  }
}

function startStats(peer) {
  stopStats();
  statsTimer = setInterval(async () => {
    if (!peer) return;
    try {
      const stats = await peer.getStats();
      let inbound = null;
      stats.forEach((s) => {
        if (s.type === "inbound-rtp" && s.kind === "video") {
          inbound = s;
        }
      });
      if (!inbound) {
        return;
      }
      const dec = inbound.framesDecoded ?? 0;
      const rec = inbound.framesReceived ?? 0;
      const lost = inbound.packetsLost ?? 0;
      const pkts = inbound.packetsReceived ?? 0;
      const bytes = inbound.bytesReceived ?? 0;
      const impl = inbound.decoderImplementation ? ` · ${inbound.decoderImplementation}` : "";
      setStatus(`Streaming · ${dec} decoded / ${rec} frames · ${pkts} pkts · ${lost} lost · ${Math.round(bytes / 1000)} KB${impl}`);
    } catch (_) {
      // ignore
    }
  }, 1000);
}

function closePeer() {
  stopStats();
  if (pc) {
    pc.close();
    pc = null;
  }
  hasTrack = false;
}

async function playVideo() {
  try {
    await videoEl.play();
  } catch (_) {
    // muted + playsinline is enough for autoplay in most browsers
  }
}

function applyLowLatency(receiver, track) {
  try {
    if (receiver && "playoutDelayHint" in receiver) {
      receiver.playoutDelayHint = 0;
    }
    if (track && "playoutDelayHint" in track) {
      track.playoutDelayHint = 0;
    }
  } catch (_) {
    // optional API; ignore if unsupported
  }
  videoEl.disableRemotePlayback = true;
}

function browserHasH264() {
  if (!RTCRtpReceiver.getCapabilities) {
    return true;
  }
  const caps = RTCRtpReceiver.getCapabilities("video");
  if (!caps || !caps.codecs) {
    return true;
  }
  return caps.codecs.some((c) => c.mimeType.toLowerCase() === "video/h264");
}

function preferH264(peer) {
  const transceivers = peer.getTransceivers();
  const trans = transceivers[0];
  if (!trans || !RTCRtpReceiver.getCapabilities) {
    return;
  }
  const caps = RTCRtpReceiver.getCapabilities("video");
  if (!caps || !caps.codecs) {
    return;
  }
  const mode1 = caps.codecs.filter((c) =>
    c.mimeType.toLowerCase() === "video/h264" &&
    (c.sdpFmtpLine || "").includes("packetization-mode=1")
  );
  const constrained = mode1.filter((c) =>
    (c.sdpFmtpLine || "").toLowerCase().includes("profile-level-id=42e01f")
  );
  const mode1Rest = mode1.filter((c) => !constrained.includes(c));
  const otherH264 = caps.codecs.filter((c) =>
    c.mimeType.toLowerCase() === "video/h264" && !mode1.includes(c)
  );
  const rest = caps.codecs.filter((c) => c.mimeType.toLowerCase() !== "video/h264");
  try {
    trans.setCodecPreferences([...constrained, ...mode1Rest, ...otherH264, ...rest]);
  } catch (err) {
    console.warn("setCodecPreferences", err);
  }
}

async function start() {
  closePeer();
  remoteSet = false;
  pendingIce.length = 0;
  setStatus("Connecting signaling…");

  ws = new WebSocket(signalUrl);
  ws.onopen = async () => {
    retryMs = 1000;
    setStatus("Negotiating WebRTC…");
    pc = new RTCPeerConnection({ iceServers: [] });

    pc.ontrack = (event) => {
      const stream = event.streams[0] ?? new MediaStream([event.track]);
      videoEl.srcObject = stream;
      hasTrack = true;
      setStatus("Streaming");
      applyLowLatency(event.receiver, event.track);
      playVideo();
      startStats(pc);
      send({ type: "viewer-ready" });
    };
    pc.onconnectionstatechange = () => {
      if (!pc) return;
      if (!hasTrack) {
        setStatus(`WebRTC ${pc.connectionState}`);
      }
      if (pc.connectionState === "failed" || pc.connectionState === "disconnected") {
        reconnect();
      }
    };
    pc.onicecandidate = (event) => {
      if (event.candidate) {
        send({
          type: "candidate",
          candidate: event.candidate.candidate,
          sdpMid: event.candidate.sdpMid ?? "0",
        });
      }
    };

    pc.addTransceiver("video", { direction: "recvonly" });
    if (!browserHasH264()) {
      setStatus("This browser has no H.264 decoder. Firefox needs the OpenH264 plugin.");
    }
    preferH264(pc);
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    send({ type: "offer", sdp: offer.sdp });
  };

  ws.onmessage = async (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === "error") {
      setStatus(msg.message || "Rejected");
      if (msg.message === "too many viewers") {
        reconnect();
      }
      return;
    }
    if (!pc) return;
    if (msg.type === "answer" && msg.sdp) {
      try {
        await pc.setRemoteDescription({ type: "answer", sdp: msg.sdp });
      } catch (err) {
        console.warn("setRemoteDescription", err);
        setStatus("SDP error");
        return;
      }
      remoteSet = true;
      for (const cand of pendingIce) {
        try {
          await pc.addIceCandidate(cand);
        } catch (err) {
          console.warn("ICE candidate", err);
        }
      }
      pendingIce.length = 0;
    } else if (msg.type === "candidate" && msg.candidate) {
      const init = {
        candidate: msg.candidate,
        sdpMid: msg.sdpMid ?? "0",
        sdpMLineIndex: 0,
      };
      if (!remoteSet) {
        pendingIce.push(init);
        return;
      }
      try {
        await pc.addIceCandidate(init);
      } catch (err) {
        console.warn("ICE candidate", err);
      }
    }
  };

  ws.onclose = () => reconnect();
  ws.onerror = () => ws.close();
}

function reconnect() {
  closePeer();
  if (ws) {
    ws.onclose = null;
    ws.close();
    ws = null;
  }
  setStatus(`Reconnecting in ${Math.round(retryMs / 1000)}s…`);
  const wait = retryMs;
  retryMs = Math.min(retryMs * 2, 8000);
  setTimeout(start, wait);
}

window.addEventListener("pagehide", () => send({ type: "bye" }));

start();
