#!/usr/bin/env bash
# Starts odysseus with the given flags, points a headless browser at it and
# prints what the browser decoded plus the server log.
#
#   tests/e2e/run.sh [-p port] [-s seconds] [-v viewers] [-a] [-- odysseus flags...]
#
# Environment:
#   ODYSSEUS_EXE   binary to test (default build/odysseus[.exe])
#   VIEWER_ARGS    extra viewer.mjs options (e.g. "--screenshot shot.png")
#   E2E_XVFB=1     Linux: run against a private Xvfb display showing a moving test pattern
#   E2E_HOLD=N     do not start a viewer; keep the server up for N seconds instead
#                  (the viewer runs elsewhere, e.g. on the Windows side of WSL)
#
# Exit code: 0 when frames were decoded AND the server survived the viewer leaving.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
port=8097
seconds=5
viewers=1
audio=""
while [ $# -gt 0 ]; do
	case "$1" in
		-p) port="$2"; shift 2 ;;
		-s) seconds="$2"; shift 2 ;;
		-v) viewers="$2"; shift 2 ;;
		-a) audio="--expect-audio"; shift ;;
		--) shift; break ;;
		*) break ;;
	esac
done

exe="${ODYSSEUS_EXE:-$root/build/odysseus}"
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) [ -f "$exe.exe" ] && exe="$exe.exe" ;;
esac
log="$(mktemp)"
helpers=()

cleanup() {
	for pid in ${helpers[@]+"${helpers[@]}"}; do
		kill "$pid" 2>/dev/null
	done
}
trap cleanup EXIT

if [ "${E2E_XVFB:-}" = 1 ]; then
	display=":${E2E_DISPLAY:-99}"
	Xvfb "$display" -screen 0 1280x720x24 -nolisten tcp >/dev/null 2>&1 &
	helpers+=($!)
	export DISPLAY="$display"
	unset WAYLAND_DISPLAY XDG_SESSION_TYPE
	sleep 1
	if command -v ffplay >/dev/null 2>&1; then
		# Something that moves, so every frame differs.
		SDL_AUDIODRIVER=dummy ffplay -loglevel quiet -f lavfi -i "testsrc2=size=1280x720:rate=30" -noborder -left 0 -top 0 >/dev/null 2>&1 &
		helpers+=($!)
		sleep 1
	fi
fi

"$exe" -port:"$port" -log:none "$@" >"$log" 2>&1 &
pid=$!
sleep 1.5

if [ -n "${E2E_HOLD:-}" ]; then
	sleep "$E2E_HOLD"
	viewer=0
else
	# shellcheck disable=SC2086
	node "$root/tests/e2e/viewer.mjs" --url "http://127.0.0.1:$port/odysseus" --seconds "$seconds" --viewers "$viewers" $audio ${VIEWER_ARGS:-}
	viewer=$?
	# The server must still be up after the last viewer disconnected.
	sleep 2
fi

status="$(curl -s -m 3 "http://127.0.0.1:$port/api/status")"
alive=$?
echo "--- /api/status: ${status:-<no answer>}"

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
echo "--- server log"
cat "$log"
rm -f "$log"

if [ "$viewer" -ne 0 ]; then echo "RESULT: FAIL (viewer exit $viewer)"; exit 1; fi
if [ "$alive" -ne 0 ]; then echo "RESULT: FAIL (server died after the viewer left)"; exit 1; fi
echo "RESULT: PASS"
