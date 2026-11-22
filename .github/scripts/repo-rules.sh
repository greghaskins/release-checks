#!/usr/bin/env bash
# This repo's rules for workflows and actions, checked in every tracked YAML
# file. A strict text check, not a YAML parser: a match in a comment fails too.
#   1. No pull_request_target, in any form.
#   2. No secret except GITHUB_TOKEN, and in a reusable workflow the names it
#      declares under on.workflow_call.secrets (a caller passes those; this
#      repository stores none). Only the form `secrets.<NAME>` and the
#      declaration's own `secrets:` key pass; any other use of the word fails:
#      `secrets: inherit`, a job passing secrets on, `secrets['X']`,
#      `toJSON(secrets)`, a comment.
#   3. Every `uses:` is a local path (./...) or pinned to a full commit SHA.
#      Each `uses:` is checked on its own: two on a line, one in a comment or a
#      quoted key count too, and an empty value fails.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

mapfile -t files < <(git ls-files '*.yml' '*.yaml')
if [ "${#files[@]}" -eq 0 ]; then exit 0; fi

hits() {  # grep the YAML files: no match is fine, a grep error stops the check
  local rc=0
  grep -nHI "$@" "${files[@]}" || rc=$?
  [ "$rc" -le 1 ]
}

fail=0
report() {  # <hits> <message>
  if [ -n "$1" ]; then
    printf '%s\n' "$1"
    echo "::error::$2"
    fail=1
  fi
}

# Each check is assigned first, so a grep error stops the script (set -e).
out=$(hits -e 'pull_request_target')
report "$out" "pull_request_target is not allowed in this repo"

out=""
for f in "${files[@]}"; do
  # Names declared under on.workflow_call.secrets (parsed); a file that does
  # not parse fails here too.
  if ! declared="$(yq -r '(.on.workflow_call.secrets // {}) | keys | .[]' "$f" 2>&1)"; then
    out+="${f}: does not parse: ${declared}"$'\n'; continue
  fi
  allow='GITHUB_TOKEN'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [[ "$d" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { out+="${f}: declared name '${d}' is not a plain name"$'\n'; continue 2; }
    allow+="|${d}"
  done <<<"$declared"
  lines=$(grep -nI -i -w 'secrets' "$f" || [ $? = 1 ])
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    text="${line#*:}"
    # The declaration key itself, only when this file declares something.
    if [ "$allow" != GITHUB_TOKEN ] && [[ "$text" =~ ^[[:space:]]*secrets:[[:space:]]*$ ]] \
       && [ "$(yq -r '[.jobs[]? | select(has("secrets"))] | length' "$f")" = 0 ]; then
      continue
    fi
    rest=$(sed -E "s/secrets\.(${allow})([^A-Za-z0-9_]|$)/\2/g" <<<"$text")
    if grep -qiw 'secrets' <<<"$rest"; then out+="${f}:${line}"$'\n'; fi
  done <<<"$lines"
done
report "${out%$'\n'}" "GITHUB_TOKEN and this file's own workflow_call secrets are the only secrets allowed in this repo"

uses=$(hits -oE "\\buses[\"']?:[[:space:]]*[^[:space:],}]*")
pinned="uses[\"']?:[[:space:]]*[\"']?(\./[^\"']*|[^@\"']+@[0-9a-f]{40})[\"']?$"
out=$(grep -vE "$pinned" <<<"$uses" || [ $? = 1 ])
report "$out" "pin every action and reusable workflow to a full commit SHA"

exit "$fail"
