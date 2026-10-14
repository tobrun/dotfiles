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
| KVM | `/dev/kvm` group `kvm` (nurbot in `/etc/group` since 2026-10-14) + logind/uaccess ACL `user:nurbot:rw-` | two access paths: ACL for the active seat session, group from the next login |
| RAM | 60 GiB (+7 GiB swap) | concurrency target is **3 tasks**, not the book's 10 |
| GPU | RTX 4090, 24 GiB, idle | **unallocated spare** — inference runs on a remote server (deviation from the book's running example) |
| Disk | 621 GiB root, ~544 GiB free | admission floor below |
| Engine | Ubuntu-archive `docker.io` 29.1.3 (group `docker`) | coexists; `sbx` does not need it and the docker-ce suite stays uninstalled |
| Tailscale | enrolled 2026-10-14 (`desktop-1`, `100.113.6.60`) | admin path below; host SSH still off |
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

**Done 2026-10-14** — all five steps converged; kept here for rebuilds.

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
`agent-templates` holds exported template tars; `agent-exchange/<task>`
holds one task's artifact directory (rw mount, created per task, see
`fleet/defaults.txt`); `models` is unused while inference is remote —
kept reserved. Exchange dirs must never be ancestors of clone roots.
(2026-10-14: all dirs incl. `agent-exchange` created and owned by `nurbot`.)

## sbx lockdown (applied 2026-10-14, as nurbot)

```bash
sbx login                                       # browser OAuth; GUI session exists
sbx settings set ssh.agentForwardingEnabled false
sbx settings set skills.defaultMode off
sbx daemon restart
sbx policy init deny-all
```

Book ch 5.2: apply before active work exists; changing settings later is an
interruption. The four state changes are live (`ssh.agentForwardingEnabled`
and `skills.defaultMode` show `source=override` in `sbx settings ls`;
global policy is `deny-all`; `sbx diagnose` passes with authentication).
The installed interfaces are snapshotted in
`docs/records/sbx-0.48.0/` — help text proves the syntax of *this*
installation; re-capture on every runtime bump.

## First-sandbox boundary evidence (2026-10-14, sbx 0.48.0)

Smoke sandbox `phase1-smoke` (agent `shell`, no workspace, `--cpus 2
--memory 2g --skills off`), then removed. Measured, not assumed:

| Claim | Evidence |
| --- | --- |
| Resource limits enforced | guest saw `nproc=2`, `MemTotal ≈ 1.94 GiB` |
| Private engine per sandbox | guest `docker info` reported server 29.8.1 vs host docker.io 29.1.3 |
| No SSH agent | `SSH_AUTH_SOCK=/run/ssh-agent.sock` is a stub: socket absent, `ssh-add` cannot connect, no identities |
| Host git identity crosses in | guest `git config --global` was seeded with `user.name`/`user.email` from the host — task-authored commits inherit the human identity until Phase 5 gives sandboxes a bot identity (book ch 12) |
| deny-all blocks HTTP(S) by name | `registry.npmjs.org` → `403`; `sbx policy log` records each hit: "No matching allow rule (default deny)" |
| Raw `connect()` is **not** the boundary | `connect()` to `1.1.1.1:80`, `8.8.8.8:53`, tailnet `:22` all succeed (local egress interceptor completes the handshake) — but zero bytes flow: HTTP `GET` got an empty response, no sshd banner, no DNS answer. Verify boundaries at the **data** layer, never at the handshake; these direct-IP connects generate **no policy-log rows** (log covers named domains only) |


## First real task environment: task-001 (2026-10-14)

Profile `fleet/envs/contexia.txt`; source clone `/srv/agent-sources/contexia`
at baseline `dad828035ed7f1a49b130d8d61920254200504ba` (clean, origin
re-pointed at the GitHub remote). Created with `sbx create --name task-001
--clone --skills off --cpus 4 --memory 8g opencode /srv/agent-sources/contexia
/srv/agent-exchange/task-001`, then stopped (idle sandboxes hold no RAM; the
VM state incl. toolchain survives). Measured:

| Claim | Evidence |
| --- | --- |
| Mount rules hold on 0.48.0 | source mounted `/run/sandbox/source` **ro enforced** (`touch` → Read-only file system); clone rw; exchange rw listed last, visible on host immediately; `--clone` auto-added remote `sandbox-task-001` → `git://127.0.0.1:<port>/<repo>` |
| Sandbox remote is lifecycle-scoped | on `sbx stop` the remote disappears from the host clone and is "restored when the sandbox next starts" |
| Verification chain green at baseline | `pnpm install --frozen-lockfile` → `lint` → `typecheck` → `build` → `test:unit` all pass inside the sandbox (unit scope; Postgres-backed integration + Playwright e2e deferred with their own future allow rules) |
| Extraction path | sandbox commit `8f6da296` on a probe branch reached the host clone via `git fetch sandbox-task-001 <branch>`, authored with the declared identity; probe refs cleaned, host clone back at baseline |
| Push must fail | `git push origin` from the sandbox: no credentials, connection refused at the SSH layer — designed boundary |
| Host state invisible | host home (`/home/nurbot`) does not exist in the sandbox mount namespace; 0600 canary unreadable |
| Kit network override | **The `opencode` kit provisions an unremovable allow rule** (AI providers, GitHub, Ubuntu archives) on top of deny-all — `policy rm` refuses (`editable=false`, "recreated at sandbox create"), and it made `github.com` return 200 under "deny-all". Explicit `policy deny` rules **outrank** kit allows (measured: 401 → 403), so `fleet/envs/*.txt` carries a `deny` list neutralizing every provider/GitHub host; inference may only ever reach the gateway, GitHub only the Phase 6 broker |
| Kit toolchain gap | kit ships Node 22 (`corepack` cannot symlink into `/usr/bin` as agent); repo engines `>=24` + `engine-strict=true` → Node 24 tarball fetched to `~/.local/node` at env setup (`nodejs.org` allow rule; **no `xz` in the kit** — must take the `.tar.gz` dist). Phase 5 template retires this rule |
| pnpm store is filesystem-scoped | home (ext4) and clone (its own ext4 device) differ → pnpm silently fell back to a project-local `.pnpm-store/` **inside the clone**, which biome then linted (582 phantom errors). Fix in the profile's verify chain: `--store-dir ~/.pnpm-store` |

