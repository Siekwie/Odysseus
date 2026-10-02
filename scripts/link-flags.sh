#!/usr/bin/env bash
# Prints the linker search-path flags for the native libraries Odysseus links
# on Linux and macOS (FFmpeg and libdatachannel). Used by build.sh and
# tests/run.sh; run it from anywhere.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
flags=""

ffmpeg_modules="libavcodec libavutil libswscale libavformat libavdevice"
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists $ffmpeg_modules; then
	flags="$(pkg-config --libs-only-L $ffmpeg_modules)"
fi

# libdatachannel: a copy built by scripts/fetch-libs.sh wins over the system one.
if ls "$root"/vendor/libdatachannel/lib/libdatachannel.so* "$root"/vendor/libdatachannel/lib/libdatachannel*.dylib >/dev/null 2>&1; then
	flags="$flags -L$root/vendor/libdatachannel/lib -Wl,-rpath,$root/vendor/libdatachannel/lib"
elif command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libdatachannel 2>/dev/null; then
	flags="$flags $(pkg-config --libs-only-L libdatachannel)"
elif [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
	# Homebrew's libdatachannel ships no .pc file.
	flags="$flags -L$(brew --prefix)/lib"
fi

echo "$flags"
