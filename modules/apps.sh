#!/usr/bin/env bash
# modules/apps.sh — converge per-user applications declared in packages/apps/.
#
# Model:
#   Declaration   packages/apps/<app>.txt      (in Git: version, sha256, source)
#   Artifact      ~/.cache/workstation/apps/   (private cache, not in Git)
#   Install       ~/.local/apps/<app>/<version> + `current` symlink
#   Entry points  ~/.local/bin/<app>, ~/.local/share/applications/<app>.desktop
#
# Convergence: if the versioned install exists with a matching provenance marker,
# the module only repairs entry points. It never removes other apps or versions.
# Runs as the ordinary user; needs no root.
set -Eeuo pipefail

fail() {
  printf 'apps module: %s\n' "$*" >&2
  exit 1
}
note() { printf 'apps: %s\n' "$*"; }

(($# > 0)) || fail "provide at least one app name"
((EUID != 0)) || fail "run as the ordinary user, not root"

check_only=0
[[ "${WORKSTATION_APPS_CHECK:-0}" == 1 ]] && check_only=1

module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$module_dir/.." && pwd)
cache_dir=${WORKSTATION_APP_CACHE:-"$HOME/.cache/workstation/apps"}
apps_root="$HOME/.local/apps"
bin_dir="$HOME/.local/bin"
desktop_dir="$HOME/.local/share/applications"
icon_dir="$HOME/.local/share/icons/hicolor/48x48/apps"

install_app() {
  local app=$1 decl=$2
  local -A f=()
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([a-z0-9_]+)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]] ||
      fail "invalid entry in $app declaration: $line"
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    [[ -z "${f[$key]+x}" ]] || fail "duplicate key '$key' in $app declaration"
    f[$key]=$value
  done < "$decl"

  local required=(name title version binary prefix archive sha256 source)
  for key in "${required[@]}"; do
    [[ -n "${f[$key]:-}" ]] || fail "app '$app' declaration missing key: $key"
  done
  [[ "${f[name]}" == "$app" ]] || fail "app '$app': name key must equal file name"
  [[ "${f[version]}" =~ ^[0-9][0-9a-zA-Z.+-]*$ ]] || fail "app '$app': invalid version"
  [[ "${f[sha256]}" =~ ^[0-9a-f]{64}$ ]] || fail "app '$app': sha256 must be 64 hex chars"
  [[ "${f[archive]}" != */* ]] || fail "app '$app': archive must be a bare file name"

  local app_dir="$apps_root/$app"
  local dest="$app_dir/${f[version]}"
  local provenance="sha256=${f[sha256]}"

  # Convergence: matching provenance means the artifact was already verified
  # and installed; repair entry points and stop.
  if [[ -x "$dest/${f[binary]}" && "$(cat -- "$dest/.provenance" 2>/dev/null || true)" == "$provenance" ]]; then
    note "$app ${f[version]}: already installed"
  elif ((check_only == 1)); then
    fail "app '$app': drift — version ${f[version]} not installed"
  else
    local archive="$cache_dir/${f[archive]}"
    [[ -r "$archive" ]] || fail \
"app '$app': archive not found: $archive
  Place the artifact obtained from ${f[source]} there, then rerun.
  (Archives are kept out of Git; the declaration pins them by sha256.)"

    note "$app: verifying sha256 of ${f[archive]}"
    local actual
    actual=$(sha256sum -- "$archive" | cut -d' ' -f1)
    [[ "$actual" == "${f[sha256]}" ]] ||
      fail "app '$app': sha256 mismatch
  expected ${f[sha256]}
  actual   $actual
  Refusing to install."

    note "$app ${f[version]}: extracting"
    mkdir -p -- "$app_dir"
    rm -rf -- "$dest"
    local tmp
    tmp=$(mktemp -d -- "$app_dir/.tmp.XXXXXX")
    case "${f[archive]}" in
      *.zip) unzip -q -- "$archive" -d "$tmp" ;;
      *.tar.gz | *.tgz) tar -xzf "$archive" -C "$tmp" ;;
      *) fail "app '$app': unsupported archive type: ${f[archive]}" ;;
    esac
    if [[ "${f[prefix]}" == "." ]]; then
      # Payload at the archive root (e.g. VSCodium tarballs): tmp itself is
      # the install tree, and it lives in $app_dir, so rename it into place.
      mv -- "$tmp" "$dest"
    else
      [[ -d "$tmp/${f[prefix]}" ]] || fail "app '$app': archive has no top-level '${f[prefix]}/'"
      mv -- "$tmp/${f[prefix]}" "$dest"
      rmdir -- "$tmp" 2>/dev/null || rm -rf -- "$tmp"
    fi
    [[ -x "$dest/${f[binary]}" ]] || chmod +x -- "$dest/${f[binary]}"
    printf '%s\n' "$provenance" > "$dest/.provenance"
  fi

  # current -> versioned install
  if ((check_only == 1)); then
    [[ "$(readlink -- "$app_dir/current" 2>/dev/null || true)" == "${f[version]}" ]] ||
      fail "app '$app': drift — $app_dir/current does not point at ${f[version]}"
  else
    ln -sfn -- "${f[version]}" "$app_dir/current"
  fi

  # shell launcher
  if ((check_only == 1)); then
    [[ "$(readlink -- "$bin_dir/$app" 2>/dev/null || true)" == "$app_dir/current/${f[binary]}" ]] ||
      fail "app '$app': drift — launcher $bin_dir/$app missing or incorrect"
  else
    mkdir -p -- "$bin_dir"
    ln -sfn -- "$app_dir/current/${f[binary]}" "$bin_dir/$app"
  fi

  # desktop entry and icon
  if [[ "${f[desktop]:-false}" == "true" ]]; then
    if ((check_only == 1)); then
      [[ -f "$desktop_dir/$app.desktop" ]] ||
        fail "app '$app': drift — desktop entry missing"
    else
      mkdir -p -- "$desktop_dir"
      if [[ -n "${f[icon]:-}" && -f "$dest/${f[icon]}" ]]; then
        mkdir -p -- "$icon_dir"
        install -m 0644 -- "$dest/${f[icon]}" "$icon_dir/$app.png"
      fi
      cat > "$desktop_dir/$app.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${f[title]}
Comment=Web browser (${f[version]}, managed by workstation apps module)
Exec=$bin_dir/$app %U
Icon=$app
Terminal=false
Categories=Network;WebBrowser;
StartupWMClass=chromium-browser
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF
      update-desktop-database -- "$desktop_dir" 2>/dev/null || true
    fi
  fi

  # runtime library check (declared capability must actually load). Guarded:
  # ldd exits 1 on script launchers ("not a dynamic executable"), and with
  # pipefail that would abort the module; only "not found" lines matter.
  local missing
  missing=$(ldd "$dest/${f[binary]}" 2>/dev/null | awk '/not found/{print $1}' | sort -u) || true
  [[ -z "$missing" ]] ||
    fail "app '$app': shared libraries missing at runtime: $missing"

  # AppArmor profile for the userns sandbox (Ubuntu 23.10+ restricts userns
  # creation for unconfined binaries; see the app declaration). The module
  # generates the profile content; installation is a declared root step, and
  # the smoke test below provides functional verification.
  local profile_name="workstation-$app"
  local profile_generated="$cache_dir/apparmor/$profile_name"
  local profile_installed="/etc/apparmor.d/$profile_name"
  if [[ "${f[apparmor]:-false}" == "true" ]]; then
    local profile_render=$profile_generated
    ((check_only == 1)) && profile_render=$(mktemp)
    mkdir -p -- "$(dirname -- "$profile_render")"
    cat > "$profile_render" <<EOF
# Generated by workstation modules/apps.sh. Install as:
#   sudo install -m 0644 '$profile_generated' '/etc/apparmor.d/$profile_name'
#   sudo apparmor_parser -r '/etc/apparmor.d/$profile_name'
abi <abi/5.0>,
include <tunables/global>

profile $profile_name $HOME/.local/apps/$app/*/${f[binary]} flags=(unconfined) {
  userns,

  include if exists <local/$profile_name>
}
EOF
    if ((check_only == 1)); then
      if [[ ! -f "$profile_installed" ]]; then
        rm -f -- "$profile_render"
        fail "app '$app': drift — AppArmor profile not installed. Apply:
  sudo install -m 0644 \"$profile_generated\" \"$profile_installed\"
  sudo apparmor_parser -r \"$profile_installed\""
      elif ! cmp -s -- "$profile_render" "$profile_installed"; then
        rm -f -- "$profile_render"
        fail "app '$app': drift — installed $profile_installed differs from generated content; reinstall the profile and rerun apparmor_parser"
      fi
      rm -f -- "$profile_render"
      note "$app: AppArmor profile installed and current"
    else
      note "$app: AppArmor profile generated at $profile_generated"
    fi
  fi

  # Functional evidence: run the app's own declared smoke command through its
  # real launcher. $APP is the launcher path, $VERSION the declared version.
  if [[ "${f[smoke]:-false}" == "true" ]]; then
    [[ -n "${f[smoke_cmd]:-}" ]] ||
      fail "app '$app': smoke = true requires a smoke_cmd key"
    local out rc=0
    out=$(APP="$bin_dir/$app" VERSION="${f[version]}" timeout 60 \
      bash -c "${f[smoke_cmd]}" 2>&1) || rc=$?
    if ((rc != 0)); then
      printf 'apps: %s: smoke test failed (exit %s):\n' "$app" "$rc" >&2
      printf '%s\n' "$out" | head -5 >&2
      if [[ "${f[apparmor]:-false}" == "true" && ! -e "/etc/apparmor.d/$profile_name" ]]; then
        printf 'apps: %s: likely cause: no AppArmor profile installed. Apply:\n' "$app" >&2
        printf '  sudo install -m 0644 "%s" "/etc/apparmor.d/%s"\n  sudo apparmor_parser -r "/etc/apparmor.d/%s"\n' \
          "$profile_generated" "$profile_name" "$profile_name" >&2
      fi
      return 1
    fi
    note "$app: smoke test passed"
  fi

  note "$app ${f[version]}: converged ($bin_dir/$app)"
}

for app in "$@"; do
  [[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || fail "invalid app name: $app"
  decl="$repo_root/packages/apps/$app.txt"
  [[ -r "$decl" ]] || fail "missing app declaration: packages/apps/$app.txt"
  install_app "$app" "$decl"
done
