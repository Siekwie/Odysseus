// Headless end-to-end check: opens the Odysseus viewer in a headless Chromium
// (Edge or Chrome) through the DevTools protocol and reports what the browser
// actually decoded. No npm dependencies; needs Node 22+ (global WebSocket/fetch).
//
//   node tests/e2e/viewer.mjs --url http://127.0.0.1:8080/odysseus --seconds 6
//
// Options:
//   --seconds N        how long to watch before sampling stats (default 6)
//   --min-frames N     decoded frames required to pass (default 10)
//   --no-video-check   same as --min-frames 0
//   --viewers N        open N tabs at once
//   --expect-audio     also require received audio packets
//   --eval "js"        run JavaScript in each page ~1.5 s after load (repeatable; may return a promise)
//   --inject "js"      run JavaScript before any page script (repeatable)
//   --final "js"       evaluate after watching; results are reported as "final" (repeatable)
//   --screenshot f.png save a screenshot of the first tab before sampling
//   --mobile           emulate a 390x844 phone viewport
//
// Exit code 0 when the requirements were met.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function parseArgs(argv) {
  const out = { url: "http://127.0.0.1:8080/odysseus", seconds: 6, minFrames: 10, eval: [], inject: [], final: [], viewers: 1 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === "--url") out.url = next();
    else if (a === "--seconds") out.seconds = Number(next());
    else if (a === "--min-frames") out.minFrames = Number(next());
    else if (a === "--eval") out.eval.push(next());
    else if (a === "--inject") out.inject.push(next());
    else if (a === "--final") out.final.push(next());
    else if (a === "--viewers") out.viewers = Number(next());
    else if (a === "--expect-audio") out.expectAudio = true;
    else if (a === "--screenshot") out.screenshot = next();
    else if (a === "--mobile") out.mobile = true;
    else if (a === "--no-video-check") out.minFrames = 0;
    else if (a === "--verbose") out.verbose = true;
  }
  return out;
}

function findBrowser() {
  if (process.env.BROWSER && existsSync(process.env.BROWSER)) return process.env.BROWSER;
  const candidates = [
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/microsoft-edge",
  ];
  return candidates.find((p) => existsSync(p));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.events = [];
    this.ready = new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
      } else if (msg.method) {
        this.events.push(msg);
      }
    };
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async eval(expression) {
    const r = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) {
      throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    }
    return r.result.value;
  }
  close() {
    try { this.ws.close(); } catch {}
  }
}

const STATS_JS = `(async () => {
  const out = { status: document.getElementById("status")?.textContent ?? "", video: null, audio: null };
  const v = document.getElementById("stream");
  if (v) out.element = { w: v.videoWidth, h: v.videoHeight, paused: v.paused, readyState: v.readyState, t: v.currentTime };
  const peer = (window.odysseus && window.odysseus.pc) || (typeof pc !== "undefined" ? pc : null);
  if (!peer) return out;
  out.connectionState = peer.connectionState;
  const stats = await peer.getStats();
  stats.forEach((s) => {
    if (s.type !== "inbound-rtp") return;
    const pick = {
      framesDecoded: s.framesDecoded, framesReceived: s.framesReceived, framesDropped: s.framesDropped,
      keyFramesDecoded: s.keyFramesDecoded, frameWidth: s.frameWidth, frameHeight: s.frameHeight,
      packetsReceived: s.packetsReceived, packetsLost: s.packetsLost, bytesReceived: s.bytesReceived,
      framesPerSecond: s.framesPerSecond, decoder: s.decoderImplementation, pliCount: s.pliCount,
      nackCount: s.nackCount, jitter: s.jitter, freezeCount: s.freezeCount,
      totalSamplesReceived: s.totalSamplesReceived, audioLevel: s.audioLevel,
    };
    if (s.kind === "video") out.video = pick; else if (s.kind === "audio") out.audio = pick;
  });
  return out;
})()`;

async function main() {
  const args = parseArgs(process.argv);
  const browser = findBrowser();
  if (!browser) {
    console.error("no Chromium-based browser found; set BROWSER=/path/to/chrome");
    process.exit(2);
  }
  const profile = mkdtempSync(join(tmpdir(), "odysseus-e2e-"));
  const port = 9300 + Math.floor(Math.random() * 500);
  const child = spawn(browser, [
    "--headless=new",
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--mute-audio",
    "--autoplay-policy=no-user-gesture-required",
    "--window-size=1280,720",
    // E2E_BROWSER_ARGS: extra flags, e.g. "--no-sandbox" on CI runners.
    ...(process.env.E2E_BROWSER_ARGS ? process.env.E2E_BROWSER_ARGS.split(" ").filter(Boolean) : []),
    "about:blank",
  ], { stdio: "ignore" });

  let code = 1;
  const pages = [];
  try {
    let version = null;
    for (let i = 0; i < 50 && !version; i++) {
      try {
        version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
      } catch {
        await sleep(200);
      }
    }
    if (!version) throw new Error("browser did not expose a DevTools endpoint");

    for (let i = 0; i < args.viewers; i++) {
      const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
      const cdp = new Cdp(target.webSocketDebuggerUrl);
      await cdp.ready;
      await cdp.send("Runtime.enable");
      await cdp.send("Log.enable");
      await cdp.send("Page.enable");
      if (args.mobile) {
        await cdp.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
      }
      for (const source of args.inject) {
        await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source });
      }
      await cdp.send("Page.navigate", { url: args.url });
      pages.push(cdp);
    }

    await sleep(1500);
    for (const cdp of pages) {
      for (const expr of args.eval) {
        const v = await cdp.eval(expr);
        if (args.verbose) console.error("eval:", expr, "=>", JSON.stringify(v));
      }
    }
    await sleep(args.seconds * 1000);

    if (args.screenshot) {
      const shot = await pages[0].send("Page.captureScreenshot", { format: "png" });
      writeFileSync(args.screenshot, Buffer.from(shot.data, "base64"));
    }

    const results = [];
    for (const cdp of pages) {
      const r = await cdp.eval(STATS_JS);
      for (const expr of args.final) {
        (r.final ??= []).push(await cdp.eval(expr));
      }
      r.console = cdp.events
        .filter((e) => e.method === "Runtime.consoleAPICalled" || e.method === "Runtime.exceptionThrown" || e.method === "Log.entryAdded")
        .map((e) => {
          if (e.method === "Runtime.consoleAPICalled") return `${e.params.type}: ${e.params.args.map((a) => a.value ?? a.description ?? "").join(" ")}`;
          if (e.method === "Log.entryAdded") return `${e.params.entry.level}: ${e.params.entry.text}`;
          return `exception: ${e.params.exceptionDetails?.exception?.description ?? e.params.exceptionDetails?.text}`;
        })
        .slice(0, 20);
      results.push(r);
    }
    console.log(JSON.stringify(args.viewers === 1 ? results[0] : results, null, 2));

    const ok = results.every((r) => (r.video?.framesDecoded ?? 0) >= args.minFrames &&
      (!args.expectAudio || (r.audio?.packetsReceived ?? 0) > 0));
    code = ok ? 0 : 1;
    if (!ok) console.error(`FAIL: expected >= ${args.minFrames} decoded frames${args.expectAudio ? " and audio packets" : ""}`);
  } catch (err) {
    console.error("e2e error:", err.message);
    code = 2;
  } finally {
    for (const cdp of pages) cdp.close();
    child.kill();
    await sleep(500);
    try { rmSync(profile, { recursive: true, force: true }); } catch {}
  }
  process.exit(code);
}

main();
