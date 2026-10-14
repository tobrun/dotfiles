# Runbook: fleet host preparation (coding-agent sandbox runtime)

Host-only layer. The package half is declared in `packages/apt/sbx.txt`
(repo bound via `packages/apt/repos/docker.*`); this runbook owns the host
state the package cannot carry: KVM access, service directories, the `sbx`
lockdown, the Tailscale administration path, and the memory/disk budget.
Design rationale lives in `~/ws/books/REMOTE_CODING_AGENTS_IN_PRACTICE.md`
(ch 4–5); this file is the operator contract for **this** machine.

## Machine facts (verified 2026-10-14)

| Item | Value | Consequence |
| --- | --- | --- |
| Release | Ubuntu 26.04.1 LTS (resolute), x86_64 | supported by `docker-sbx` |
| KVM | `/dev/kvm` present; `nurbot` **not** in `kvm` group until prepared | blocking step below |
| RAM | 60 GiB (+7 GiB swap) | concurrency target is **3 tasks**, not the book's 10 |
| GPU | RTX 4090, 24 GiB, idle | **unallocated spare** — inference runs on a remote server (deviation from the book's running example) |
| Disk | 621 GiB root, ~544 GiB free | admission floor below |
| Engine | Ubuntu-archive `docker.io` 29.1.3 (group `docker`) | coexists; `sbx` does not need it and the docker-ce suite stays uninstalled |
| Tailscale | installed (group `tailscale`), logged out | Phase 0 enrolls |
| Fleet account | `nurbot` (desktop account; book ch 3.3 accepted trade-off) | everything below runs as `nurbot` |

## Memory budget (admission policy until measured otherwise)

| Consumer | Reserve |
| --- | ---: |
| Desktop, kernel, runtime, remote administration | 10 GiB |
| Inference gateway + host services overhead | 3 GiB |
| Maintenance / failure headroom | 12 GiB |
| Task environments (8 GiB each) | 3 × 8 GiB = 24 GiB |
| Unaccounted (runtime overhead — measure) | ~11 GiB |

Admission rule: at most **three** concurrent 8 GiB sandboxes with explicit
`--cpus 4 --memory 8g` (the CLI's host-proportional defaults are not an
admission policy). Reduce to two if measured runtime overhead eats the last
row. Disk: stop new admission with under ~60 GiB free (export + diagnosis
reserve); the 80 %-use mark is only a notification threshold.

## Preparation (root steps, run interactively)

```bash
sudo usermod -aG kvm nurbot                     # KVM access (re-login after)
sudo mkdir -p /srv/agent-sources /srv/agent-templates /srv/models
sudo chown nurbot:nurbot /srv/agent-sources /srv/agent-templates /srv/models
sudo bash modules/apt.sh sbx                    # keyring + sources + docker-sbx
tailscale up                                    # browser login; enrollment
```

Verify after a **new login session** (group changes need it):

```bash
id -nG | tr ' ' '\n' | grep -qx kvm && echo kvm-ok
sbx version
```

`/srv` conventions: `agent-sources/<repo>` holds one clean clone per
repository baseline at a recorded commit (never the daily checkout);
`agent-templates` holds exported template tars; `models` is unused while
inference is remote — kept reserved.

## sbx lockdown (run once after install, as nurbot)

```bash
sbx login                                       # browser OAuth; GUI session exists
sbx settings set ssh.agentForwardingEnabled false
sbx settings set skills.defaultMode off
sbx daemon restart
sbx policy init deny-all
```

Book ch 5.2: apply before active work exists; changing settings later is an
interruption. Then capture the installed interfaces (`sbx version`,
`sbx create/run/exec/ports/template save --help`, `sbx settings ls --json`)
into the host record — help text proves the syntax of *this* installation.

## Tailscale administration path

- Enable host SSH only with a recovery connection already open (enabling it
  interrupts existing connections to the tailnet address):
  `sudo tailscale set --ssh`.
- Laptop connects to `nurbot` with `ForwardAgent no`; never forward the
  laptop's SSH agent into the fleet account.
- Keep a second recovery route (local console) before touching SSH,
  firewall, kernel, or driver config.

## Reboot checklist (run after the first real reboot, then on maintenance)

1. Remote login to `nurbot` works over the tailnet.
2. `sbx daemon` state reachable; sandboxes recover or are explained.
3. Disk above admission floor; `/srv` dirs intact.
4. Tailscale reconnected (`tailscale status`).

## Drift policy

`scripts/drift.sh` proves `docker-sbx` + repo files are present. The
lockdown settings, budget, and `/srv` inventory are this runbook's manual
half: re-run `sbx settings ls --json` and the boundary probes after any
runtime upgrade and treat differences as drift to reconcile here.
