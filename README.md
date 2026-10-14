# Workstation dotfiles

Declarations and code that build this workstation: one repository declares the
environment; small modules apply it; observations live outside this repo.

## Vision

A reproducible workstation is a **maintained explanation of how your working
environment is built**. The machine is an output of this repository, never an
input: whatever makes the machine useful only counts as reproducible once it
exists here as a reviewed declaration plus code that converges reality toward
it. The ideas this repo is built on:

- **One owner per kind of state.** Files, system packages, developer tools,
  and container packaging each have exactly one owner with a reviewable
  declaration. Duplicate owners mean `command -v` succeeds while the shell
  runs an unintended version.
- **Declarations, not observations.** A machine inventory is evidence, not
  intent. Only curated content in this repo states what the workstation
  should be; everything else — project source, browser sessions,
  credentials, model weights — has other owners and stays out by design.
- **Convergence over installation.** Every module is idempotent with a
  read-only check mode, so re-applying the declarations repairs managed
  state; "installed once" is not the goal.
- **Keep the claim smaller than the evidence.** This repo aims to be
  recoverable, convergent, and repeatable. Bit-for-bit reproducibility is a
  different, more expensive claim — a Docker digest identifies an artifact,
  it does not prove you can recreate it.
- **Drift is a work queue, not a failure to hide.** An out-of-band change is
  detected by `scripts/drift.sh` and resolved deliberately — fold it into the
  declaration or revert it — so machine and repo never quietly disagree.
- **Update deliberately, recover from a runbook.** Version bumps follow the
  recipe recorded in the declaration and re-verify provenance; clean-machine
  recovery is written down in `docs/runbooks/`, not reenacted from memory.

## Who owns what state

| State | Owner | Declaration | Status |
| --- | --- | --- | --- |
| Ubuntu packages | apt module | `packages/apt/*.txt` | active |
| Third-party apps & binaries (per-user) | apps module | `packages/apps/*.txt` | active |
| Personal files (shell, git config, systemd units, mise config copies, OpenCode skills) | chezmoi | `home/` | active |
| GNOME desktop settings | desktop module | `packages/desktop/*.txt` | active |
| Language runtimes / dev CLIs | mise | `toolchains/mise.toml` + lock | active |
| Container packaging | Dockerfile (same modules + declarations) | `docker/` | active |
| Project source (`~/ws/<project>`) | each project's own git remote | *never stored here* | excluded |

Do not install the same tool through two owners. The package owner and the
effective executable must agree. In particular, **bootstrap tools (chezmoi, mise)
stay out of mise itself** — they are pinned below and installed by hand, because
they run the convergence and cannot be converged by it. (The mise registry entry
`opencode` is the older 1.x product line and must not be used; see
`packages/apps/opencode.txt`.)

## Excluded state (never in this repository)

Recovery means rebuilding from declarations; some state deliberately has other
owners. This repo never stores, inventories, or pushes it:

- **Project checkouts under `~/ws/`** — work lives in `~/ws/<project>` and each
  project is owned by its own git remote; recovery is cloning from there.
  Project lists, private remote URLs, and project content must not appear in
  this repository (it is pushed); that inventory belongs to your backup/remote
  system, not the workstation declaration. The only thing under `~/ws/` that
  this repo is about is its own checkout.
- **Credentials and identity** — SSH keys, tokens, and git identity come from
  separately recovered machine data (chezmoi config) or a credential system;
  templates reference them, files never hardcode them.
- **Observations** — drift reports and package inventories live under
  `~/.local/state/workstation/`: evidence, not declarations.

Drift checks and `chezmoi` only ever look at declared paths, so a clean
`drift.sh` result says nothing — and leaks nothing — about `~/ws/`.

## Prerequisites (bootstrap tools, pinned)

Both installer scripts verify the artifact hash themselves, but the *script*
comes over TLS; review before piping.

```bash
sh -c "$(curl -fsSL get.chezmoi.io)" -b ~/.local/bin -t v2.73.1   # chezmoi
curl -fsSL https://mise.run | MISE_VERSION=v2026.10.8 sh          # mise
```

`./bootstrap` refuses to run without them and prints these commands.

## Applying the declarations

```bash
./bootstrap            # apt → apps → dotfiles → desktop → toolchains
./scripts/drift.sh     # read-only: does reality still match the declarations?
```

`scripts/drift.sh` runs a `workstation-drift.timer` daily at 06:30 (systemd user
timer, installed via chezmoi; `systemctl --user list-timers` to inspect, reports
in `~/.local/state/workstation/drift/`). The desktop layer check skips (not
fails) where no session D-Bus exists.

Bootstrap takes machine data from the environment (with sensible fallbacks):
`WORKSTATION_PROFILE` (desktop/server/container), `WORKSTATION_GIT_NAME`,
`WORKSTATION_GIT_EMAIL`. If `chezmoi apply` refuses because a managed file was
edited outside the repo, review with `chezmoi diff`, then either fold the change
into `home/` or rerun with `WORKSTATION_APPLY_FORCE=1`.

Single layers:

