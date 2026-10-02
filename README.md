# Odysseus

Odysseus is a low-latency screen sharing application for the local network,
written in [Odin](https://odin-lang.org/).

It captures the host computer's screen and system audio, encodes them with
FFmpeg (H.264 + Opus) and streams them to web browsers over WebRTC. Viewers
need nothing but a browser:

```text
http://<streaming-computer-ip>:8080/odysseus
```

There is no account, no cloud service and no STUN/TURN server involved:
devices that can reach each other on the same network connect directly.

## Features

- Real-time desktop capture on Windows, Linux (X11 and Wayland) and macOS
- H.264 over WebRTC, played by a plain `<video>` element with the browser's hardware decoder
- Hardware encoding where it works (NVENC, AMF, Quick Sync, VAAPI, VideoToolbox, Media Foundation), software fallback (x264 / OpenH264); the first encoder that actually opens is used
- Zero-copy capture → encode on Windows with NVENC (the frame never leaves the GPU; AMF uses the same path but has not been tested on AMD hardware)
- System audio (what the speakers play) as stereo Opus
- Mouse cursor in the stream
- Monitor selection from the command line or from the viewer
- Optional remote control (mouse and keyboard), protected by a password or PIN
- Optional viewing password
- Viewer with auto-hiding overlay, live statistics, fullscreen, mobile layout and automatic reconnect
- Several viewers at once share one capture/encode pipeline; capture runs only while someone is watching

## Platform support

| | Capture | Hardware encode | Audio | Remote control | Status |
| --- | --- | --- | --- | --- | --- |
| **Windows 10/11** | Desktop Duplication (DXGI), GDI fallback | NVENC, AMF, Quick Sync, Media Foundation | WASAPI loopback | `SendInput` | Tested end to end |
| **Linux, X11** | FFmpeg `x11grab` | NVENC, VAAPI, Quick Sync | PulseAudio / PipeWire-Pulse monitor | XTest | Tested end to end |
| **Linux, Wayland** | xdg-desktop-portal + PipeWire | NVENC, VAAPI, Quick Sync | PulseAudio / PipeWire-Pulse monitor | RemoteDesktop portal (GNOME, KDE) | Capture tested on wlroots (sway); portal input untested |
| **macOS 12.3+** | AVFoundation (default), ScreenCaptureKit (`-capture:screencapturekit`) | VideoToolbox | ScreenCaptureKit system audio (macOS 13+) | CoreGraphics events | Builds in CI; not yet run on real hardware |

On Linux, Intel and AMD GPUs encode through VAAPI (needs FFmpeg 8 or 9 on
x86-64). That path shares its code with a CUDA-pool variant that is tested,
but it has not been run on VAAPI hardware; if it fails to open or to encode,
Odysseus moves on to the next encoder by itself.

## Quick start

### Windows

FFmpeg 8.1 (BtbN `win64-gpl-shared`) and libdatachannel are vendored under
`vendor/`, so the only thing to install is the
[Odin compiler](https://odin-lang.org/docs/install/).

```powershell
git clone https://github.com/Siekwie/Odysseus.git
cd Odysseus
.\build.ps1
.\build\odysseus.exe
```

If Windows Firewall asks, allow Odysseus on private networks.

### Linux

Install Odin, FFmpeg (6, 7, 8 or 9) with development files, and libdatachannel
0.20 or newer. PipeWire and GLib development files are optional and enable
Wayland capture.

```bash
# Arch
sudo pacman -S odin ffmpeg libdatachannel pipewire pkgconf clang

# Debian / Ubuntu (libdatachannel is built from source by fetch-libs.sh)
sudo apt install clang pkg-config cmake libssl-dev ffmpeg libavcodec-dev libavformat-dev \
  libavdevice-dev libavutil-dev libswscale-dev libpipewire-0.3-dev libglib2.0-dev
./scripts/fetch-libs.sh

./build.sh
./build/odysseus
```

At run time the X11 libraries (`libX11`, `libXrandr`, `libXtst`) and
`libpulse` are loaded only if present; none of them is required.

On Wayland the desktop asks which screen to share the first time a viewer
connects. The choice is remembered, so it asks only once. If you decline, or
stop the share from the desktop, viewers are told and cannot trigger the
dialog again for 30 seconds.

### macOS

```bash
brew install odin ffmpeg pkg-config cmake openssl@3
./scripts/fetch-libs.sh        # builds libdatachannel (Homebrew has no formula for it)
./build.sh
./build/odysseus
```

macOS asks for the **Screen Recording** permission on first use (and for
**Accessibility** when started with `-input`). Grant it to the terminal you
start Odysseus from. System audio needs macOS 13 or newer.

## Usage

Start Odysseus on the computer whose screen should be shared. It prints the
addresses viewers can open:

```text
19:05:45 info   Odysseus 1.0.0 (libavcodec 62, libavutil 60)
19:05:45 info   open http://192.168.2.178:8080/odysseus
```

Open that address in a browser on another device. The viewer starts playing
as soon as the connection is up. Move the pointer (or tap) to bring up the
overlay; the button in the lower right opens the settings:

- **Monitor**: switch the captured monitor (applies to every viewer)
- **Show overlay** / **Show statistics**: what is drawn over the video (remembered per browser)
- **Fullscreen**, **Unmute**
- **Remote control**: only when the host was started with `-input`

Keyboard shortcuts: `O` overlay, `S` statistics, `F` fullscreen, `M` sound.
While controlling the host, every key goes to the host; `Ctrl+Alt+Shift+Q`
releases control.

Any modern browser with WebRTC and H.264 works: Chrome, Edge, Safari, and
Firefox (which may need its OpenH264 plugin enabled).

## Configuration

Flags use Odin style, `-name:value`. Run `odysseus -help` for the full list.

| Flag | Default | Meaning |
| --- | --- | --- |
| `-port:8080` | 8080 | HTTP port |
| `-bind:<address>` | all IPv4 interfaces | Listen address; also used for WebRTC |
| `-monitor:<n>` | 0 | Monitor to capture; see `-list-monitors` |
| `-fps:<n>` | 30 | Capture and encode rate |
| `-bitrate:<kbps>` | 8000 | Video bitrate |
| `-width:<px>` `-height:<px>` | 0 (native) | Output size. Set one to keep the aspect ratio. Scaling runs on the CPU and disables the zero-copy path |
| `-encoder:<name>` | `h264` | `h264` picks the best working encoder; or name an FFmpeg encoder such as `h264_nvenc`, `libx264` |
| `-capture:<backend>` | `auto` | `dxgi`, `gdigrab`, `x11`, `pipewire`, `avfoundation`, `screencapturekit` |
| `-cursor:false` | on | Leave the mouse cursor out of the stream |
| `-audio:false` | on | Do not stream audio |
| `-audio-device:<name>` | default output | Capture another device (substring of its name; a PulseAudio source name on Linux) |
| `-audio-bitrate:<kbps>` | 128 | Opus bitrate |
| `-password:<text>` | none | Viewers must enter this password |
| `-input` | off | Allow remote control (see below) |
| `-max-viewers:<n>` | 8 | Concurrent viewers |
| `-max-http:<n>` | 64 | Concurrent HTTP connections |
| `-host-name:<names>` | none | Extra host names accepted in the URL (comma separated) |
| `-log:<path>` | `odysseus.log` next to the executable | `none` disables the log file |
| `-verbose` | off | Debug output, including FFmpeg and WebRTC library messages |
| `-list-monitors` | | Print the monitors and exit |
| `-list-encoders` | | Probe which H.264 encoders work on this machine and exit |

Example for a smooth 1080p60 stream:

```bash
./build/odysseus -fps:60 -height:1080 -bitrate:16000
```

Suggested bitrates:

| Preset | Resolution | FPS | Bitrate |
| --- | ---: | --: | ---: |
| Low bandwidth | 1280×720 | 30 | 3–5 Mbps |
| Balanced | 1920×1080 | 30 | 6–10 Mbps |
| Smooth | 1920×1080 | 60 | 12–20 Mbps |
| Text / UI quality | native | 30 | 10–25 Mbps |

When the screen is static Odysseus sends almost nothing: frames are encoded
when the desktop changes, briefly afterwards so a still image sharpens, and
once a second as a keepalive.

## Remote control

`-input` lets viewers move the mouse and type on the host. Because that hands
over the machine, it is never open to everyone on the network:

- with `-password:<text>`, the viewing password also unlocks control;
- without one, Odysseus prints a six-digit PIN at startup and the viewer asks
  for it when "Remote control" is switched on.

Five wrong attempts close the connection. Keys and buttons held by a viewer
are released when that viewer disconnects.

On Wayland, remote control goes through the desktop's RemoteDesktop portal
(GNOME and KDE have it; wlroots compositors do not).

## Security notes

Odysseus is meant for a network you trust.

- Traffic to the page and the signaling WebSocket is plain HTTP; the media
  itself is encrypted by WebRTC (DTLS-SRTP), but a password or PIN can be read
  by anyone who can sniff the network. Do not expose the port to the internet.
- The signaling socket only accepts same-origin requests, and the server only
  answers to IP addresses, `localhost`, the machine's own name and names given
  with `-host-name`. This keeps websites you visit on a viewer device from
  reaching an Odysseus host behind your back (cross-site WebSocket hijacking,
  DNS rebinding).
- Anyone who can open the page can watch unless `-password` is set.

## Network notes

- The host must accept incoming TCP on the HTTP port and UDP for WebRTC.
- Guest Wi-Fi with client isolation, VPNs and strict firewalls can prevent the
  direct connection WebRTC needs. No STUN or TURN server is used.

## How it works

```text
capture backend ─► (BGRA frame or GPU texture)
  ─► swscale to NV12 / zero-copy D3D11        src/core
  ─► FFmpeg H.264 encoder ─► AVCC access units
  ─► libdatachannel RTP packetizer ─► WebRTC   src/network
  ─► browser <video>

system audio ─► 20 ms frames ─► libopus ─► WebRTC audio track   src/audio
```

WebSockets carry only signaling (SDP, ICE candidates, monitor switches, input
events); see `src/network/signaling.odin` for the protocol.

```text
Odysseus/
├── main.odin, signaling.odin   Entry point and signaling handlers
├── build.ps1 / build.sh        Build scripts (release, debug, test, check)
├── scripts/                    fetch-libs.ps1 / fetch-libs.sh, link-flags.sh
├── src/
│   ├── core/                   Capture backends, encoders, H.264 bitstream helpers
│   ├── audio/                  System audio capture and Opus encoding
│   ├── input/                  Remote input backends and key map
│   ├── network/                WebRTC peer, SDP parsing, signaling messages
│   ├── server/                 HTTP server and WebSocket
│   ├── stream/                 The capture → encode → send session
│   ├── utils/                  Configuration, logging, crash and shutdown handling
│   ├── native/                 C / Objective-C shims (PipeWire portal, ScreenCaptureKit)
│   └── web/odysseus/           Viewer page (embedded into the executable)
├── tests/                      Unit test runner and headless end-to-end tests
└── vendor/                     FFmpeg and libdatachannel bindings (+ Windows binaries)
```

## Development

```bash
./build.sh test          # unit tests            (.\build.ps1 test on Windows)
./build.sh check         # type-check all targets without linking
bash tests/e2e/run.sh -- -monitor:1          # headless browser against a real capture
E2E_XVFB=1 bash tests/e2e/run.sh             # Linux: private X server with a test pattern
bash tests/e2e/wayland.sh                    # Linux: headless sway + portal + PipeWire
```

The end-to-end tests start Odysseus, drive a headless Chrome or Edge through
the DevTools protocol (Node 22+, no npm packages) and check what the browser
actually decoded.

FFmpeg's struct layouts differ between releases. The bindings in
`vendor/ffmpeg` therefore configure codecs through AVOptions only and keep the
few unavoidable offsets in `vendor/ffmpeg/abi.odin`, checked against the
running library at startup.

To update the vendored Windows libraries see `scripts/fetch-libs.ps1`.

## Troubleshooting

- **Black or frozen picture, "Waiting for the host…"**: run with `-verbose`
  and check `-list-encoders`; try `-encoder:libx264`.
- **No picture on Wayland**: the portal dialog may be waiting on the host's
  screen. `ODYSSEUS_PW_DEBUG=1` prints each portal and PipeWire step.
- **Viewer says "This browser has no H.264 decoder"**: enable OpenH264 in
  Firefox's add-on settings, or use another browser.
- **No sound**: the video starts muted because browsers require it for
  autoplay; press "Unmute". On Linux check that `pactl info` works.
- **"Odysseus does not answer to this host name"**: open the page by IP
  address or start the host with `-host-name:<name>`.

## License

MIT License
