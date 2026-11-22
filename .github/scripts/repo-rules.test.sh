#!/usr/bin/env bash
# Tests for repo-rules.sh rule 2 (secrets), each in a scratch git repo. TAP.
# shellcheck disable=SC2015  # ok and bad never fail
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
n=0; failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
bad() { n=$((n + 1)); echo "not ok $n - $1"; failed=1; }
case_() { # name, want (pass|fail); workflow on stdin
  local d="$tmp/r$n" out rc
  mkdir -p "$d/.github/workflows"; git -C "$d" init -q
  cat > "$d/.github/workflows/w.yml"; git -C "$d" add -A
  out="$(cd "$d" && bash "$here/repo-rules.sh" 2>&1)"; rc=$?
  if { [ "$2" = pass ] && [ $rc -eq 0 ]; } || { [ "$2" = fail ] && [ $rc -ne 0 ]; }; then ok "$1"; else bad "$1 (want $2, rc=$rc): $out"; fi
}
case_ "GITHUB_TOKEN is allowed" pass <<'Y'
on: push
jobs: {a: {runs-on: x, steps: [{run: x, env: {T: "${{ secrets.GITHUB_TOKEN }}"}}]}}
Y
case_ "a declared workflow_call secret is allowed" pass <<'Y'
on:
  workflow_call:
    secrets:
      CFG:
        required: true
jobs: {a: {runs-on: x, steps: [{run: x, env: {C: "${{ secrets.CFG }}"}}]}}
Y
case_ "an undeclared secret fails" fail <<'Y'
on:
  workflow_call:
    secrets:
      CFG:
        required: true
jobs: {a: {runs-on: x, steps: [{run: x, env: {C: "${{ secrets.OTHER }}"}}]}}
Y
case_ "a secret with no workflow_call fails" fail <<'Y'
on: push
jobs: {a: {runs-on: x, steps: [{run: x, env: {C: "${{ secrets.CFG }}"}}]}}
Y
case_ "secrets by index fails, even when declared" fail <<'Y'
on:
  workflow_call:
    secrets:
      CFG:
        required: true
jobs: {a: {runs-on: x, steps: [{run: x, env: {C: "${{ secrets['CFG'] }}"}}]}}
Y
case_ "toJSON(secrets) fails" fail <<'Y'
on:
  workflow_call:
    secrets:
      CFG:
        required: true
jobs: {a: {runs-on: x, steps: [{run: x, env: {C: "${{ toJSON(secrets) }}"}}]}}
Y
case_ "secrets: inherit on a job fails" fail <<'Y'
on: push
jobs: {a: {uses: ./.github/workflows/x.yml, secrets: inherit}}
Y
case_ "a job passing a declared secret on fails" fail <<'Y'
on:
  workflow_call:
    secrets:
      CFG:
        required: true
jobs:
  a:
    uses: ./.github/workflows/x.yml
    secrets:
      CFG: ${{ secrets.CFG }}
Y
case_ "the word in a comment fails" fail <<'Y'
# keeps the secrets safe
on: push
jobs: {a: {runs-on: x, steps: [{run: x}]}}
Y
case_ "a declared name that prefixes another does not cover it" fail <<'Y'
on:
  workflow_call:
    secrets:
      CFG:
        required: true
jobs: {a: {runs-on: x, steps: [{run: x, env: {C: "${{ secrets.CFG_EXTRA }}"}}]}}
Y
case_ "a declared secret in a file that also runs on push fails" fail <<'Y'
on:
  push:
  workflow_call:
    secrets:
      CFG:
        required: true
jobs: {a: {runs-on: x, steps: [{run: x, env: {C: "${{ secrets.CFG }}"}}]}}
Y
case_ "workflow_call alone, in list form, still allows it" pass <<'Y'
on: [workflow_call]
jobs: {a: {runs-on: x, steps: [{run: x}]}}
Y
case_ "a YAML anchor carrying secrets: inherit fails" fail <<'Y'
on: push
x-defaults: &d {secrets: inherit}
jobs: {a: {<<: *d, uses: ./.github/workflows/x.yml}}
Y
echo "1..$n"
exit $failed
