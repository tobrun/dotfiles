#!/usr/bin/env bash
# modules/apt.sh — ensure declared apt packages are present.
# Presence-only: does not remove, downgrade, or upgrade packages.
set -Eeuo pipefail

fail() {
  printf 'apt module: %s\n' "$*" >&2
  exit 1
}

((EUID == 0)) || fail "run this module as root"
(($# > 0)) || fail "provide at least one package group"

module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$module_dir/.." && pwd)
declare -a packages=()

for group in "$@"; do
  [[ "$group" =~ ^[a-z][a-z0-9-]*$ ]] || fail "invalid group: $group"
  manifest="$repo_root/packages/apt/$group.txt"
  [[ -r "$manifest" ]] || fail "missing manifest: $group"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] ||
      fail "invalid package entry in $group: $line"
    packages+=("$line")
  done < "$manifest"
done

((${#packages[@]} > 0)) || fail "selected groups contain no packages"
declare -a unique=()
mapfile -t unique < <(printf '%s\n' "${packages[@]}" | LC_ALL=C sort -u)
declare -a missing=()

for package in "${unique[@]}"; do
  if status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null); then
    [[ "$status" == "install ok installed" ]] || missing+=("$package")
  else
    missing+=("$package")
  fi
done

if ((${#missing[@]} == 0)); then
  printf 'apt: declared packages are present\n'
  exit 0
fi

declare -a apt_options=(-o APT::Update::Error-Mode=any)
if [[ -n "${WORKSTATION_APT_SNAPSHOT:-}" ]]; then
  [[ "$WORKSTATION_APT_SNAPSHOT" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
    fail "invalid snapshot timestamp"
  apt_options+=(-o "APT::Snapshot=$WORKSTATION_APT_SNAPSHOT")
fi

export DEBIAN_FRONTEND=noninteractive
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends "${missing[@]}"
