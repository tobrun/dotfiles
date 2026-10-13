#!/usr/bin/env bash
# drift.sh — read-only drift report across every declared layer.
#
# Answers one question: does reality still match this repo's declarations?
# Nothing here modifies state; convergence is ./bootstrap's job. Reports are
# observations, so they live outside the repo (ch. 3):
#   ~/.local/state/workstation/drift/<utc-timestamp>.log
#
# Exit status: 0 = converged, 1 = drift detected (or a layer unverifiable).
set -Eeuo pipefail
export PATH="$HOME/.local/bin:$PATH"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"

state_dir="${WORKSTATION_STATE_DIR:-$HOME/.local/state/workstation}/drift"
mkdir -p -- "$state_dir"
log="$state_dir/$(date -u +%Y%m%dT%H%M%SZ).log"

overall=0
report=()

# run_check <name> <command...> — records ok/DRIFT plus the command's output.
run_check() {
  local name=$1
  shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if ((rc == 0)); then
    report+=("ok       $name")
  else
    overall=1
    report+=("DRIFT    $name (exit $rc)")
    while IFS= read -r line; do report+=("           | $line"); done <<<"$out"
  fi
}

# Layer: apt presence (root not required for a --check).
run_check apt bash modules/apt.sh --check base

# Layer: declared per-user applications (check mode: verify, never write).
for decl in packages/apps/*.txt; do
  app=$(basename -- "$decl" .txt)
  run_check "apps:$app" env WORKSTATION_APPS_CHECK=1 bash modules/apps.sh "$app"
done

# Layer: home-directory dotfiles (chezmoi status lists targets that differ).
if ! command -v chezmoi >/dev/null 2>&1 || [[ ! -f "$HOME/.config/chezmoi/chezmoi.toml" ]]; then
  overall=1
  report+=("DRIFT    dotfiles (chezmoi not registered — run ./bootstrap)")
else
  # chezmoi status exits 0 even when it lists drifted targets, so turn a
  # non-empty listing into a failing check whose output names the targets.
  run_check dotfiles bash -c \
    'out=$(chezmoi status 2>&1); [[ -z "$out" ]] || { printf "%s\n" "$out"; exit 1; }'
fi

# Layer: developer toolchains — installed set must match the pinned lock.
# --dry-run-code exits 1 when anything would need installing; it never
# modifies state. MISE_LOCKED also prevents mise from rewriting the
# projected lockfile (that file belongs to chezmoi, see README).
if ! command -v mise >/dev/null 2>&1; then
  overall=1
  report+=("DRIFT    toolchains (mise not installed — see README Prerequisites)")
else
  run_check toolchains env MISE_LOCKED=1 bash -c \
    'cd "$HOME" && mise install --locked --dry-run-code'
fi

{
  printf '# drift report %s — %s\n' "$(date -u +%FT%TZ)" "$(hostname)"
  printf '%s\n' "${report[@]}"
  if ((overall == 0)); then
    printf 'drift: all layers converged\n'
  else
    printf 'drift: drift detected — run ./bootstrap to converge, then recheck\n'
  fi
} | tee -- "$log"

exit "$overall"
