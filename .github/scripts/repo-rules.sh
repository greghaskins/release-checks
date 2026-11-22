#!/usr/bin/env bash
# This repo's rules for workflows and actions, checked in every tracked YAML
# file. A strict text check, not a YAML parser: a match in a comment fails too.
#   1. No pull_request_target, in any form.
#   2. No secret except GITHUB_TOKEN: any other use of the secrets context
#      fails, `secrets: inherit` and `secrets['X']` included.
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

out=$(hits -iP '\bsecrets\b(?!\s*\.\s*GITHUB_TOKEN\b)')
report "$out" "GITHUB_TOKEN is the only secret allowed in this repo"

uses=$(hits -oE "\\buses[\"']?:[[:space:]]*[^[:space:],}]*")
pinned="uses[\"']?:[[:space:]]*[\"']?(\./[^\"']*|[^@\"']+@[0-9a-f]{40})[\"']?$"
out=$(grep -vE "$pinned" <<<"$uses" || [ $? = 1 ])
report "$out" "pin every action and reusable workflow to a full commit SHA"

exit "$fail"
