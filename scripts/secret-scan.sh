#!/usr/bin/env bash
# secret-scan.sh — read-only leak gate for this repo's content.
#
# Policy (AGENTS.md): the repo describes programs and installable
# environments only. It must never carry credentials, operator identity
# (account name, real name, email, private repo paths), or references to
# project checkouts under ~/ws/. Everything below enforces that classes;
# arbitrary project *names* cannot be detected mechanically and stay a
# review concern.
#
# Modes:
#   --staged (default)  scan only lines added to the index — what the
#                       pre-commit hook runs; pre-existing content never
#                       blocks an unrelated commit.
#   --all               audit every tracked file (read-only).
#
# Exit: 0 clean · 1 findings · 2 usage error.
#
# Exceptions (reviewed, minimal, each must say why it is safe):
#   ALLOW[name]   ERE matched against the offending LINE ('*' = any rule)
#   EXCL[name]    ERE matched against the file PATH ('*' = any rule)
# set -Eeuo pipefail
set -Eeuo pipefail
export LC_ALL=C

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"

usage() {
  printf 'usage: secret-scan.sh [--staged | --all]\n' >&2
  exit 2
}
mode=${1:---staged}
[[ $# -le 1 ]] || usage
case $mode in --staged | --all) ;; -h | --help) usage ;; *) usage ;; esac

note() { printf 'secret-scan: %s\n' "$*"; }

# re_escape <text> — quote ERE metacharacters in machine-derived values.
re_escape() {
  local s=$1 out= i c
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      '\' | '[' | ']' | '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '{' | '}' | '|') out+="\\$c" ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# --- rules: "category|name|ERE" (matching is case-insensitive) ---
RULES=()
add_rule() { RULES+=("$1|$2|$3"); }

# Credentials: fixed token shapes from issuers plus structural tells.
add_rule credential private-key      '-+BEGIN [A-Z ]*PRIVATE KEY-+'
add_rule credential github-token     '(^|[^A-Za-z0-9])(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,})'
add_rule credential gitlab-token     '(^|[^A-Za-z0-9])glpat-[A-Za-z0-9_-]{16,}'
add_rule credential openai-style-key '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'
add_rule credential aws-access-key   '(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}'
add_rule credential google-api-key   '(^|[^A-Za-z0-9])AIza[0-9A-Za-z_-]{35}'
add_rule credential slack-token      '(^|[^A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}'
add_rule credential slack-webhook    'hooks\.slack\.com/services/T[A-Z0-9]+'
add_rule credential discord-webhook  'discord(app)?\.com/api/webhooks/[0-9]+'
add_rule credential telegram-token   '(^|[^0-9])[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}'
add_rule credential npm-token        '(^|[^A-Za-z0-9])_npm_[A-Za-z0-9]{36}'
add_rule credential pypi-token       '(^|[^A-Za-z0-9])pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{20,}'
add_rule credential huggingface-token '(^|[^A-Za-z0-9])hf_[A-Za-z0-9]{30,}'
add_rule credential stripe-key       '(^|[^A-Za-z0-9])[spr]k_live_[A-Za-z0-9]{10,}'
add_rule credential jwt              '(^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
add_rule credential url-credentials  '://[^/[:space:]@]+:[^/[:space:]@]+@'
# key=value style assignment with a digit-bearing literal value of 8+ chars
# (variable references, digests, and placeholder prose cannot match).
add_rule credential credential-assignment "(api[_-]?key|access[_-]?token|auth(ization)?[_-]?token|secret[_-]?key|client[_-]?secret|password|passwd|token|secret)[[:space:]\"']*[=:][[:space:]\"']*[A-Za-z0-9+/.=-]*[0-9][A-Za-z0-9+/.=-]{7,}"