## Topology revisions (2026-10-14)

Recorded decisions that revise the original build sequence, several informed
by a community practitioner setup shared that month (mechanisms absorbed;
their names, org, paths and model aliases deliberately not adopted):

1. **Gateway = LiteLLM proxy on the host** (declared later via the apps
   layer, pinned) instead of a hand-built gateway. It supplies the book's
   control-plane pieces off the shelf: per-task virtual keys with expiry and
   model allowlists. Sandbox side: OpenAI-compatible provider at
   `http://host.docker.internal:<port>/v1`; the network policy resource for
   that route is `localhost:<port>`. Keys are injected with
   `sbx secret set-custom` (host-keyed env placeholder, value in the OS
   keyring) — the key never appears in create commands, shell history, or
   sandbox config. Agent config pins `enabled_providers` to the proxy alone
   and denies the agent edits to its own config files; explore/build
   subagents get a cheaper model tier.
2. **Artifact flow through clone mode**: `sbx create --clone` adds a
   `sandbox-<name>` git remote to the *host* repository — the host extracts
   committed work with `git fetch sandbox-<name>`; the sandbox keeps no push
   credentials, so a failing `git push` is the designed boundary, not an
   incident. Generated artifacts go to a dedicated rw **exchange directory**
   mounted alongside the clone.
3. **Bot git identity per sandbox**: identity is set inside each sandbox at
   create time (`sbx exec … git config --global …`) with a dedicated fleet
   bot name/email — overriding the host-identity seeding measured above.
   Value is a parameter (`fleet/` declaration), not hardcoded in scripts.
4. **Per-task declarations live in `fleet/`** (top-level):
   `fleet/defaults.txt` holds shared values (git identity decided
   2026-10-14: the operator's own identity, declared per-sandbox rather
   than inherited — see its header); `fleet/envs/<task>.txt` will hold one
   profile per task-environment (repo baseline + commit, resources, per-task
   network allow-list, read-only context dirs, exchange). The converger
   `modules/fleet.sh` lands with Phase 2 execution. Global policy stays
   `deny-all` + per-sandbox allow rules; curated global allow-lists are
   rejected as weaker.
5. **Templates**: build from `docker/sandbox-templates:<agent>` bases, ship
   via `docker save` + `sbx template load`, bump the tag on every change —
   sbx caches template images by tag.
6. **Deferred phase 6 — host MCP brokers**: credential-adjacent operations
   (GitHub PR/CI, push of `agent/*` branches) run as host-side MCP servers
   registered with `sbx mcp add`: tools and targets (repo, remote, base
   branch) fixed at registration, arguments regex-validated, JSONL audit
   log, bounded concurrency/timeouts. Until then, extraction is manual
   `git fetch sandbox-<task>` on the host.

Mount rules from the practitioner data (0.42.1): never `:ro`-mount a parent
of the clone root (sandbox fails to start); a rw mount sharing ancestry with
`:ro` mounts stays writable only if listed after them; workspace mounts are
frozen at creation; `--clone` refuses git worktrees.
(2026-10-14: re-verified on 0.48.0 via task-001 — all hold; see the
task-001 evidence table.)

## Inference gateway (LiteLLM, host)

Declared as app `litellm` (`packages/apps/litellm.txt`, vendored-tree
provenance — read its header before bumping). Converged and smoke-tested;
**not yet running: blocked on the upstream credential handoff** (remote
model server URL + API key, to be delivered as a `0600` file under
`~/.config/litellm/`, never pasted into chat or shell history). Operating
contract once unblocked:

- Serve on `127.0.0.1:<port>` only; sandboxes reach it at
  `host.docker.internal:<port>` and the per-sandbox allow resource is
  `localhost:<port>` (plus the gateway deny of every direct provider host,
  already in `fleet/envs/contexia.txt`).
- One real upstream key lives in the gateway config; sandboxes get
  per-task virtual keys (expiry + model allowlist) injected with
  `sbx secret set-custom`, so keys stay out of commands, history, and
  sandbox config.
- The gateway exposes the remote server's own model IDs; provider selection
  inside the agent is locked to the proxy (`enabled_providers`) with agent
  self-edit of its config denied.
- Acceptance for this section: the book ch 10.3 tool-loop test executed
  through the gateway from inside task-001 (plan's designated main risk).

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
