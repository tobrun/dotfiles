#!/usr/bin/env bash
# docker/acceptance.sh — shared-capability parity checks, host vs image
# (book ch 9 lab: one installation implementation per declaration; every
# intentional host/image difference documented in docker/README.md).
#
# Checks the workstation-agent:local image reproduces what the repository
# declares, comparing against the same declarations the host converged from.
set -Eeuo pipefail

fail() { printf 'acceptance: FAIL %s\n' "$*" >&2; exit 1; }
ok()   { printf 'acceptance: ok %s\n' "$*"; }

module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$module_dir/.." && pwd)
image=${1:-workstation-agent:local}

docker image inspect "$image" >/dev/null 2>&1 ||
  fail "image $image not present; run: bash docker/build.sh agent"

decl_version() { grep -m1 '^version = ' "$repo_root/packages/apps/$1.txt" | sed 's/.*= //'; }

# 1) apt layer: every declared base-group package is installed in the image.
pkgs=$(sed -n 's/^[a-z0-9][a-z0-9+.-]*$/&/p' "$repo_root/packages/apt/base.txt" | tr '\n' ' ')
[[ -n "${pkgs// /}" ]] || fail "no packages parsed from base.txt"
want=$(wc -w <<<"$pkgs")
got=$(docker run --rm --entrypoint bash "$image" -c \
  "dpkg-query -W -f='\${Status}\n' $pkgs 2>/dev/null | grep -cx 'install ok installed'" || true)
[[ "$got" == "$want" ]] || fail "apt layer: only $got/$want declared packages installed"
ok "apt layer: base.txt packages all installed"

# 2) toolchain layer: effective tool versions satisfy toolchains/mise.toml pins.
docker run --rm --entrypoint bash "$image" -c '
  set -e
  python --version
  node --version
  go version
' >/dev/null || fail "tooling layer: a toolchain command failed"
versions=$(docker run --rm --entrypoint bash "$image" -c '
  printf "python=%s\nnode=%s\ngo=%s\n" "$(python -c "import sys;print(\"%d.%d\"%sys.version_info[:2])")" \
    "$(node --version | sed "s/^v//;s/\.[^.]*$//")" "$(go version | sed "s/.*go\([0-9]*\.[0-9]*\).*/\1/")"')
grep -q 'python=3.13' <<<"$versions" || fail "toolchain: python pin mismatch ($versions)"
grep -q 'node=24'     <<<"$versions" || fail "toolchain: node pin mismatch ($versions)"
grep -q 'go=1.26'     <<<"$versions" || fail "toolchain: go pin mismatch ($versions)"
ok "tooling layer: python 3.13 / node 24 / go 1.26 as declared"

# 3) agent layer: app versions equal the declarations (exact pins, not majors).
for app in claude opencode; do
  want=$(decl_version "$app")
  got=$(docker run --rm --entrypoint bash -i "$image" <<< "$app --version" | grep -oE '[0-9][0-9a-zA-Z.+-]*' | head -1)
  [[ "$got" == "$want" ]] || fail "agent layer: $app is $got, declaration pins $want"
  ok "agent layer: $app $want (matches declaration)"
done

# 4) hash-verified installs: provenance markers carried through.
docker run --rm --entrypoint bash "$image" -c \
  'for a in claude opencode; do grep -q "^sha256=" /home/dev/.local/apps/$a/*/.provenance || exit 1; done' ||
  fail "provenance markers missing"
ok "provenance markers present for both apps"

# 5) host-only capabilities are absent by design (documented differences).
docker run --rm --entrypoint bash "$image" -c 'command -v dockerd >/dev/null && echo PRESENT || echo ABSENT' |
  grep -qx ABSENT || fail "image unexpectedly contains a container engine"
ok "host-only groups correctly absent"

printf 'acceptance: image %s matches the repository declarations\n' "$image"
