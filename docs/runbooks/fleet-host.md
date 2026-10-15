# Runbook: fleet host preparation (coding-agent sandbox runtime)

Host-only layer. The package half is declared in `packages/apt/sbx.txt`
(repo bound via `packages/apt/repos/docker.*`); this runbook owns the host
state the package cannot carry: KVM access, service directories, the `sbx`
lockdown, the Tailscale administration path, and the memory/disk budget.
Design rationale lives in the reference book (ch 4–5); this file is the
operator contract for **this** machine.

## Machine facts (verified 2026-10-14)

| Item | Value | Consequence |
| --- | --- | --- |
| Release | Ubuntu 26.04.1 LTS (resolute), x86_64 | supported by `docker-sbx` |
| KVM | `/dev/kvm` group `kvm` (fleet account added 2026-10-14) + logind/uaccess ACL `user:<fleet-account>:rw-` | two access paths: ACL for the active seat session, group from the next login |
| RAM | 60 GiB (+7 GiB swap) | concurrency target is **3 tasks**, not the book's 10 |
| GPU | RTX 4090, 24 GiB, idle | **unallocated spare** — inference runs on a remote server (deviation from the book's running example) |
| Disk | 621 GiB root, ~544 GiB free | admission floor below |
| Engine | Ubuntu-archive `docker.io` 29.1.3 (group `docker`) | coexists; `sbx` does not need it and the docker-ce suite stays uninstalled |
| Tailscale | enrolled 2026-10-14 (`desktop-1`, `100.113.6.60`) | admin path below; host SSH still off |
| Fleet account | the desktop account (book ch 3.3 accepted trade-off); resolve the name live with `whoami` | everything below runs as the fleet account |

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
FLEET_ACCOUNT=$(whoami)                         # this runbook runs as the fleet account
sudo usermod -aG kvm "$FLEET_ACCOUNT"           # KVM access (re-login after)
sudo mkdir -p /srv/agent-sources /srv/agent-templates /srv/models
sudo chown "$FLEET_ACCOUNT:$FLEET_ACCOUNT" \
  /srv/agent-sources /srv/agent-templates /srv/models
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
(2026-10-14: all dirs incl. `agent-exchange` created and owned by the fleet account.)

## sbx lockdown (applied 2026-10-14, as the fleet account)

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
| Host state invisible | host home (`/home/<fleet-account>`) does not exist in the sandbox mount namespace; 0600 canary unreadable |
| Kit network override | **The `opencode` kit provisions an unremovable allow rule** (AI providers, GitHub, Ubuntu archives) on top of deny-all — `policy rm` refuses (`editable=false`, "recreated at sandbox create"), and it made `github.com` return 200 under "deny-all". Explicit `policy deny` rules **outrank** kit allows (measured: 401 → 403), so `fleet/envs/*.txt` carries a `deny` list neutralizing every provider/GitHub host; inference may only ever reach the gateway, GitHub only the Phase 6 broker |
| Kit toolchain gap | kit ships Node 22 (`corepack` cannot symlink into `/usr/bin` as agent); repo engines `>=24` + `engine-strict=true` → Node 24 tarball fetched to `~/.local/node` at env setup (`nodejs.org` allow rule; **no `xz` in the kit** — must take the `.tar.gz` dist). Phase 5 template retires this rule |
| pnpm store is filesystem-scoped | home (ext4) and clone (its own ext4 device) differ → pnpm silently fell back to a project-local `.pnpm-store/` **inside the clone**, which biome then linted (582 phantom errors). Fix in the profile's verify chain: `--store-dir ~/.pnpm-store` |

**Retired 2026-10-14**: task-001 (kit-bootstrap toolchain, per-sandbox
generated-placeholder secret) was superseded by template-built task-002
(see "Template bake") and removed with `sbx rm --force`; everything it
proved is restated on the template instance, and the toolchain rows above
are history — the bootstrap they describe now happens once, in a baker.

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
 7. **Revision of point 1, measured at gateway go-live (2026-10-14)**:
    per-task virtual keys are **not provided** — LiteLLM gates them behind
    its Prisma layer, whose runtime engine fetch violates the apps-layer
    provenance rule. Sandboxes share the master key, delivered as a
    placeholder custom secret (value source is a host `--command`,
    sandboxd-stored — not the OS keyring); isolation is network policy +
    injected placeholder, revocation is key rotation. See "Inference
    gateway" for the full contract.
 8. **Preview path revised from ch 14.4**: no `tailscale serve` route;
    preview ports publish directly on the tailscale0 address via
    `sbx ports`, see "Operator previews".
 9. **Template bake live (ch 12), measured 2026-10-14**: task environments
    are created from `fleet-typescript:2026-10-14.2` (publication records
    in `fleet/templates/`); the toolchain lives at `/opt/fleet/node` and
    reaches every shell through the kit's own
    `BASH_ENV=/etc/sandbox-persistent.sh` hook. The agent config cannot be
    baked at `~/.config/opencode/opencode.json` — the kit re-provisions
    that file at create (measured: fresh instance showed the kit's own
    271-byte file, the baked 1985-byte file gone) — so the template ships
    `/opt/fleet/opencode/config.json` and exports `OPENCODE_CONFIG`
    through the same hook. `set-custom` accepts `--placeholder` (fixed
    value) and defaults to GLOBAL scope, so the gateway credential is one
    fleet-wide secret, `sbx-cs-fleet-gateway`, whose placeholder is baked
    into the reviewed config; per-sandbox secret registration, `sbx exec
    -e` injection, and the first-contact gateway approval are all retired.
 10. **Phase 6 delivered (2026-10-14): first host MCP broker live** —
    git-push (`fleet/brokers/git-push.py`, registered as `broker-git` on
    the host clone). The §8.5 contract and measured boundary evidence
    live in "Host MCP broker". Extraction stays `git fetch
    sandbox-<task>` on the host; the broker adds the missing **publication**
    step for already-extracted `agent/*` branches.

Mount rules from the practitioner data (0.42.1): never `:ro`-mount a parent
of the clone root (sandbox fails to start); a rw mount sharing ancestry with
`:ro` mounts stays writable only if listed after them; workspace mounts are
frozen at creation; `--clone` refuses git worktrees.
(2026-10-14: re-verified on 0.48.0 via task-001 — all hold; see the
task-001 evidence table.)

## Inference gateway (LiteLLM, host)

Declared as app `litellm` (`packages/apps/litellm.txt`, vendored-tree
provenance — read its header before bumping). **Live since 2026-10-14** as
the `litellm.service` user unit (chezmoi-managed; `systemctl --user
status litellm`). Upstream: one OpenAI-compatible server on the LAN; its
URL and model id live in chezmoi data (`inferenceBaseUrl`,
`inferenceModel` in `~/.config/chezmoi/chezmoi.toml`), never in this repo;
the gateway serves the server's own model id, verbatim. Keys/bind in
`~/.config/litellm/gateway.env` (0600).

Operating contract (measured 2026-10-14):

- Serves `127.0.0.1:4000` only. Sandboxes reach it at
  `host.docker.internal:4000`; the egress proxy **normalizes that to
  policy resource `localhost:4000`** — allow rules on
  `host.docker.internal` do not match. With the fleet secret registered
  (below), first contact no longer raises a policy approval (measured
  2026-10-14 on task-002; approvals still guard resources without one).
- Credentials: ONE **global** custom secret with a **fixed placeholder**
  (revision 9): `sbx secret set-custom --host localhost --env
  GATEWAY_API_KEY --placeholder sbx-cs-fleet-gateway --command "grep
  '^LITELLM_MASTER_KEY=' ~/.config/litellm/gateway.env | cut -d= -f2"`.
  The sandbox only ever sees the **placeholder** — non-secret, safe in
  commands and committed configs; the proxy rewrites the `Authorization`
  header toward `localhost` with the real master key, which never enters
  the sandbox.
- Placeholder → real substitution is keyed on the placeholder value in
  `Authorization: Bearer …`. The openai-compatible SDK defaults to
  `x-api-key`, which the proxy does not rewrite — the fleet opencode
  config therefore pins `options.headers.Authorization` explicitly. The
  baked config carries the literal placeholder, so the old
  `sbx exec -e GATEWAY_API_KEY=<placeholder>` injection is retired;
  `sbx run` sessions additionally receive the env var from the secret.
- DB-less by necessity: LiteLLM virtual keys require Prisma, whose engine
  binary is fetched at runtime — violates the apps-layer provenance rule.
  Consequences: `/v1/models` answers "No connected db." (harmless; agents
  declare models statically; over the gateway the endpoint has since
  returned 500 — equally harmless, agents never call it), and
  **revocation = rotate `LITELLM_MASTER_KEY` in gateway.env +
  `systemctl --user restart litellm`** (invalidates all sandboxes at once
  — acceptable while the fleet is one host's own sandboxes; revisit with
  the ch 15 ledger db).
- Agent side: the reviewed config is `fleet/opencode/opencode.json`,
  baked to `/opt/fleet/opencode/config.json` and selected via
  `OPENCODE_CONFIG` (revision 9 — the kit re-provisions
  `~/.config/opencode/opencode.json` at create, so baking there is
  futile). It declares the provider with `baseURL
  `http://host.docker.internal:4000/v1`, pins `model` to
  `gateway/<server-model-id>`, and locks `enabled_providers:
  ["gateway"]` (measured: `opencode models` lists exactly one model on a
  fresh instance). File is root-owned 644 in the image: an in-sandbox
  agent's tamper attempt gets Permission denied; note the sandbox agent
  holds sudo, so this stops casual self-edits — what no agent can escape
  is the host-side network policy and the key that never enters the VM.
  Kit's `OPENAI_API_KEY=proxy-managed` is owned by the kit — never
  override it; a custom secret on that env name is shadowed (measured).
- Acceptance (ch 10.3 tool loop): **passed 2026-10-14 from inside
  task-001** — streamed `opencode run` task reasoned, called bash to
  locate a file, wrote `GATEWAY_TEST.md`, read it back, reported
  correctly; every inference hop traversed proxy → gateway → upstream.
  **Re-passed 2026-10-14 on template-built task-002** with the baked
  config alone (`opencode run` wrote and re-read `GATEWAY_LOOP.md`),
  proving nothing per-sandbox is needed anymore.
- Follow-ups: deny agent self-edit of its own config beyond file
  ownership (no filesystem policy verb in 0.48.0's `policy allow`; only
  `network` — investigate mounts or template re-bake).

## Operator previews (sbx ports on the tailnet)

Book ch 14 implemented 2026-10-14 with one topology revision: instead of
`tailscale serve` (ch 14.4 — needs root, persists across reboot, needs
its own cleanup step), preview ports are published **directly on the
tailscale0 address** — `sbx ports <task> --publish
<tailscale-ip>:<host-port>:<sandbox-port>/tcp4`. Same audience (tailnet
peers only, ACL-gated), no root, and the sandbox lifecycle owns the
route. Measured: `100.113.6.60:18001 → :3000` answered 200 while the LAN
interface refused the same port. The SSH-tunnel route (ch 14.3) stays as
the fallback whenever SSH reaches the host. Never publish on `0.0.0.0`
or the LAN address.

Contract per preview:

- Reserve host ports from a fixed table (`18001` app dev server, `18002`
  agent session), check conflicts first (`ss -tln`), and record the
  mapping `sbx ports --json` actually returned. The durable preview
  record lands with the ch 15 controller; until then the operator's task
  note is the record. `sbx ports` also auto-publishes sandbox port 9418
  (git) on ephemeral loopback — that is the extraction mechanism, not a
  preview.
- Guest dev servers: bind `0.0.0.0` **inside the sandbox** (measured:
  Next dev needs `--hostname 0.0.0.0`; its loopback-only default is
  unreachable through the publish path). Guest `curl` to non-loopback
  addresses traverses the egress proxy (`http_proxy`), so a 403 on a
  self-IP probe is the policy speaking, not the app. contexia's web dev
  server requires `CONTEXIA_API_URL` at boot; the full web+api+db preview
  needs the integration allow rules (deferred with compose), so today's
  verified preview served with a stub API URL — enough to prove every
  hop.
- Agent-session preview: `opencode serve --hostname 0.0.0.0 --port 4096`
  with `OPENCODE_SERVER_PASSWORD` set — without it the server is
  unsecured (it warns). Generate the password per session, keep it in
  `~/.local/state/fleet/previews/<task>.serve.pass` (0600), verify
  unauthenticated → 401 and basic-auth → 200, and delete the file at
  teardown.
- Teardown order (ch 14.6, measured): **unpublish first, verify the route
  is dead, then kill the guest processes**, then remove the password
  file. `sbx ports <task>` must show only the auto 9418 afterwards.
- Previews are generated output (ch 14.5): disposable data only; cookies
  are not port-scoped, so isolation-sensitive sessions need distinct
  hostnames, not just ports.

## Template bake (fleet-typescript)

Book ch 12, live 2026-10-14. Active publication:
`fleet/templates/fleet-typescript-2026-10-14.2.yaml` (identity matches
`template` in `fleet/envs/contexia.txt`). A template is never saved from a
completed task — only from a dedicated baker whose only inputs are the
declared ones below.

Recipe (all steps measured; re-verify anything that drifts):

1. `sbx create --name baker-ts --clone --skills off --cpus 4 --memory 8g
   opencode /srv/agent-sources/contexia` (baker needs no exchange mount).
2. Policy: the profile `deny` list, plus temporary allows
   `registry.npmjs.org:443, nodejs.org:443` (toolchain fetch only).
3. Toolchain (the sandbox agent has passwordless sudo **inside the VM** —
   that is how system paths become writable; it grants nothing on the
   host): fetch `node-v<ver>-linux-x64.tar.gz` (**no `xz` in the kit** →
   must be `.tar.gz`) + `SHASUMS256.txt` from nodejs.org, verify with
   `sha256sum -c`, unpack to `/opt/fleet/node`; then
   `NPM_CONFIG_PREFIX=/opt/fleet/node npm install -g pnpm@<ver>` — without
   the override npm lands pnpm in the kit's `/usr/local/share/npm-global`
   (measured).
4. Hook: append `export PATH=/opt/fleet/node/bin:$PATH` and
   `export OPENCODE_CONFIG=/opt/fleet/opencode/config.json` to
   `/etc/sandbox-persistent.sh`. The kit exports
   `BASH_ENV=/etc/sandbox-persistent.sh`, so **every** shell — `sbx exec`,
   agent tool shells, login shells — picks both up (measured: fresh `sbx
   exec` resolves node/pnpm with zero per-session setup).
5. Agent config: pipe `fleet/opencode/opencode.json` into
   `/opt/fleet/opencode/config.json` via `sudo tee` (leaves it
   root-owned 644 — agent tamper attempts get Permission denied,
   measured). Baking to `~/.config/opencode/opencode.json` does NOT work:
   the kit re-provisions that file at every create (revision 9).
6. Sentinels (12.3 markers, see inventory below), then the profile
   `verify` chain must go green in the baker.
7. Prune task residue: `git clean -xdff` the clone, remove sentinels that
   name tasks, stop background writers, `sbx stop baker-ts`.
   **`template save` on a running sandbox demands a `--force` flag that
   does not exist** (0.48.0 bug; `yes |` doesn't satisfy the TTY gate) —
   a stopped sandbox saves without prompting.
8. `sbx template save baker-ts fleet-typescript:<tag> --output
   /srv/agent-templates/fleet-typescript-<tag>.tar`; record sha256 + size
   in a `fleet/templates/<tag>.yaml` publication record; `sha256sum`
   honestly, never a borrowed number.
9. Accept on a fresh instance, not in the baker: `sbx create --name <task>
   ... --pull never -t fleet-typescript:<tag> opencode <clone> <exchange>`,
   converge profile rules **without** the toolchain allows, run the full
   verify chain + boundary probes + the gateway tool loop.
10. Bump the tag on every rebuild (caching is by tag); retire bakers and
    superseded tags/tars with `sbx rm --force` / `sbx template rm --force`.

Capture inventory (sentinels placed in the baker, inspected on a fresh
instance — what capture includes is measured, not assumed):

| Location | Survives capture | Note |
| --- | --- | --- |
| `/opt/fleet/node` (toolchain) | yes | sentinel content intact |
| `~/.cache` (download cache) | yes | |
| `~/.local/share/opencode` (kit storage) | yes | |
| `~/.pnpm-store` (warm store) | yes | 583-package fresh install + full chain: 1m49s |
| `/etc/sandbox-persistent.sh` hook | yes | both exports present |
| `/var/lib/docker` (VM docker store) | **no** | images pulled in-sandbox do not travel |
| task clone contents | n/a | reverted clean pre-save; fresh instances get a fresh clone — warm node_modules can never travel (mount) |
| `~/.config/opencode/opencode.json` | overwritten | kit re-provisions at create → `OPENCODE_CONFIG` mechanism |

Fresh-instance acceptance (task-002 from `2026-10-14.2`, 2026-10-14):
verify chain green 10/10 packages; `nodejs.org` probe **403** with the
baked toolchain fully working (the rule is genuinely retired); gateway
chat **200** via the baked placeholder with **no** first-contact approval;
`opencode models` lists exactly `gateway/qwen38-flash-next`; agent tool
loop wrote/re-read `GATEWAY_LOOP.md`; extraction probe `59b2f136` reached
the host clone with the declared identity (probe refs removed both sides,
clones clean).

## Host MCP broker (git-push)

Book §8.5, live 2026-10-14 (topology revision 10). §8.5 says: start with
**no** host MCP tools; when adding one, document implementation,
credential, operation set, and expected caller, and test its own boundary.
That is what this section is.

**Implementation.** `fleet/brokers/git-push.py` — an MCP stdio server
(JSON-RPC 2.0, protocol 2025-06-18) hand-rolled on the Python standard
library, pinned in-repo. Registered with
`sbx mcp add broker-git --command <abs path> --dir /srv/agent-sources/contexia`
(interface: `docs/records/sbx-0.48.0/sbx-mcp-add.txt`, `sbx-mcp-load.txt`).
`add` spawns and validates the server at the registration `--dir`. Docker's
own help text warns that `--command` servers run **on the host, as the host
user, with no sandboxing**; that is accepted here only because the reviewed
repo file is the whole implementation — no dependencies, no fetches, no
interpreter magic.

**Credential.** The broker process inherits the operator account's access
(ssh key to `origin`). Nothing credential-shaped ever crosses into a
sandbox: the agent sees tool results only. There is no secret to rotate
for the broker itself; revoking it is `sbx mcp rm broker-git --force`.

**Operation set (closed).**
- `push_branch{branch}` — `branch` must match
  `^agent/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$` with `..`, `@{`, `:`,
  whitespace, `~^?*[\` and dash/dot-leading segments refused; then the ref
  must exist locally (`git rev-parse --verify`); then
  `git push origin refs/heads/<b>:refs/heads/<b>` — the destination is
  **derived from** the source, so no input can name another destination.
  argv lists only, 120 s push timeout.
- `list_branches{}` — read-only `for-each-ref refs/heads/agent/`.
Repo dir and remote are fixed at registration, never tool args. The stdio
loop is single-threaded by construction: one push at a time. Every call —
including refusals — appends a JSON line to
`~/.local/state/fleet/brokers/git-push.jsonl` (host state, outside every
sandbox mount). `BROKER_GIT_DRY_RUN=1` is an operator-side registration
option only; note `sbx mcp add` has **no env flag** and spawns with the
daemon's environment, so dry-run cannot currently be set through an sbx
registration — a future converger must wrap it (e.g. a `--dry-run`
argv flag) if per-registration dry-run is wanted.

**Expected caller.** Fleet task sandboxes, attached at create with
`--static-mcp broker-git` or live with
`sbx mcp load broker-git --sandbox <task>`; the agent sees the tools
through the baked `mcp-gateway` config block. Workflow order matters: the
broker pushes **host-clone** branches, so extraction (`git fetch
sandbox-<task>`, revision 2) must land the `agent/*` branch on the host
before publication can name it.

**Boundary tests (measured, 2026-10-14).** Own boundary first, as an
inert harness (bare `origin.git` + staging clone under
`/tmp/opencode/broker-evidence`, rebuildable in four `git` commands):
pushes of `main`, `agent/x:refs/heads/main`, `agent/../main`, and
nonexistent `agent/ghost` were all refused; a real `agent/probe` push
reached the harness origin; audit lines matched call-for-call, refusals
included. Then through the real path: loaded live into task-002
(`sbx mcp load broker-git-test --sandbox task-002`), the in-sandbox agent
called the tools via the gateway — `agent/sbx-probe` pushed (audit shows
`[new branch]`, `dry_run: false` confirming daemon-env spawn), `main`
refused. One behavioral note worth keeping: the agent **reported a prompt
injection** inside the `list_branches` output; the audit holds the actual
bytes the tool returned — three `sha refs/heads/agent/*` lines, no prose —
so the "injection" was a model hallucination (correctly not acted on). The
audit log is the truth of what the agent saw; keep it that way.

Production registration `broker-git` (`--dir /srv/agent-sources/contexia`)
is live; the test registration was unloaded and removed. Pushing
`agent/*` branches to the real `origin` is the mechanism's purpose, but
has deliberately **not** been exercised against the real remote in this
evidence — the first real task does that.

## Tailscale administration path

- Enable host SSH only with a recovery connection already open (enabling it
  interrupts existing connections to the tailnet address):
  `sudo tailscale set --ssh`.
- Laptop connects as the fleet account with `ForwardAgent no`; never forward the
  laptop's SSH agent into the fleet account.
- Keep a second recovery route (local console) before touching SSH,
  firewall, kernel, or driver config.

## Reboot checklist (run after the first real reboot, then on maintenance)

1. Remote login as the fleet account works over the tailnet.
2. `sbx daemon` state reachable; sandboxes recover or are explained.
3. Disk above admission floor; `/srv` dirs intact.
4. Tailscale reconnected (`tailscale status`).

## Drift policy

`scripts/drift.sh` proves `docker-sbx` + repo files are present. The
lockdown settings, budget, and `/srv` inventory are this runbook's manual
half: re-run `sbx settings ls --json` and the boundary probes after any
runtime upgrade and treat differences as drift to reconcile here.
