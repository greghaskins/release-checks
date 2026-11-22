#!/usr/bin/env bash
# Content and commit messages of every commit in BASE..HEAD. A BASE that is
# unknown (a brand-new branch) or not an ancestor falls back to the last 50
# commits, which is never silently nothing. Exemptions live in the private
# gitleaks config (its allowlists). A repository may also exempt single
# findings by fingerprint in its .gitleaksignore, which gitleaks reads for the
# content scan and this script passes to the message scan.
set -euo pipefail
# shellcheck disable=SC1091  # env.sh, beside this script
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
base=${1:?base}; head=${2:?head}
git rev-parse -q --verify "$head^{commit}" >/dev/null || { echo "secret-scan: unknown head commit" >&2; exit 1; }
if [[ "$base" =~ ^0+$ ]] || ! git merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
  range="-n 50 $head"
else
  range="$base..$head"
fi
root=$(git rev-parse --show-toplevel)
ignore=()
if [[ -f "$root/.gitleaksignore" ]]; then
  ignore=(--gitleaks-ignore-path "$root/.gitleaksignore")
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
# Content findings are reported as file, commit, rule id and fingerprint from
# the JSON report, never the matched text.
# shellcheck disable=SC2086
if ! gitleaks git --redact --no-banner --exit-code 1 \
    --report-format json --report-path "$tmp/content.json" --log-opts="$range" . >/dev/null 2>&1; then
  fail=1
  if [[ -s "$tmp/content.json" ]] && [[ $(jq 'length' "$tmp/content.json") -gt 0 ]]; then
    while IFS=$'\t' read -r file commit rule fingerprint; do
      echo "secret-scan: $file in commit $commit matched rule $rule ($fingerprint)" >&2
    done < <(jq -r '.[] | [.File, .Commit, .RuleID, .Fingerprint] | @tsv' "$tmp/content.json")
  else
    echo "secret-scan: the commit content scan failed" >&2
  fi
fi

# Every message in the range becomes one file named by its full commit SHA, and
# one gitleaks scan covers the directory. Run from inside it, on ".", so the
# reported path is the bare SHA and a finding's fingerprint is
# <sha>:<rule-id>:<line>, independent of the temporary directory. gitleaks'
# output is discarded (it must never print matched text); only the commit and
# the fingerprint are reported, from the JSON report.
mkdir "$tmp/messages"
# shellcheck disable=SC2086
for c in $(git rev-list $range); do
  git log -1 --format=%B "$c" >"$tmp/messages/$c"
done
rc=0
(cd "$tmp/messages" && gitleaks dir --redact --no-banner --exit-code 1 ${ignore[@]+"${ignore[@]}"} \
  --report-format json --report-path "$tmp/report.json" . >/dev/null 2>&1) || rc=$?
if [[ $rc -ne 0 ]]; then
  fail=1
  found=0
  if [[ -s "$tmp/report.json" ]]; then
    while IFS=$'\t' read -r file fingerprint; do
      echo "secret-scan: commit message $file matched secret scanning ($fingerprint)" >&2
      found=1
    done < <(jq -r '.[] | [.File, .Fingerprint] | @tsv' "$tmp/report.json")
  fi
  if [[ $found -eq 0 ]]; then
    echo "secret-scan: the commit message scan failed (gitleaks exit status $rc)" >&2
  fi
fi
exit $fail
