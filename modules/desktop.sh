#!/usr/bin/env bash
# modules/desktop.sh — converge GNOME desktop settings declared in
# packages/desktop/<group>.txt via gsettings.
#
# Model:
#   Declaration  packages/desktop/<group>.txt  (in Git: schema, key, value)
#   State        dconf (GNOME settings database, owned by gsettings/dconf)
#
# Each declaration line is `<schema> <key> = <value>` where <value> is exactly
# what `gsettings get` prints (a GVariant literal), so compare and re-set are
# byte-for-byte. Values are converged exactly, not merely present: the desktop
# layer has one owner, so a mismatch means something changed it.
#
# Runs as the ordinary user inside a session bus; needs no root.
set -Eeuo pipefail

fail() {
  printf 'desktop module: %s\n' "$*" >&2
  exit 1
}
note() { printf 'desktop: %s\n' "$*"; }

(($# > 0)) || fail "provide at least one settings group"
((EUID != 0)) || fail "run as the ordinary user, not root"

check_only=0
[[ "${WORKSTATION_DESKTOP_CHECK:-0}" == 1 ]] && check_only=1

command -v gsettings >/dev/null || fail "gsettings not available (GNOME desktop layer?)"
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] ||
  fail "no session D-Bus address in the environment; run inside a graphical/logind session"

module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$module_dir/.." && pwd)

changed=0
drift=0
for group in "$@"; do
  [[ "$group" =~ ^[a-z][a-z0-9-]*$ ]] || fail "invalid group name: $group"
  decl="$repo_root/packages/desktop/$group.txt"
  [[ -r "$decl" ]] || fail "missing settings declaration: packages/desktop/$group.txt"

  line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([a-z0-9][a-z0-9.-]+)[[:space:]]+([a-z0-9][a-zA-Z0-9-]*)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]] ||
      fail "$group.txt:$line_no: expected '<schema> <key> = <GVariant>', got: $line"
    schema=${BASH_REMATCH[1]} key=${BASH_REMATCH[2]} want=${BASH_REMATCH[3]}

    actual=$(gsettings get "$schema" "$key" 2>&1) ||
      fail "$group.txt:$line_no: gsettings get $schema $key failed: $actual"
    [[ "$actual" == "$want" ]] && continue

    if ((check_only == 1)); then
      printf 'desktop: drift — %s %s: declared %s, actual %s\n' \
        "$schema" "$key" "$want" "$actual" >&2
      drift=1
      continue
    fi
    gsettings set "$schema" "$key" "$want"
    verify=$(gsettings get "$schema" "$key")
    [[ "$verify" == "$want" ]] ||
      fail "$schema $key: set did not take effect (read back: $verify)"
    note "$schema $key: converged"
    changed=$((changed + 1))
  done < "$decl"
done

if ((check_only == 1)); then
  ((drift == 0)) && note "declared settings are in effect"
  exit "$drift"
fi
note "settings converged ($changed changed)"
