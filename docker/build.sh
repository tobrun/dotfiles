#!/usr/bin/env bash
# docker/build.sh — build sandbox images from docker/inputs.txt pinned refs.
# Usage: bash docker/build.sh [base|tooling|agent]   (default: agent, builds all stages)
set -Eeuo pipefail

fail() { printf 'docker build: %s\n' "$*" >&2; exit 1; }
note() { printf 'docker build: %s\n' "$*"; }

module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$module_dir/.." && pwd)

target=${1:-agent}
[[ "$target" =~ ^(base|tooling|agent)$ ]] || fail "unknown target: $target (base|tooling|agent)"
command -v docker >/dev/null || fail "docker not installed (apt group 'docker', see bootstrap phase 1)"

declare -A inputs=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]] ||
    fail "invalid entry in inputs.txt: $line"
  inputs[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
done < "$module_dir/inputs.txt"

for key in ubuntu_image mise_image; do
  [[ -n "${inputs[$key]:-}" ]] || fail "inputs.txt missing $key"
  [[ "${inputs[$key]}" == *@sha256:* ]] || fail "$key must be pinned by @sha256 digest"
done

# Restrict by declared platform explicitly (book 9.4: one supported arch first).
platform=${WORKSTATION_DOCKER_PLATFORM:-linux/amd64}

# Plain `docker build`: with the docker-buildx plugin installed (apt group
# `docker`) this runs on the BuildKit backend, which the Dockerfile's cache
# mounts require. Images land in the local docker store.
note "building '$target' ($platform) from pinned inputs"
docker build \
  --file "$module_dir/Dockerfile" \
  --target "$target" \
  --build-arg UBUNTU_IMAGE="${inputs[ubuntu_image]}" \
  --build-arg MISE_IMAGE="${inputs[mise_image]}" \
  --platform "$platform" \
  --tag "workstation-$target:local" \
  "$repo_root"
note "ok: workstation-$target:local"