# Machine identity: derived at scan time, never hardcoded here.
operator_user=$(whoami)
add_rule identity operator-username "(^|[^A-Za-z0-9])$(re_escape "$operator_user")([^A-Za-z0-9]|$)"
while IFS= read -r word; do
  ((${#word} >= 4)) || continue
  add_rule identity operator-name "(^|[^A-Za-z0-9])$(re_escape "$word")([^A-Za-z0-9]|$)"
done < <(git config --get user.name 2>/dev/null || true)
operator_email=$(git config --get user.email 2>/dev/null || true)
[[ -n "$operator_email" ]] &&
  add_rule identity operator-email "$(re_escape "$operator_email")"
add_rule identity email-address '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# Project references: excluded state must not be named (AGENTS.md).
add_rule project project-checkout '(/home/[A-Za-z0-9._-]+|~)/ws($|[^A-Za-z0-9._-])'
add_rule project mdns-hostname    '(^|[^A-Za-z0-9-])[A-Za-z0-9-]{2,}\.local($|[^A-Za-z0-9-])'
while IFS= read -r url; do
  path=$(sed -E 's#^[a-z+]+://[^/]+/##; s#^[^/[:space:]]+:##; s#\.git$##' <<<"$url")
  [[ "$path" == */* ]] || continue
  add_rule project repo-remote "(^|[^A-Za-z0-9._/-])$(re_escape "$path")([^A-Za-z0-9._/-]|$)"
done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null | awk '{print $2}' || true)

# --- exceptions ---
declare -A ALLOW EXCL
# Declared gateway placeholder in fleet/envs/contexia.txt — a fixed
# placeholder, not a secret (see the file's header).
ALLOW['*']='sbx-cs-fleet-gateway'
# git@github.com is the ssh transport prefix, not a person; documentation
# addresses use reserved domains.
ALLOW['email-address']='git@github\.com|@(example\.[a-z]{2,4}|noreply\.[A-Za-z0-9.-]+|localhost)'
# The policy documents themselves may name the excluded-state location;
# the nvidia runbook's rebuild steps keep their self-checkout reference
# (reviewed 2026-10-15: it names this repo, no project).
EXCL['project-checkout']='^(AGENTS|README)\.md$|^docs/runbooks/nvidia-gpu\.md$'
# Vendor keyring headers must record the publisher UID (AGENTS.md vendor-repo
# recipe); those addresses belong to the vendor, not the operator.
# The fleet git identity in fleet/defaults.txt is a DECLARATION (file header:
# sandbox commits carry it deliberately), reviewed and kept 2026-10-15.
EXCL['operator-name']='^fleet/defaults\.txt$'
EXCL['operator-email']='^fleet/defaults\.txt$'
EXCL['email-address']='^packages/apt/repos/.*\.key\.asc$|^fleet/defaults\.txt$'
EXCL['*']='^scripts/(secret-scan\.sh|git-hooks/)'

# --- candidate stream: "file<TAB>line<TAB>text" ---
candidates() {
  if [[ "$mode" == --staged ]]; then
    # Added lines only; line numbers refer to the new file version.
    git diff --cached -U0 --diff-filter=ACM | awk '
      /^\+\+\+ b\// { file = substr($0, 7); next }
      /^@@/         { s = $0; sub(/^@@ [^ ]+ \+/, "", s); sub(/[, ].*$/, "", s); ln = s + 0; next }
      /^\+/         { printf "%s\t%d\t%s\n", file, ln, substr($0, 2); ln++; next }
      { next }'
  else
    local patfile out
    patfile=$(mktemp)
    for spec in "${RULES[@]}"; do
      spec=${spec#*|}
      printf '%s\n' "${spec#*|}"
    done >"$patfile"
    out=$(git grep -In -i -E -f "$patfile" -- . \
      ':' '!scripts/secret-scan.sh' ':' '!scripts/git-hooks' || true)
    rm -f -- "$patfile"
    [[ -n "$out" ]] || return 0
    awk '{ t = $0; f = t; sub(/:.*/, "", f); n = t; sub(/^[^:]+:/, "", n);
          sub(/:.*/, "", n); sub(/^[^:]+:[0-9]+:/, "", t);
          printf "%s\t%s\t%s\n", f, n, t }' <<<"$out" | sort -u
  fi
}

findings=()
scan_candidates() {
  local file ln text spec cat name re pat
  shopt -s nocasematch
  while IFS=$'\t' read -r file ln text; do
    [[ -n "$file" && -n "$text" ]] || continue
    for spec in "${RULES[@]}"; do
      cat=${spec%%|*}; spec=${spec#*|}
      name=${spec%%|*}; re=${spec#*|}
      [[ "$text" =~ $re ]] || continue
      pat=${EXCL["$name"]:-}
      [[ -z "$pat" || ! $file =~ $pat ]] || continue
      pat=${EXCL['*']:-}
      [[ -z "$pat" || ! $file =~ $pat ]] || continue
      pat=${ALLOW["$name"]:-}
      [[ -z "$pat" || ! $text =~ $pat ]] || continue
      pat=${ALLOW['*']:-}
      [[ -z "$pat" || ! $text =~ $pat ]] || continue
      findings+=("$cat/$name|$file:$ln|$text")
    done
  done
  shopt -u nocasematch
}

scan_candidates < <(candidates | sort -u)

if ((${#findings[@]} == 0)); then
  note 'ok — no leaks found'" (${mode#--})"
  exit 0
fi

note "${#findings[@]} finding(s) in ${mode#--} content:" >&2
for f in "${findings[@]}"; do
  rule=${f%%|*}; rest=${f#*|}
  loc=${rest%%|*}; text=${rest#*|}
  printf '  [%s] %s\n    | %s\n' "$rule" "$loc" "${text:0:160}" >&2
done
note 'these are leaks: scrub them, or record a commented exception in ALLOW/EXCL (scripts/secret-scan.sh).' >&2
exit 1
