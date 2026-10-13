#!/usr/bin/env bash
# modules/apt.sh — converge declared apt repositories and packages.
# Presence-only: does not remove, downgrade, or upgrade packages.
#
# A group manifest lists packages, one per line, and may bind third-party
# repositories with `repo = <name>` lines. Each repo is a pair of committed
# convention files under packages/apt/repos/:
#   <name>.sources  → /etc/apt/sources.list.d/<name>.sources (byte-exact)
#   <name>.key.asc  → /usr/share/keyrings/<name>-archive-keyring.gpg (dearmored)
# The .sources file is authored to reference that fixed keyring path.
set -Eeuo pipefail

fail() {
  printf 'apt module: %s\n' "$*" >&2
  exit 1
}

check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
  shift
fi
((EUID == 0 || check_only == 1)) || fail "run this module as root (or use --check)"
(($# > 0)) || fail "provide at least one package group"

module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$module_dir/.." && pwd)
declare -a packages=() repos=()

for group in "$@"; do
  [[ "$group" =~ ^[a-z][a-z0-9-]*$ ]] || fail "invalid group: $group"
  manifest="$repo_root/packages/apt/$group.txt"
  [[ -r "$manifest" ]] || fail "missing manifest: $group"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^repo\ =\ ([a-z][a-z0-9-]*)$ ]]; then
      repos+=("${BASH_REMATCH[1]}")
      continue
    fi
    [[ "$line" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] ||
      fail "invalid package entry in $group: $line"
    packages+=("$line")
  done < "$manifest"
done

(( ${#packages[@]} > 0 || ${#repos[@]} > 0 )) ||
  fail "selected groups contain no packages or repos"
declare -a unique=()
mapfile -t unique < <(printf '%s\n' "${packages[@]}" | LC_ALL=C sort -u)
if ((${#repos[@]} > 0)); then
  mapfile -t repos < <(printf '%s\n' "${repos[@]}" | LC_ALL=C sort -u)
fi

# Repo files are converged before packages: a package may exist only once its
# repo is declared. Sets apt_dirty (files written) / repo_drift (check mode).
apt_dirty=0
repo_drift=0
converge_repo() {
  local name=$1
  local sources_src="$repo_root/packages/apt/repos/$name.sources"
  local key_src="$repo_root/packages/apt/repos/$name.key.asc"
  local sources_dst="/etc/apt/sources.list.d/$name.sources"
  local keyring_dst="/usr/share/keyrings/$name-archive-keyring.gpg"
  [[ -r "$sources_src" ]] || fail "repo '$name': missing repos/$name.sources"
  [[ -r "$key_src" ]] || fail "repo '$name': missing repos/$name.key.asc"

  local tmpd key_tmp
  tmpd=$(mktemp -d)
  key_tmp="$tmpd/keyring.gpg"
  # Hermetic homedir; dearmor is pure packet decoding, so the rendering is
  # byte-stable and comparable against the installed keyring.
  gpg --homedir "$tmpd" --batch --quiet --yes --dearmor \
    --output "$key_tmp" < "$key_src" ||
    fail "repo '$name': dearmoring repos/$name.key.asc failed"

  if ! cmp -s "$key_tmp" "$keyring_dst" 2>/dev/null; then
    if ((check_only == 1)); then
      printf 'apt: repo %s — keyring missing or drifted\n' "$name" >&2
      repo_drift=1
    else
      install -D -m 0644 "$key_tmp" "$keyring_dst"
      printf 'apt: repo %s — keyring converged (%s)\n' "$name" "$keyring_dst"
      apt_dirty=1
    fi
  fi
  if ! cmp -s "$sources_src" "$sources_dst" 2>/dev/null; then
    if ((check_only == 1)); then
      printf 'apt: repo %s — sources missing or drifted\n' "$name" >&2
      repo_drift=1
    else
      install -D -m 0644 "$sources_src" "$sources_dst"
      printf 'apt: repo %s — sources converged (%s)\n' "$name" "$sources_dst"
      apt_dirty=1
    fi
  fi
  rm -rf "$tmpd"
}

for name in ${repos[@]+"${repos[@]}"}; do
  converge_repo "$name"
done

declare -a missing=()
for package in "${unique[@]}"; do
  if status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null); then
    [[ "$status" == "install ok installed" ]] || missing+=("$package")
  else
    missing+=("$package")
  fi
done

if ((check_only == 1)); then
  if ((repo_drift == 1)) || ((${#missing[@]} > 0)); then
    ((${#missing[@]} == 0)) ||
      printf 'apt: drift — packages missing: %s\n' "${missing[*]}" >&2
    exit 1
  fi
  printf 'apt: declared repos and packages are converged\n'
  exit 0
fi

if ((${#missing[@]} == 0 && apt_dirty == 0)); then
  printf 'apt: declared repos and packages are present\n'
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
if ((${#missing[@]} > 0)); then
  apt-get "${apt_options[@]}" install -y --no-install-recommends "${missing[@]}"
fi