```bash
sudo bash modules/apt.sh base                 # ensure apt packages are present
bash modules/apps.sh chrome                   # converge one app/CLI
WORKSTATION_APPS_CHECK=1 bash modules/apps.sh chrome   # read-only check
chezmoi apply                                 # re-project home files
bash modules/desktop.sh gnome                 # converge GNOME settings
(cd ~ && MISE_LOCKED=1 mise install --locked) # install pinned toolchain
```

`modules/apt.sh` is presence-only by design: it installs declared packages, it does
not remove, downgrade, or upgrade (the host security policy owns upgrades).
Groups may bind third-party apt repositories with `repo = <name>` lines; the
repo itself is declared by `packages/apt/repos/<name>.sources` +
`<name>.key.asc` (committed key, fixed keyring path) and the module converges
both before touching packages — `tailscale` is the reference group.

**Mise ownership rule:** the host's `~/.config/mise/config.toml` and `mise.lock`
are chezmoi-projected copies of `toolchains/`. Never run bare `mise use`/`mise
install` against them — mise then rewrites the projected lock and chezmoi (rightly)
reports drift. Edit `toolchains/mise.toml`, run `mise lock` there, `chezmoi apply`,
then install with `--locked`. Rust is intentionally absent until needed.

## Third-party artifacts and provenance

Large archives are **not** stored in Git. They live in a private cache:

    ~/.cache/workstation/apps/<archive name>

Each declaration in `packages/apps/` pins the archive by name and sha256 (zip and
tar.gz/tgz are supported). The module verifies the hash before installing and
refuses to install on mismatch. Every declared app ends convergence with its own
declared `smoke_cmd` executed through the real launcher (`$APP`/`$VERSION` are
provided), so "converged" means functional evidence, not "a script ran".

- **chrome**: Chrome for Testing publishes versioned, permanent URLs but no
  checksum sidecar; the pinned sha256 is a documented local recovery anchor, not
  independent publisher verification. Update procedure in the declaration.
- **opencode**: v2 ships per-platform binaries as `@opencode/cli-<platform>` npm
  packages; the registry publishes a per-tarball `dist.integrity` (sha512), which
  was cross-checked when pinning. Update procedure in the declaration.

Sources that rotate or delete artifacts (e.g. the Chromium snapshot bucket) cannot
be re-fetched later; prefer publishers with versioned URLs and published hashes.

## Chrome sandbox on Ubuntu 23.10+ (AppArmor userns)

Ubuntu restricts unprivileged user-namespace creation: unconfined binaries that
create a userns are transitioned into a capability-less `unprivileged_userns`
profile and fail to write uid mappings. Chromium's legacy SUID sandbox helper no
longer exists in current builds. The supported fix is an AppArmor profile granting
`userns` to the exact executable path — same mechanism as Ubuntu's own
`/etc/apparmor.d/chrome`.

`modules/apps.sh` generates the profile to
`~/.cache/workstation/apps/apparmor/workstation-chrome` and check mode verifies the
installed `/etc/apparmor.d/workstation-chrome` matches it byte for byte. Clean
machine recovery: `./bootstrap`, apply the printed AppArmor commands, rerun
`./bootstrap`.

## GNOME settings semantics

The desktop layer converges **exact values** (`gsettings get` GVariant literals).
`packages/desktop/gnome.txt` was seeded from observed state on 2026-10-13 and is
the one place to change desktop preferences: edits made through the Settings app
or gsettings by hand are drift and will be reverted by the next `./bootstrap`.
Run `./scripts/drift.sh` first to see what would be reverted.

## Docker sandboxes

`docker/` assembles sandbox images from the **same** declarations and modules
the host converges (`modules/apt.sh`, `modules/apps.sh`, `toolchains/`,
`packages/apps/claude.txt`, `packages/apps/opencode.txt`). Base images are
pinned by digest in `docker/inputs.txt`; image builds fetch app artifacts with
`WORKSTATION_APP_FETCH=1` (opt-in, always sha256-verified against the
declaration). Deliberate host/image differences are documented in
`docker/README.md`.

```bash
bash docker/build.sh agent    # build workstation-agent:local
bash docker/acceptance.sh     # parity checks against the declarations
bash docker/run.sh            # sandbox with $PWD mounted at /workspaces
```

The host engine itself is the apt group `packages/apt/docker.txt` (installed by
`./bootstrap`; afterwards `sudo usermod -aG docker $USER` and re-login).

## Current manual notes

- `~/.config/opencode/opencode.json` and `service.json` are **intentionally not
  managed**: the config contains host/LAN addresses that must not enter the
  (pushed) repository, and `service.json` is OpenCode's own service-registration
  runtime state. Only the skills tree under `~/.config/opencode/skills/` is
  declared (via `home/`); machine-local OpenCode config stays machine-local.
- `~/.opencode/` (old curl-installer copy and PATH entry) is no longer used — the
  managed launcher is `~/.local/bin/opencode`. Delete `~/.opencode` once no
  running process holds it (this session included).
- The 158.0.8104.0 Chromium install is retained under `~/.local/apps/chrome/` as
  the rollback anchor; the declaration comments carry the four rollback keys.
