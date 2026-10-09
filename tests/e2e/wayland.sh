#!/usr/bin/env bash
# Runs odysseus against a throwaway headless Wayland session so the
# portal + PipeWire capture path can be tested without a desktop:
#
#   sway (headless wlroots backend) + pipewire + wireplumber
#   + xdg-desktop-portal + xdg-desktop-portal-wlr (auto-selects the output)
#   + a moving test pattern (ffplay) as the thing to capture
#
#   tests/e2e/wayland.sh [-p port] [-s seconds] [-- odysseus flags...]
#
# With E2E_DENY=1 the portal refuses the share (tests the "host declined" path).
# With E2E_HOLD=N no viewer is started and the server stays up N seconds
# (the viewer runs elsewhere). Needs: sway, pipewire, wireplumber,
# xdg-desktop-portal, xdg-desktop-portal-wlr, dbus, ffplay.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
port=8102
seconds=6
while [ $# -gt 0 ]; do
	case "$1" in
		-p) port="$2"; shift 2 ;;
		-s) seconds="$2"; shift 2 ;;
		--) shift; break ;;
		*) break ;;
	esac
done

work="$(mktemp -d)"
export XDG_RUNTIME_DIR="$work/run"
export XDG_CONFIG_HOME="$work/config"
export XDG_CURRENT_DESKTOP=sway
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/xdg-desktop-portal" "$XDG_CONFIG_HOME/xdg-desktop-portal-wlr" "$XDG_CONFIG_HOME/sway"
chmod 700 "$XDG_RUNTIME_DIR"
unset DISPLAY WAYLAND_DISPLAY

cat >"$XDG_CONFIG_HOME/sway/config" <<'EOF'
output HEADLESS-1 resolution 1280x720 position 0 0
default_border none
EOF
cat >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" <<'EOF'
[preferred]
default=wlr
org.freedesktop.impl.portal.ScreenCast=wlr
EOF
if [ "${E2E_DENY:-}" = 1 ]; then
	# A chooser that picks nothing: the portal answers "cancelled", like a user declining.
	printf '[screencast]
chooser_type=simple
chooser_cmd=false
' >"$XDG_CONFIG_HOME/xdg-desktop-portal-wlr/config"
else
	printf '[screencast]
chooser_type=none
output_name=HEADLESS-1
max_fps=60
' >"$XDG_CONFIG_HOME/xdg-desktop-portal-wlr/config"
fi

inner="$work/inner.sh"
cat >"$inner" <<EOF
#!/usr/bin/env bash
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
sway -c "\$XDG_CONFIG_HOME/sway/config" >"$work/sway.log" 2>&1 &
for _ in \$(seq 50); do [ -S "\$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland
dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR XDG_CONFIG_HOME 2>/dev/null
pipewire >"$work/pipewire.log" 2>&1 &
sleep 0.5
wireplumber >"$work/wireplumber.log" 2>&1 &
sleep 1
/usr/lib/xdg-desktop-portal-wlr -l DEBUG >"$work/portal-wlr.log" 2>&1 &
sleep 0.5
/usr/lib/xdg-desktop-portal >"$work/portal.log" 2>&1 &
sleep 1.5
SDL_VIDEODRIVER=wayland SDL_AUDIODRIVER=dummy ffplay -loglevel quiet -f lavfi -i "testsrc2=size=1280x720:rate=30" -fs >/dev/null 2>&1 &
sleep 1

ODYSSEUS_PW_DEBUG="\${ODYSSEUS_PW_DEBUG:-}" "$root/build/odysseus" -port:$port -log:none "\$@" >"$work/odysseus.log" 2>&1 &
pid=\$!
sleep 1.5
if [ -n "\${E2E_HOLD:-}" ]; then
	sleep "\$E2E_HOLD"; viewer=0
else
	node "$root/tests/e2e/viewer.mjs" --url "http://127.0.0.1:$port/odysseus" --seconds $seconds \${VIEWER_ARGS:-}
	viewer=\$?
	sleep 2
fi
echo "--- /api/status: \$(curl -s -m 3 http://127.0.0.1:$port/api/status)"
kill \$pid 2>/dev/null; wait \$pid 2>/dev/null
echo "--- server log"; cat "$work/odysseus.log"
if [ -n "\${E2E_VERBOSE:-}" ]; then
	for f in portal portal-wlr sway; do echo "--- \$f.log"; tail -25 "$work/\$f.log"; done
fi
kill \$(jobs -p) 2>/dev/null
exit \$viewer
EOF
chmod +x "$inner"

dbus-run-session -- "$inner" "$@"
rc=$?
rm -rf "$work"
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
