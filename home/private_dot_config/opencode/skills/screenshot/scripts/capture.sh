#!/usr/bin/env bash
# capture.sh — take a full-screen screenshot on GNOME/Wayland.
#
# Why this detour: GNOME does not implement wlr-screencopy (grim's
# requirement) and blocks org.gnome.Shell.Screenshot for foreign callers, so
# the working path is the freedesktop screenshot portal (interactive=false →
# silent capture). Observed on this machine (systemd 259, GNOME portal): the
# portal writes the PNG into ~/Pictures but emits no org.freedesktop.portal.
# Request::Response signal, so completion is detected by polling Pictures for
# a new file instead of waiting on D-Bus.
#
# usage: bash capture.sh [OUTPUT.png]   (default: timestamped under /tmp/opencode/)
set -Eeuo pipefail

fail() { printf 'capture: %s\n' "$*" >&2; exit 1; }

out="${1:-/tmp/opencode/screenshot-$(date +%Y%m%d-%H%M%S).png}"
mkdir -p "$(dirname -- "$out")"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

command -v gdbus >/dev/null || fail "gdbus not found"
[[ -S "${XDG_RUNTIME_DIR}/bus" ]] || fail "no session D-Bus (is a graphical session running?)"

pictures="$(xdg-user-dir PICTURES 2>/dev/null || true)"
[[ -d "${pictures:-}" ]] || pictures="$HOME/Pictures"
[[ -d "$pictures" ]] || fail "no Pictures directory at $pictures"

marker=$(mktemp)
touch -- "$marker"
trap 'rm -f "$marker"' EXIT

gdbus call --session --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Screenshot.Screenshot '' \
  "{'interactive': <false>}" >/dev/null \
  || fail "portal request failed (is xdg-desktop-portal running?)"

# Newest PNG created after the marker is our capture. The portal creates the
# file first and GNOME fills it asynchronously, so wait for a non-zero,
# stable size before copying. (Concurrent manual screenshots could race;
# acceptable on a single-user workstation.)
for _ in $(seq 1 15); do
  candidate=$(find "$pictures" -maxdepth 1 -name '*.png' -newer "$marker" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  if [[ -n "$candidate" ]]; then
    prev=-1
    for _ in $(seq 1 20); do
      size=$(stat -c '%s' -- "$candidate")
      [[ "$size" == "$prev" && "$size" -gt 0 ]] && break
      prev=$size
      sleep 0.5
    done
    cp -- "$candidate" "$out"
    printf '%s\n' "$out"
    exit 0
  fi
  sleep 1
done
fail "no screenshot appeared in $pictures within 15s (a portal permission dialog may need approving)"
