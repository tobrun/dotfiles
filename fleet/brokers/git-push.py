#!/usr/bin/env python3
"""git-push host broker — the fleet's controlled publication path (book ch 8.5).

An MCP stdio server registered with `sbx mcp add --command`. Per Docker's
own warning, --command servers run on the HOST with full host-user
privileges and no sandboxing; that is accepted here ONLY because this file
is the entire implementation — reviewed, pinned in-repo, no dependencies
beyond the Python standard library. The broker is the crossing: the agent
gets exactly the operations below, everything else stays behind the host.

Contract (docs/runbooks/fleet-host.md "Host MCP broker"):
  repo      : the broker's cwd (fixed by `sbx mcp add --dir`), never a tool arg
  remote    : "origin", fixed, never a tool arg
  refspace  : refs/heads/agent/* only; the destination ref is derived from
              the source ref (same name), so no input can name another
              destination (no refspec crossing)
  audit     : one JSON line per call, host-side, outside any sandbox mount
  serial    : the stdio loop is single-threaded by construction — one
              push at a time, each under its own timeout
  dry-run   : BROKER_GIT_DRY_RUN=1 in the registration environment; callers
              inside a sandbox can neither see nor flip this switch
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "fleet-git-push", "version": "1.0.0"}
PUSH_TIMEOUT_S = 120
GIT_TIMEOUT_S = 10

# agent/<path>: git-safe charset, must start alphanumeric, no dot-leading
# segments, and separately rejected below: "..", "@{", leading dashes.
BRANCH_RE = re.compile(r"^agent/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
BAD_SUBSTRINGS = ("..", "@{", ":", " ", "\t", "\n", "~", "^", "?", "*", "[", "\\")

AUDIT_PATH = Path(
    os.environ.get(
        "BROKER_GIT_AUDIT",
        os.path.expanduser("~/.local/state/fleet/brokers/git-push.jsonl"),
    )
)
DRY_RUN = os.environ.get("BROKER_GIT_DRY_RUN") == "1"

TOOLS = [
    {
        "name": "push_branch",
        "description": (
            "Publish a LOCAL branch named agent/* from the task repository to "
            "the fleet remote under the same branch name. Only branches under "
            "agent/ are accepted; the default branch cannot be written."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "branch": {
                    "type": "string",
                    "description": "Local branch name, must match agent/<name>",
                }
            },
            "required": ["branch"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_branches",
        "description": "List local branches the broker may publish (agent/* only).",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def audit(entry: dict) -> None:
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    entry["dry_run"] = DRY_RUN
    AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with AUDIT_PATH.open("a") as fh:
        fh.write(json.dumps(entry, sort_keys=True) + "\n")


def git(*args: str, timeout: int = GIT_TIMEOUT_S) -> subprocess.CompletedProcess:
    # argv lists only — never shell=True, never interpolated strings.
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, timeout=timeout, cwd=os.getcwd()
    )


def branch_ok(branch) -> str | None:
    """Return a rejection reason, or None if the branch name is admissible."""
    if not isinstance(branch, str) or not BRANCH_RE.match(branch):
        return "branch must match ^agent/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"
    if any(s in branch for s in BAD_SUBSTRINGS):
        return "branch contains a rejected sequence"
    if any(part.startswith("-") or part.startswith(".") for part in branch.split("/")):
        return "branch segments may not start with '-' or '.'"
    return None


def call_push_branch(args: dict) -> tuple[str, bool]:
    branch = args.get("branch")
    reason = branch_ok(branch)
    if reason:
        audit({"tool": "push_branch", "branch": branch, "ok": False, "detail": reason})
        return f"refused: {reason}", True
    ref = f"refs/heads/{branch}"
    verify = git("rev-parse", "--verify", "--quiet", ref)
    if verify.returncode != 0:
        audit({"tool": "push_branch", "branch": branch, "ok": False, "detail": "ref not found"})
        return f"refused: local ref {ref} does not exist", True
    sha = verify.stdout.strip()
    cmd = ["push", "origin", f"{ref}:{ref}"]
    if DRY_RUN:
        cmd.insert(1, "--dry-run")
    try:
        push = git(*cmd, timeout=PUSH_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        audit({"tool": "push_branch", "branch": branch, "sha": sha, "ok": False,
               "detail": f"timeout after {PUSH_TIMEOUT_S}s"})
        return f"error: push timed out after {PUSH_TIMEOUT_S}s", True
    ok = push.returncode == 0
    audit({"tool": "push_branch", "branch": branch, "sha": sha, "ok": ok,
           "detail": (push.stderr or push.stdout).strip()[-400:]})
    if not ok:
        return f"push failed (rc={push.returncode}): {push.stderr.strip()[-400:]}", True
    return f"pushed {sha[:12]} -> origin/{branch}{' (dry-run)' if DRY_RUN else ''}", False


def call_list_branches(_args: dict) -> tuple[str, bool]:
    res = git("for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads/agent/")
    audit({"tool": "list_branches", "ok": res.returncode == 0,
           "detail": res.stdout.strip()[-200:]})
    if res.returncode != 0:
        return f"error: {res.stderr.strip()[-200:]}", True
    return res.stdout.strip() or "(no agent/* branches)", False


DISPATCH = {"push_branch": call_push_branch, "list_branches": call_list_branches}


def respond(msg_id, result=None, error=None) -> None:
    reply: dict = {"jsonrpc": "2.0", "id": msg_id}
    if error:
        reply["error"] = error
    else:
        reply["result"] = result
    sys.stdout.write(json.dumps(reply) + "\n")
    sys.stdout.flush()


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        method, msg_id = req.get("method"), req.get("id")
        if method == "initialize":
            respond(msg_id, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": SERVER_INFO,
            })
        elif method == "notifications/initialized":
            continue
        elif method == "ping":
            respond(msg_id, {})
        elif method == "tools/list":
            respond(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = req.get("params", {})
            name, args = params.get("name"), params.get("arguments", {})
            handler = DISPATCH.get(name)
            if not handler:
                respond(msg_id, {"content": [{"type": "text", "text": f"unknown tool {name}"}],
                                 "isError": True})
                continue
            try:
                text, is_error = handler(args if isinstance(args, dict) else {})
            except Exception as exc:  # never die mid-session; report the fault
                text, is_error = f"broker error: {exc}", True
                audit({"tool": name, "ok": False, "detail": repr(exc)})
            respond(msg_id, {"content": [{"type": "text", "text": text}],
                             "isError": is_error})
        elif msg_id is not None:
            respond(msg_id, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
