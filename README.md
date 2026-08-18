# Odysseus

Odysseus is a low-latency local-network screen sharing application written in
[Odin](https://odin-lang.org/).

It captures the host computer’s screen, encodes it with FFmpeg, and streams it to
web browsers using WebRTC.

Open the stream from another device on the same local network:

```text
http://<streaming-computer-ip>:<port>/odysseus
```

Example:

```text
http://192.168.178.42:8080/odysseus
```

Odysseus is designed for LAN use. It does not require an external service,
account, STUN server, or TURN server for devices that can directly reach each
other on the same network.

## Features

- Real-time desktop capture
- Low-latency streaming with WebRTC
- Browser playback through a native HTML `<video>` element
- FFmpeg-based H.264 video encoding
- Hardware encoding where supported
- Mouse cursor included in the stream
- Local-network-first design
- Simple browser access through `/odysseus`
- Automatic WebRTC reconnect handling
- Configurable resolution, FPS, bitrate, and port

## Architecture

```text
Screen Capture
  → Frame conversion / scaling
  → FFmpeg video encoder
  → WebRTC video track
  → Browser <video> element
```

WebRTC is used for media delivery instead of sending individual image frames over
WebSockets.

WebSockets may still be used internally for WebRTC signaling, such as exchanging
SDP offers, answers, and ICE candidates. The video stream itself is transported
by WebRTC.

## Requirements

### Host computer

- Odin compiler
- Windows x64 (Linux/macOS capture is later)
- Vendored FFmpeg 8.x and libdatachannel under `vendor/` (already in this repo for Windows)
- A compatible H.264 encoder at runtime (NVENC / QSV / AMF, or libx264 from the GPL FFmpeg build)

### Viewer computer

- A modern browser with WebRTC support:
  - Chrome
  - Firefox
  - Microsoft Edge
  - Safari

Both devices must be connected to the same local network.

## Installation

### 1. Install Odin

Install Odin using the official instructions:

```text
https://odin-lang.org/docs/install/
```

Verify the installation:

```bash
odin version
```

### 2. Native libraries (Windows)

FFmpeg 8.1 (BtbN `win64-gpl-shared`, includes libx264) and libdatachannel are
vendored under `vendor/ffmpeg` and `vendor/libdatachannel`. You do not need a
system FFmpeg install.

To rebuild libdatachannel from source (MinGW + CMake):

```powershell
.\scripts\fetch-libs.ps1
```

### 3. Clone and build

```powershell
git clone https://github.com/<your-user>/Odysseus.git
cd Odysseus
.\build.ps1
```

`build.ps1` compiles to `build/odysseus.exe` and copies the vendored DLLs
into `build/`. This Odin nightly has no `-config:` flag; bindings use the real
libs automatically when `vendor/*/lib/*.lib` exist.

## Usage

### Start streaming

Run Odysseus on the computer whose screen should be shared:

```bash
./build/odysseus
```

On Windows:

```powershell
.\build.ps1
.\build\odysseus.exe
```

By default, the server listens on `0.0.0.0:8080` (all IPv4 interfaces). Use
`-bind:` to listen on one LAN NIC; the same address is used for WebRTC ICE host
candidates. `-max-viewers:` caps concurrent streams (default 8). `-max-http:`
caps concurrent HTTP connections (default 64).

### Find the streaming computer IP address

#### Linux

```bash
hostname -I
```

#### macOS

```bash
ipconfig getifaddr en0
```

#### Windows

```bash
ipconfig
```

Look for the local IPv4 address, usually similar to:

```text
192.168.x.x
```

or:

```text
10.x.x.x
```

### Open the stream

From another device on the same network, open:

```text
http://<host-ip>:8080/odysseus
```

For example:

```text
http://192.168.178.42:8080/odysseus
```

The browser connects to the Odysseus signaling endpoint, establishes a direct
WebRTC connection, and displays the host screen in a video element.

## Configuration

Odysseus can be configured through command-line flags.

```bash
./build/odysseus \
  -bind:0.0.0.0 \
  -port:8080 \
  -fps:30 \
  -width:1920 \
  -height:1080 \
  -bitrate:8000 \
  -encoder:h264 \
  -cursor:true \
  -max-viewers:8 \
  -max-http:64
```

The mouse cursor is drawn into the stream by default. Disable it with `-cursor:false`.

Example for a smooth 1080p 60 FPS LAN stream:

```bash
./build/odysseus \
  -port:8080 \
  -fps:60 \
  -width:1920 \
  -height:1080 \
  -bitrate:16000 \
  -encoder:h264_nvenc
```

Suggested settings:

| Preset            |        Resolution | FPS |    Bitrate |
| ----------------- | ----------------: | --: | ---------: |
| Low bandwidth     |          1280×720 |  30 |   3–5 Mbps |
| Balanced          |         1920×1080 |  30 |  6–10 Mbps |
| Smooth            |         1920×1080 |  60 | 12–20 Mbps |
| Text / UI quality | Native resolution |  30 | 10–25 Mbps |

Actual bitrate requirements depend on desktop motion, monitor resolution, and
network quality.

## Encoders

Odysseus should prefer a hardware encoder when supported by the host system.

Possible FFmpeg encoder names include:

```text
h264_nvenc       NVIDIA GPU
h264_qsv         Intel Quick Sync
h264_amf         AMD GPU
h264_videotoolbox macOS hardware encoder
h264_vaapi       Linux VAAPI
libx264          Software fallback
```

Check which encoders are available:

```bash
ffmpeg -encoders | grep 264
```

On Windows PowerShell:

```powershell
ffmpeg -encoders | Select-String 264
```

For interactive screen sharing, use low-latency encoder settings:

- H.264 codec
- 30 or 60 FPS
- short keyframe interval, around 1–2 seconds
- no B-frames when low latency is preferred
- frame dropping instead of queueing old frames
- hardware encoding where possible

## Network Notes

Odysseus is intended for a local network.

- The host computer must allow incoming connections on the configured HTTP port.
- Devices must be able to reach each other directly.
- Guest Wi-Fi networks may block device-to-device traffic.
- VPNs, client isolation, or restrictive firewalls can prevent WebRTC negotiation.
- No public STUN or TURN server is needed for normal LAN usage.

If Windows Firewall asks for permission, allow Odysseus on private networks.

## Project Structure

```text
Odysseus/
├── main.odin                 Application entry point
├── build.ps1                 Compiles into build/
├── build/                    Exe + runtime DLLs (created by build.ps1)
├── src/
│   ├── core/                 Platform-specific screen capture, FFmpeg Encoding, ...
│   ├── network/              WebRTC peer connection and media handling
│   ├── server/               Routes and local web server
│   ├── utils/                CLI flags and configuration and utils
│   ├── web/
│       ├── odysseus/              Browser viewer page
│       │   ├── index.html
│       │   ├── app.js
│       │   └── style.css
│       └── assets/              Probably not needed
├── vendor/
│   ├── ffmpeg/               FFmpeg 8.x Odin bindings + vendored win64 libs/DLLs
│   └── libdatachannel/       libdatachannel C API bindings + vendored win64 libs/DLLs
└── README.md
```

## Development Goals

- [x] Windows screen capture support
- [x] FFmpeg H.264 encoding through Odin C interop
- [x] Hardware encoder detection
- [x] WebRTC signaling server
- [x] Browser viewer at `/odysseus`
- [x] Mouse cursor capture
- [ ] Configurable monitor selection
- [ ] Linux PipeWire capture support (LATER)
- [ ] macOS ScreenCaptureKit support (LATER)
- [ ] Audio streaming (LATER)
- [ ] Remote input support, optionally (LATER)

## Why WebRTC Instead of Raw WebSockets?

Sending screen frames directly over WebSockets often requires the browser to
manually decode images or video data and draw them to a canvas. This can add CPU
usage, latency, buffering, and poor frame rates.

WebRTC allows the browser to use its optimized media pipeline:

```text
Encoded H.264 video
  → browser hardware decoder
  → HTML video element
```

This makes 30 FPS and 60 FPS streaming substantially more realistic than a
JPEG/PNG-over-WebSocket approach.

## License

MIT License
