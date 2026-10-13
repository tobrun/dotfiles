# AGENTS.md

Guidance for AI coding agents working in this repository.

This repo is the **single source of truth for one workstation**: declarative
layers plus the convergence code that applies them. The machine is an output
of the repo, never the input. Design rationale lives in `README.md` and
`~/Documents/REPRODUCIBLE_WORKSTATIONS_IN_PRACTICE.md`; this file is the
operating contract.

## The three facts

1. **Convergence**: `./bootstrap` is the single entry point. It runs ordered
   phases (apt → apps → dotfiles → desktop → toolchains) and reports failures
   by phase without stopping later phases.
2. **Acceptance test**: `scripts/drift.sh` must end with
   `drift: all layers converged` before any change is declared done.
3. **Drift policy**: a change made outside the repo (dock edits, `apt install`,
   `npm i -g`, hand-edited dotfiles) is drift. Resolve it by updating the
   declaration or re-converging — never by leaving the machine and repo
   disagreeing. If the user intentionally changed the machine, the repo
   usually adopts the change; ask which side is the source of truth.

## Repository map

| Path | Purpose |
| --- | --- |
| `bootstrap` | Ordered phases, root work delegated via sudo, machine data passed explicitly |
| `modules/apt.sh` | System packages from `packages/apt/base.txt` (`--check` = read-only) |
| `modules/apps.sh` | Per-user pinned apps from `packages/apps/<app>.txt` (`WORKSTATION_APPS_CHECK=1` = read-only) |
| `modules/desktop.sh` | gsettings convergence from `packages/desktop/<profile>.txt` (`WORKSTATION_DESKTOP_CHECK=1`) |
| `home/` | chezmoi source tree, projected onto `$HOME` (naming: `dot_x` → `.x`) |
| `toolchains/mise.toml` + `mise.lock` | Canonical developer toolchains |
| `packages/apt/base.txt` | System package pins (`name=version`) |
| `packages/apps/*.txt` | App declarations (version, sha256, launcher, smoke test) |
| `packages/desktop/gnome.txt` | GNOME settings baseline |
| `scripts/drift.sh` | Cross-layer read-only drift report |

## Convergence contract (every module obeys this)

- Idempotent: a second run is a no-op (`already at` / `already converged`).
- Read-only check mode for drift detection; never mutates in check mode.
- Destructive actions are gated (backup first, explicit env override, refuse
  under check mode).
- `set -Eeuo pipefail` discipline with a `fail()` helper; no silent failures.

## Recipes

**System package** → append to `packages/apt/base.txt` (pin `name=version`
when reproducibility matters), then `modules/apt.sh` via sudo.

**Per-user CLI/app** → new `packages/apps/<app>.txt`, never ad-hoc
`npm i -g` or manual installs:
- Filename must equal `name` (the module enforces it). **The app name is the
  launcher name** (`~/.local/bin/<app>`) — name it what the user types.
- Pin `version` + `sha256`. Verify provenance at declaration time (registry
  integrity header or publisher sidecar); if no independent source exists,
  record a "local recovery anchor" note in the header, as `chrome.txt` does.
- Archive lives in `~/.cache/workstation/apps/` — never committed.
- Header comment must carry the update recipe (how to find the next version,
  what to re-verify, which module command to rerun).
- Provide `smoke_cmd` (declaration-owned, runs after every install).
- Electron/Chromium apps need `apparmor = true` (userns sandbox profile; the
  generated profile globs the version dir, so bumps stay covered) and
  `desktop = false` (desktop-entry generation is chrome-specific).
- Root steps (AppArmor profile install) print `sudo` commands; the module
  converges everything else without them.

**Dotfiles** → edit `home/` using chezmoi naming. Gotchas:
- `dot_config.json` yields `.config.json`; inside a `dot_dir/`, a managed file
  keeps its plain name (no `dot_` prefix) unless you want a leading dot.
- Machine-specific values (`profile`, `gitName`, `gitEmail`, `repoDir`) come
  from chezmoi's config, prompted at init by `home/.chezmoi.toml.tmpl` and
  stored in `~/.config/chezmoi/chezmoi.toml` — templates read them, target
  files never hardcode them.
- New top-level source dirs/templates may need `chezmoi init --source $PWD
  ...` re-run (see README) before `chezmoi apply` sees them.

**Desktop setting** → edit `packages/desktop/gnome.txt`, converge with
`bash modules/desktop.sh`.

**Developer tool** → `mise use -g <tool>@<version>` (updates both
`toolchains/mise.toml` and `mise.lock`); commit both files.

## Environment notes (agent shells)

- `sudo` needs an interactive password here → full `./bootstrap` fails in
  non-interactive shells. Converge via single modules
  (`bash modules/apps.sh <app>`, `chezmoi apply`, `bash modules/desktop.sh`)
  and hand root-requiring commands to the user verbatim.
- A GUI session exists (X11 `:0` + Wayland); GUI smoke tests are possible but
  leave no stray windows behind — kill test instances.

## Conventions

- Commit one logical unit; message style `<area>: <lowercase summary>`,
  e.g. `apps: declare opencode 2.0.28 from the @opencode npm platform
  artifact`. Land module-support changes as their own commit before the
  declaration that needs them. Never commit binaries or cached archives.
- Version bumps: follow the declaration header's update recipe, re-verify the
  checksum, rerun the module, run `scripts/drift.sh`.
- Shell style: bash with `set -Eeuo pipefail`, `note()`/`fail()` helpers,
  `key = value` declaration parsing — match the existing modules.
- Before declaring work done: `scripts/drift.sh` shows all layers converged.
