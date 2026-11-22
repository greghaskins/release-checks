#!/usr/bin/env bash
# Every file and path in the working tree that git does not ignore: all tracked
# files (including any committed despite matching .gitignore) and untracked
# files that are not ignored. Ignored, untracked files (local scratch, build
# output) are skipped. The files are copied into a temporary tree under the
# same relative paths, so findings and path rules read exactly as they would
# for the working tree itself.
set -euo pipefail
# shellcheck disable=SC1091  # env.sh, beside this script
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
root=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$root"
while IFS= read -r -d '' f; do
  # A tracked file deleted in the working tree has nothing to scan.
  [[ -e "$f" || -L "$f" ]] || continue
  mkdir -p "$tmp/$(dirname "$f")"
  cp -P -- "$f" "$tmp/$f"
done < <(git ls-files -z --cached --others --exclude-standard)
cd "$tmp"
# Findings are reported as file, rule id and fingerprint from the JSON report,
# never the matched text.
if ! gitleaks dir --redact --no-banner --exit-code 1 \
    --report-format json --report-path "$tmp.json" . >/dev/null 2>&1; then
  if [[ -s "$tmp.json" ]] && [[ $(jq 'length' "$tmp.json") -gt 0 ]]; then
    jq -r '.[] | "secret-scan: \(.File) matched rule \(.RuleID) (\(.Fingerprint))"' "$tmp.json" >&2
  else
    echo "secret-scan: the working tree scan failed" >&2
  fi
  rm -f "$tmp.json"
  exit 1
fi
rm -f "$tmp.json"
