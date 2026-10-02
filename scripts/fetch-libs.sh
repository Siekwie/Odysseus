#!/usr/bin/env bash
# Builds libdatachannel from source for Linux / macOS into
# vendor/libdatachannel/lib, for systems whose package manager has no
# (or too old a) libdatachannel. build.sh picks the result up automatically.
#
# FFmpeg is not built here: install your distribution's FFmpeg development
# packages (or `brew install ffmpeg`).
#
# Needs: git, cmake, a C++17 compiler, OpenSSL development files
# (macOS: `brew install cmake openssl@3`).
set -euo pipefail

version="${LIBDATACHANNEL_VERSION:-v0.24.5}"
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/vendor/libdatachannel/upstream"
build="$root/vendor/libdatachannel/build-unix"
lib="$root/vendor/libdatachannel/lib"

if [ ! -f "$src/CMakeLists.txt" ]; then
	echo "Cloning libdatachannel $version..."
	git clone --depth 1 --branch "$version" --recursive https://github.com/paullouisageneau/libdatachannel.git "$src"
fi

cmake_args=()
if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
	# Homebrew's OpenSSL is keg-only; CMake does not find it by itself.
	openssl_dir="$(brew --prefix openssl@3 2>/dev/null || true)"
	[ -d "$openssl_dir" ] && cmake_args+=("-DOPENSSL_ROOT_DIR=$openssl_dir")
fi

echo "Building libdatachannel..."
cmake -S "$src" -B "$build" ${cmake_args[@]+"${cmake_args[@]}"} \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=ON \
	-DUSE_GNUTLS=OFF -DUSE_NICE=OFF \
	-DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON \
	-DENABLE_WARNINGS_AS_ERRORS=OFF
cmake --build "$build" --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

mkdir -p "$lib"
# Copy the library together with its version symlinks.
find "$build" -maxdepth 1 \( -name 'libdatachannel.so*' -o -name 'libdatachannel*.dylib' \) -exec cp -a {} "$lib/" \;
found=0
for f in "$lib"/libdatachannel.so* "$lib"/libdatachannel*.dylib; do
	[ -e "$f" ] && { echo "$f"; found=1; }
done
[ "$found" = 1 ] || { echo "no library produced" >&2; exit 1; }
echo "libdatachannel is in vendor/libdatachannel/lib"
