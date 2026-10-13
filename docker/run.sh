#!/usr/bin/env bash
# docker/run.sh — start an interactive sandbox from workstation-agent:local.
# The current directory is mounted at /workspaces (container uid 1000 == host
# uid 1000, so file ownership round-trips).
#
#   bash docker/run.sh                 # clean sandbox
#   bash docker/run.sh --with-auth     # + bind-mount agent credentials
#                                      #   (claude login, opencode auth)
#                                      #   CAREFUL: writes use your real creds
set -Eeuo pipefail
fail() { printf 'docker run: %s\n' "$*" >&2; exit 1; }

module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
image=${WORKSTATION_SANDBOX_IMAGE:-workstation-agent:local}
docker image inspect "$image" >/dev/null 2>&1 ||
  fail "image $image not present; run: bash docker/build.sh agent"

args=(--rm -it --cap-drop ALL --security-opt no-new-privileges
      -v "$PWD:/workspaces" -w /workspaces)
if [[ "${1:-}" == --with-auth ]]; then
  [[ -e "$HOME/.claude.json" ]] && args+=(-v "$HOME/.claude.json:/home/dev/.claude.json:ro")
  [[ -d "$HOME/.claude" ]]      && args+=(-v "$HOME/.claude:/home/dev/.claude")
  [[ -d "$HOME/.local/share/opencode" ]] && args+=(-v "$HOME/.local/share/opencode:/home/dev/.local/share/opencode")
elif [[ -n "${1:-}" ]]; then
  fail "unknown flag: $1 (use --with-auth)"
fi

exec docker run "${args[@]}" "$image" bash
