#!/usr/bin/env bash
# Runs the unit tests of every package that has *_test.odin files.
#
#   tests/run.sh                 all packages
#   tests/run.sh core server     only these (names under src/)
#   ODIN_TEST_NAMES=core.test_h264_x tests/run.sh core    only matching tests
#   ODIN_FLAGS="-debug" tests/run.sh                       extra flags for `odin test`
#
# Exit code: 0 when every package compiled and passed, 1 otherwise. Leaked
# memory in a test counts as a failure.
#
# The test binaries are written to build/: on Windows that is where the FFmpeg
# and libdatachannel DLLs live (src/core, src/server and src/network link
# them), so no PATH tricks are needed. On Linux/macOS the libraries come from
# the system.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

if ! command -v odin >/dev/null 2>&1; then
	echo "odin not found on PATH" >&2
	exit 2
fi

exe=""
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) exe=".exe" ;;
esac

mkdir -p build

if [ $# -gt 0 ]; then
	pkgs=("$@")
else
	pkgs=()
	for d in src/*/; do
		d="${d%/}"
		if compgen -G "$d/*_test.odin" >/dev/null; then
			pkgs+=("${d#src/}")
		fi
	done
fi

if [ ${#pkgs[@]} -eq 0 ]; then
	echo "no test packages found" >&2
	exit 2
fi

extra=()
if [ -n "${ODIN_TEST_NAMES:-}" ]; then
	extra+=("-define:ODIN_TEST_NAMES=${ODIN_TEST_NAMES}")
fi
# shellcheck disable=SC2206
[ -n "${ODIN_FLAGS:-}" ] && extra+=(${ODIN_FLAGS})
# Linux/macOS: tell the linker where FFmpeg and libdatachannel live.
if [ -z "$exe" ]; then
	link_flags="$(bash scripts/link-flags.sh 2>/dev/null || true)"
	[ -n "$link_flags" ] && extra+=("-extra-linker-flags:$link_flags")
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

failed_pkgs=()
total=0
total_failed=0
summary=()

for pkg in "${pkgs[@]}"; do
	echo "=== $pkg"
	if [ ! -d "src/$pkg" ]; then
		echo "no such package: src/$pkg" >&2
		failed_pkgs+=("$pkg")
		summary+=("$(printf '%-10s %s' "$pkg" 'missing')")
		continue
	fi
	odin test "src/$pkg" "-out:build/test_$pkg$exe" \
		-define:ODIN_TEST_FANCY=false \
		-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
		${extra[@]+"${extra[@]}"} >"$log" 2>&1
	rc=$?
	cat "$log"

	# "Finished 42 tests in 15.7ms. All tests were successful."
	# "Finished 87 tests in 336ms. 2 tests failed."
	line="$(grep -E '^Finished [0-9]+ tests? in ' "$log" | tail -1)"
	n="$(sed -n 's/^Finished \([0-9][0-9]*\) tests\{0,1\} in .*/\1/p' <<<"$line")"
	f="$(sed -n 's/.* \([0-9][0-9]*\) tests\{0,1\} failed\..*/\1/p' <<<"$line")"
	n="${n:-0}"
	f="${f:-0}"
	total=$((total + n))
	total_failed=$((total_failed + f))

	if [ $rc -ne 0 ] || [ "$f" -ne 0 ] || [ -z "$line" ]; then
		failed_pkgs+=("$pkg")
		if [ -z "$line" ]; then
			summary+=("$(printf '%-10s %s' "$pkg" 'did not build/run (exit '$rc')')")
		else
			summary+=("$(printf '%-10s %4d tests, %d failed (exit %d)' "$pkg" "$n" "$f" "$rc")")
		fi
	else
		summary+=("$(printf '%-10s %4d tests, 0 failed' "$pkg" "$n")")
	fi
done

echo
echo "=== summary"
printf '%s\n' "${summary[@]}"
echo "total: $total tests, $total_failed failed"

if [ ${#failed_pkgs[@]} -gt 0 ]; then
	echo "FAILED: ${failed_pkgs[*]}"
	exit 1
fi
echo "OK"
