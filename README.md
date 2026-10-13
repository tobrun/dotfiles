# Workstation dotfiles

Declarations and code that build this workstation. Following
`~/Documents/REPRODUCIBLE_WORKSTATIONS_IN_PRACTICE.md`: one repository declares the
environment; small modules apply it; observations live outside this repo.

## Who owns what state

| State | Owner | Declaration | Status |
| --- | --- | --- | --- |
| Ubuntu packages | apt module | `packages/apt/*.txt` | active |
| Third-party desktop apps (per-user) | apps module | `packages/apps/*.txt` | active |
| Personal files (shell, git config, mise config copies) | chezmoi | `home/` | active |
| Language runtimes / dev CLIs | mise | `toolchains/mise.toml` + lock | active |
| Desktop (dconf) preferences | host module | TBD | planned |
| Container packaging | Dockerfile | `docker/` | planned |

Do not install the same tool through two owners. The package owner and the
effective executable must agree. In particular, **bootstrap tools (chezmoi, mise)
stay out of mise itself** — they are pinned below and installed by hand, because
they run the convergence and cannot be converged by it.

## Prerequisites (bootstrap tools, pinned)

Verified release checksums before installing is part of the procedure; both
scripts check the artifact hash themselves, but the *script* comes over TLS.

```bash
sh -c "$(curl -fsSL get.chezmoi.io)" -b ~/.local/bin -t v2.73.1   # chezmoi
curl -fsSL https://mise.run | MISE_VERSION=v2026.10.8 sh          # mise
```

`./bootstrap` refuses to run without them and prints these commands.

## Applying the declarations

```bash
./bootstrap            # apt → apps → dotfiles (chezmoi) → toolchains (mise)
./scripts/drift.sh     # read-only: does reality still match the declarations?
```

Bootstrap takes machine data from the environment (with sensible fallbacks):
`WORKSTATION_PROFILE` (desktop/server/container), `WORKSTATION_GIT_NAME`,
`WORKSTATION_GIT_EMAIL`. If `chezmoi apply` refuses because a managed file was
edited outside the repo, review with `chezmoi diff`, then either fold the change
into `home/` or rerun with `WORKSTATION_APPLY_FORCE=1`.

Single layers:

```bash
sudo bash modules/apt.sh base                 # ensure apt packages are present
bash modules/apt.sh --check base              # same question, read-only
bash modules/apps.sh chrome                   # converge one app
WORKSTATION_APPS_CHECK=1 bash modules/apps.sh chrome   # read-only check
chezmoi apply                                 # re-project home files
(cd ~ && MISE_LOCKED=1 mise install --locked) # install pinned toolchain
```

`modules/apt.sh` is presence-only by design: it installs declared packages, it does
not remove, downgrade, or upgrade (the host security policy owns upgrades).

**Mise ownership rule:** the host's `~/.config/mise/config.toml` and `mise.lock`
are chezmoi-projected copies of `toolchains/`. Never run bare `mise use`/`mise
install` against them — mise then rewrites the projected lock and chezmoi (rightly)
reports drift. Edit `toolchains/mise.toml`, run `mise lock` there, `chezmoi apply`,
then install with `--locked`. Rust is intentionally absent until needed.

## Third-party app artifacts and provenance

Large archives are **not** stored in Git. They live in a private cache:

    ~/.cache/workstation/apps/<archive name>

Each declaration in `packages/apps/` pins the archive by name and sha256. The apps
module verifies the hash before installing and refuses to install on mismatch.
Sources that rotate or delete artifacts (e.g. the Chromium snapshot bucket) cannot
be re-fetched later; when an archive disappears from its source, obtaining it again
becomes its own recovery step. Prefer publishers with versioned URLs (e.g. Chrome
for Testing) when selecting a source for updates.

Apps install under `~/.local/apps/<app>/<version>` with a `current` symlink, a
launcher in `~/.local/bin/`, and a `.desktop` entry. The module converges: reruns
are no-ops unless the declaration changes. Convergence ends with a functional
smoke test (sandboxed headless render for Chrome), so "converged" means evidence,
not "a script ran".

Chrome's declaration documents that Chrome for Testing publishes **no checksum
sidecar**: the pinned sha256 is a local recovery anchor (detects corruption or
substitution since recording), not independent publisher verification. Updating
means: pick a version from the `last-known-good-versions.json` channel feed,
download into the cache, update the four pinned keys, rerun the module.

## Chrome sandbox on Ubuntu 23.10+ (AppArmor userns)

Ubuntu restricts unprivileged user-namespace creation: unconfined binaries that
create a userns are transitioned into a capability-less `unprivileged_userns`
profile and fail to write uid mappings. Chromium's legacy SUID sandbox helper no
longer exists in current builds (it reports "provides API version 1, but you
need 0"). The supported fix is an AppArmor profile granting `userns` to the
exact executable path — the same mechanism as Ubuntu's own `/etc/apparmor.d/chrome`.

`modules/apps.sh` generates that profile to
`~/.cache/workstation/apps/apparmor/workstation-chrome` and check mode verifies the
installed `/etc/apparmor.d/workstation-chrome` matches it byte for byte. Clean
machine recovery: `./bootstrap`, apply the printed AppArmor commands, rerun
`./bootstrap`.

## Current manual notes

- `opencode` was installed via `curl -fsSL https://opencode.ai/v2/install | bash`
  (see `~/Documents/initial-install.txt`); externally owned for now, a declaration
  is pending.
- The 158.0.8104.0 Chromium install is retained under `~/.local/apps/chrome/` as
  the rollback anchor (declaration comments carry the rollback keys); its dead
  setuid helper still needs `chown nurbot:nurbot` + `chmod 755` once via sudo.
