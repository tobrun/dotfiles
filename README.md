# Workstation dotfiles

Declarations and code that build this workstation. Following
`~/Documents/REPRODUCIBLE_WORKSTATIONS_IN_PRACTICE.md`: one repository declares the
environment; small modules apply it; observations live outside this repo.

## Who owns what state

| State | Owner | Declaration | Status |
| --- | --- | --- | --- |
| Ubuntu packages | apt module | `packages/apt/*.txt` | active |
| Third-party desktop apps (per-user) | apps module | `packages/apps/*.txt` | active |
| Personal files (shell, git config) | chezmoi | `home/` | planned |
| Language runtimes / dev CLIs | mise | `toolchains/mise.toml` + lock | planned |
| Desktop (dconf) preferences | host module | TBD | planned |
| Container packaging | Dockerfile | `docker/` | planned |

Do not install the same tool through two owners. The package owner and the
effective executable must agree.

## Applying the declarations

```bash
./bootstrap            # apt packages, then declared apps
```

Or a single layer:

```bash
sudo bash modules/apt.sh base     # ensure apt packages are present
bash modules/apps.sh chrome      # ensure declared apps are installed
```

`modules/apt.sh` is presence-only by design: it installs declared packages, it does
not remove, downgrade, or upgrade (the host security policy owns upgrades).

## Third-party app artifacts and provenance

Large archives are **not** stored in Git. They live in a private cache:

    ~/.cache/workstation/apps/<archive name>

Each declaration in `packages/apps/` pins the archive by name and sha256. The apps
module verifies the hash before installing and refuses to install on mismatch.
Sources that rotate or delete artifacts (e.g. the Chromium snapshot bucket) cannot
be re-fetched later; when an archive disappears from its source, obtaining it again
becomes its own recovery step. Prefer publishers with versioned URLs and published
checksums (e.g. Chrome for Testing) when selecting a source for updates.

Apps install under `~/.local/apps/<app>/<version>` with a `current` symlink, a
launcher in `~/.local/bin/`, and a `.desktop` entry. The module converges: reruns
are no-ops unless the declaration changes. Convergence ends with a functional
smoke test (sandboxed headless render for Chrome), so "converged" means evidence,
not "a script ran".

## Chrome sandbox on Ubuntu 23.10+ (AppArmor userns)

Ubuntu restricts unprivileged user-namespace creation: unconfined binaries that
create a userns are transitioned into a capability-less `unprivileged_userns`
profile and fail to write uid mappings. Chromium's legacy SUID sandbox helper no
longer exists in current builds (it reports "provides API version 1, but you
need 0"). The supported fix is an AppArmor profile granting `userns` to the
exact executable path — the same mechanism as Ubuntu's own `/etc/apparmor.d/chrome`.

`modules/apps.sh` generates that profile to
`~/.cache/workstation/apps/apparmor/workstation-chrome` and prints the one-time
root commands to install and load it into `/etc/apparmor.d/workstation-chrome`.
Clean-machine recovery therefore is: `./bootstrap`, apply the printed AppArmor
commands, rerun `./bootstrap`.

## Current manual notes

- `~/.local/bin` is added to PATH from `~/.bashrc` (marker-managed) until chezmoi
  takes ownership of the shell files.
- `opencode` was installed via `curl -fsSL https://opencode.ai/v2/install | bash`
  (see `~/Documents/initial-install.txt`); a declaration for it is pending.
