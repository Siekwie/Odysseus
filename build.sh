#!/usr/bin/env bash
# Builds Odysseus on Linux and macOS into build/odysseus.
#
#   ./build.sh            optimized build
#   ./build.sh debug      debug build (no optimization, debug info)
#   ./build.sh test       unit tests (tests/run.sh)
#   ./build.sh check      type-check every supported target without linking
#
# Needs: the Odin compiler, pkg-config, a C compiler, FFmpeg 6-9 development
# files (libavcodec, libavutil, libswscale, libavformat, libavdevice) and
# libdatachannel 0.20+ (from the system or from scripts/fetch-libs.sh).
# Optional: PipeWire + GLib development files (Linux; Wayland capture and
# portal remote input). On macOS the ScreenCaptureKit backend is built with
# the Xcode command line tools.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
cd "$root"
mode="${1:-release}"
os="$(uname -s)"
out="build/odysseus"
native_dir="build/native"

die() { echo "build.sh: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

case "$mode" in
	test)
		exec bash tests/run.sh
		;;
	check)
		for target in windows_amd64 linux_amd64 linux_arm64 darwin_amd64 darwin_arm64 freebsd_amd64; do
			echo "check $target"
			odin check . -target:"$target"
		done
		odin check . -target:linux_amd64 -define:ODYSSEUS_PIPEWIRE=true
		odin check . -target:darwin_arm64 -define:ODYSSEUS_SCK=true
		exit 0
		;;
	release | debug) ;;
	*) die "unknown mode '$mode' (release, debug, test, check)" ;;
esac

have odin || die "the Odin compiler is not on PATH (https://odin-lang.org/docs/install/)"
have pkg-config || die "pkg-config is required"
cc="${CC:-cc}"
have "$cc" || die "no C compiler found (set CC)"
pkg-config --exists libavcodec libavutil libswscale libavformat libavdevice ||
	die "FFmpeg development files not found (libavcodec, libavutil, libswscale, libavformat, libavdevice)"

mkdir -p "$native_dir"
defines=()
native_objects=()
linker_flags="$(bash scripts/link-flags.sh)"

case "$os" in
	Linux)
		pw_modules="libpipewire-0.3 gio-2.0 gio-unix-2.0"
		if pkg-config --exists $pw_modules; then
			echo "PipeWire capture: enabled"
			# shellcheck disable=SC2046
			"$cc" -O2 -Wall -Wextra -fPIC -c src/native/pipewire_capture.c -o "$native_dir/pipewire_capture.o" $(pkg-config --cflags $pw_modules)
			native_objects+=("$native_dir/pipewire_capture.o")
			defines+=("-define:ODYSSEUS_PIPEWIRE=true")
			linker_flags="$linker_flags $(pkg-config --libs $pw_modules)"
		else
			echo "PipeWire capture: disabled (no development files for: $pw_modules)"
		fi
		;;
	Darwin)
		if xcrun --show-sdk-path >/dev/null 2>&1; then
			echo "ScreenCaptureKit capture: enabled"
			clang -O2 -fobjc-arc -mmacosx-version-min=12.3 -Wall -c src/native/sck_capture.m -o "$native_dir/sck_capture.o"
			native_objects+=("$native_dir/sck_capture.o")
			defines+=("-define:ODYSSEUS_SCK=true")
			linker_flags="$linker_flags -weak_framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework Foundation"
		else
			echo "ScreenCaptureKit capture: disabled (Xcode command line tools not found)"
		fi
		;;
esac

if [ "${#native_objects[@]}" -gt 0 ]; then
	rm -f "$native_dir/libodysseus_native.a"
	ar rcs "$native_dir/libodysseus_native.a" "${native_objects[@]}"
	linker_flags="-L$root/$native_dir $linker_flags"
fi

opt=(-o:speed)
[ "$mode" = debug ] && opt=(-o:none -debug)

# ${arr[@]+...}: empty arrays count as unset under `set -u` in the bash 3.2 that macOS ships.
odin build . -out:"$out" "${opt[@]}" ${defines[@]+"${defines[@]}"} -extra-linker-flags:"$linker_flags"
echo "Built $out"
