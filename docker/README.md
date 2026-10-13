# Docker layer — sandboxes from the same declarations as the host

One implementation per declaration: the image installs through the **same**
`modules/apt.sh` and `modules/apps.sh` the host converges, from the same
`packages/` and `toolchains/` files. A rebuild instruction exists in Git.

## Targets

| Target | Contents | Source of truth |
| --- | --- | --- |
| `base` | Ubuntu (digest-pinned) + apt base group | `packages/apt/base.txt` |
| `tooling` | base + locked mise toolchains | `toolchains/mise.toml` + `mise.lock` |
| `agent` | tooling + `claude` + `opencode` | `packages/apps/*.txt` |

## Commands

```bash
bash docker/build.sh agent        # build (inputs pinned in docker/inputs.txt)
bash docker/acceptance.sh         # parity checks against the declarations
bash docker/run.sh                # sandbox with $PWD at /workspaces
bash docker/run.sh --with-auth    # + bind-mount claude/opencode credentials
```

## Intentional host/image differences (book ch 9 lab)

| Host | Image | Why |
| --- | --- | --- |
| apt groups `base` + `docker` | `base` only | a sandbox does not carry its own container engine |
| apps `chrome`, `code` (GUI) | absent | need display + AppArmor userns profiles; host-only |
| app `agent-browser` | absent | drives Chrome; no browser in the sandbox by design |
| apps `claude`, `opencode` | same module, same pins | shared layer |
| chezmoi `home/` tree | minimal image home | shell preferences are host personalization, not environment |
| desktop/gsettings layer | absent | no desktop in a container |
| apt floating (no snapshot) | same policy, fresh per build | update policies differ by design (book 1.3): host = long-lived + drift checks; image = rebuilt from pinned base digest |

## Build notes

- `docker/inputs.txt` pins base + mise images by `@sha256` digest; bump
  deliberately via its update recipe.
- Artifact fetch during image builds uses `WORKSTATION_APP_FETCH=1`: downloads
  come from each declaration's `source` and must match the declared `sha256`,
  or the build fails. Archives stay in a BuildKit cache mount, out of layers.
- The `agent` target writes `~/.claude/settings.json` disabling the CLI
  self-updater so pins stay authoritative (mirrors the host chezmoi file).
- Container uid is 1000 to match the host user; bind mounts round-trip.
- Rebuilds are honest only up to the pinned inputs: apt resolves against
  whatever the archive serves today (same floating policy as the host).
