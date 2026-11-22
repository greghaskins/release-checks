#!/usr/bin/env bash
# Tests for release.sh. Offline: `gh` is a stub that answers API paths from
# fixture files, and registry-state.sh is a fake. TAP output.
# shellcheck disable=SC2015  # ok and bad never fail, so A && ok || bad is if-then-else
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
n=0; failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
bad() { n=$((n + 1)); echo "not ok $n - $1"; failed=1; }

# --- stubs -------------------------------------------------------------------
# gh api <path> [--paginate] [--jq expr] [-f k=v ...]: answers from
# $FIX/<path with / as _>.json; a .404 file answers HTTP 404; a .err file
# answers its text as an error. gh release create records its arguments.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = release ] && [ "$2" = create ]; then printf '%s\n' "$@" > "$FIX/created"; cp "${@: -1}" "$FIX/notes" 2>/dev/null; exit 0; fi
[ "$1" = api ] || { echo "stub gh: unexpected: $*" >&2; exit 1; }
shift; path=""; q=""
while [ $# -gt 0 ]; do case "$1" in --jq) q="$2"; shift 2 ;; -f|-X) shift 2 ;; --paginate) shift ;; *) [ -n "$path" ] || path="$1"; shift ;; esac; done
f="$FIX/$(printf '%s' "${path%%\?*}" | tr '/' '_')"
if [ -f "$f.404" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
if [ -f "$f.err" ]; then cat "$f.err" >&2; exit 1; fi
[ -f "$f.json" ] || { echo "stub gh: no fixture for $path" >&2; exit 1; }
if [ -n "$q" ]; then jq -r "$q" "$f.json"; else cat "$f.json"; fi
STUB
chmod +x "$tmp/bin/gh"
# CHECKS: the real content-tag.sh, and a fake registry-state.sh answering $REGISTRY.
mkdir -p "$tmp/checks"
ln -s "$here/content-tag.sh" "$tmp/checks/content-tag.sh"
cat > "$tmp/checks/registry-state.sh" <<'STUB'
#!/usr/bin/env bash
case "$REGISTRY" in error) echo "registry-state: cannot read $1: 503" >&2; exit 1 ;; *) echo "$REGISTRY" ;; esac
STUB
chmod +x "$tmp/checks/registry-state.sh"
export PATH="$tmp/bin:$PATH" CHECKS="$tmp/checks" REPO=o/app GITHUB_STEP_SUMMARY=/dev/null

S=$(printf 'c%.0s' {1..40}); T=$(printf 'e%.0s' {1..40})
D="sha256:$(printf 'a%.0s' {1..64})"; D2="sha256:$(printf 'b%.0s' {1..64})"
RT="r-$(printf 'f%.0s' {1..64})"
fx() { mkdir -p "$FIX"; printf '%s' "$2" > "$FIX/$(printf '%s' "$1" | tr '/' '_').json"; }
fx404() { mkdir -p "$FIX"; : > "$FIX/$(printf '%s' "$1" | tr '/' '_').404"; }
fxerr() { mkdir -p "$FIX"; printf '%s' "$2" > "$FIX/$(printf '%s' "$1" | tr '/' '_').err"; }
newfix() { n_fix=$((${n_fix:-0} + 1)); export FIX="$tmp/fix$n_fix"; mkdir -p "$FIX"; }
run() { # want-rc, want-substring, args...
  local want="$1" sub="$2"; shift 2
  out="$("$here/release.sh" "$@" 2>&1)"; rc=$?
  [ "$rc" = "$want" ] && [[ "$out" == *"$sub"* ]]
}
st() { printf '{"context":"release-review","state":"%s","description":"%s","creator":{"id":%s,"login":"%s","type":"%s"}}' "$@"; }

# --- commit ------------------------------------------------------------------
export TAG=v0.2.0
newfix; fx repos/o/app/git/ref/tags/v0.2.0 "{\"object\":{\"type\":\"commit\",\"sha\":\"$S\"}}"
run 0 "$S" commit && ok "commit: a lightweight tag" || bad "commit: lightweight: $out"
newfix; fx repos/o/app/git/ref/tags/v0.2.0 "{\"object\":{\"type\":\"tag\",\"sha\":\"$T\"}}"; fx "repos/o/app/git/tags/$T" "{\"object\":{\"type\":\"commit\",\"sha\":\"$S\"}}"
run 0 "$S" commit && ok "commit: an annotated tag is peeled" || bad "commit: annotated: $out"
TAG=v1.0 run 1 "R1: v1.0 is not vMAJOR.MINOR.PATCH" commit && ok "commit: a non-SemVer tag fails first" || bad "commit: semver: $out"
newfix; fxerr repos/o/app/git/ref/tags/v0.2.0 "gh: Server Error (HTTP 502)"
run 1 "cannot read tag" commit && ok "commit: an API error fails" || bad "commit: error: $out"

# --- R0 ----------------------------------------------------------------------
export REVIEWER_ID=348096780
r0fix() { newfix; fx "repos/o/app/commits/$S/statuses" "[$1]"; }
r0fix "$(st success 'v0.2.0 reviewed' 348096780 rev Bot)"
run 0 "R0 ok" r0 "$S" && ok "R0: the reviewer's success naming the tag" || bad "R0 pass: $out"
REVIEWER_ID="" run 1 "RELEASE_REVIEWER_ID is not set" r0 "$S" && ok "R0: unset variable fails, naming it" || bad "R0 unset: $out"
r0fix "$(st failure x 41898282 gha Bot),$(st success 'v0.2.0' 348096780 rev Bot)"
run 0 "R0 ok" r0 "$S" && ok "R0: another account's newer failure is ignored" || bad "R0 other failure: $out"
r0fix "$(st success v0.2.0 41898282 gha Bot),$(st failure blocked 348096780 rev Bot)"
run 1 "is failure" r0 "$S" && ok "R0: the reviewer's latest is a failure" || bad "R0 reviewer failure: $out"
r0fix "$(st success v0.2.0 41898282 gha Bot)"
run 1 "no release-review from the reviewer" r0 "$S" && ok "R0: only another account" || bad "R0 only other: $out"
r0fix "$(st success 'v0.2.01 ok' 348096780 rev Bot)"
run 1 "names 'v0.2.01'" r0 "$S" && ok "R0: the first word must equal the tag" || bad "R0 word: $out"
r0fix "$(st success v0.2.0 348096780 rev User)"
run 1 "not a Bot" r0 "$S" && ok "R0: the account must be a Bot" || bad "R0 type: $out"
newfix; fxerr "repos/o/app/commits/$S/statuses" "gh: Server Error (HTTP 502)"
run 1 "cannot read the statuses" r0 "$S" && ok "R0: an API error fails" || bad "R0 error: $out"

# --- R1 ----------------------------------------------------------------------
r1base() { newfix; fx repos/o/app/git/matching-refs/tags/v "$1"; }
refs='[{"ref":"refs/tags/v0.1.0"},{"ref":"refs/tags/v0.1.2"},{"ref":"refs/tags/v0.2.0"},{"ref":"refs/tags/vendor"}]'
rel() { fx "repos/o/app/releases/tags/$1" "{\"author\":{\"id\":$2},\"draft\":${3:-false}}"; }
r1base "$refs"; rel v0.1.2 41898282; rel v0.1.0 41898282; fx "repos/o/app/compare/v0.1.2...$S" '{"status":"ahead"}'
run 0 "v0.1.2" r1 "$S" && [ "$(tail -1 <<<"$out")" = v0.1.2 ] && ok "R1: predecessor is the highest lower released tag" || bad "R1 pred: $out"
r1base "$refs"; rel v0.1.2 99; rel v0.1.0 41898282; fx "repos/o/app/compare/v0.1.0...$S" '{"status":"ahead"}'
run 0 "v0.1.0" r1 "$S" && ok "R1: a Release by someone else is not a predecessor" || bad "R1 author: $out"
r1base "$refs"; fx404 repos/o/app/releases/tags/v0.1.2; fx404 repos/o/app/releases/tags/v0.1.0
run 0 "first release" r1 "$S" && ok "R1: no released lower tag is the first release" || bad "R1 first: $out"
r1base "$refs"; fxerr repos/o/app/releases/tags/v0.1.2 "gh: Server Error (HTTP 502)"
run 1 "cannot read the Release for v0.1.2" r1 "$S" && ok "R1: a 502 on a Release stops, never skips" || bad "R1 502: $out"
r1base "$refs"; rel v0.1.2 41898282; fx "repos/o/app/compare/v0.1.2...$S" '{"status":"behind"}'
run 1 "does not descend from v0.1.2" r1 "$S" && ok "R1: the commit must descend from the predecessor" || bad "R1 descend: $out"
TAG=v0.1.0; r1base "$refs"; fx404 repos/o/app/releases/tags/v0.1.0
run 0 "first release" r1 "$S" && ok "R1: a re-run of an earlier tag looks only below it" || bad "R1 rerun: $out"
TAG=v0.2.0

# --- R2 ----------------------------------------------------------------------
newfix; fx "repos/o/app/compare/$S...main" '{"status":"ahead"}'
run 0 "on main" r2 "$S" && ok "R2: on main (main is ahead of it)" || bad "R2 ahead: $out"
newfix; fx "repos/o/app/compare/$S...main" '{"status":"identical"}'
run 0 "on main" r2 "$S" && ok "R2: the head of main" || bad "R2 identical: $out"
newfix; fx "repos/o/app/compare/$S...main" '{"status":"behind"}'
run 1 "not on main" r2 "$S" && ok "R2: ahead of main fails" || bad "R2 behind: $out"
newfix; fx "repos/o/app/compare/$S...main" '{"status":"diverged"}'
run 1 "not on main" r2 "$S" && ok "R2: diverged fails" || bad "R2 diverged: $out"

# --- R3 (a real git repo for APP; registry faked) ------------------------------
app="$tmp/app"; git init -q "$app"
mkpin() { # newTag digest
  mkdir -p "$app/.github" "$app/deploy"
  printf 'FROM scratch\n' > "$app/Dockerfile"; printf 'A=1\n' > "$app/args.env"
  printf '{"image":"ghcr.io/o/app","dockerfile":"Dockerfile","paths":["Dockerfile","args.env"],"pin_file":"deploy/kustomization.yaml","build_args_file":"args.env"}\n' > "$app/.github/image.json"
  printf 'images:\n  - name: ghcr.io/o/app\n    newTag: %s\n    digest: %s\n' "$1" "$2" > "$app/deploy/kustomization.yaml"
  git -C "$app" add -A; git -C "$app" -c user.name=t -c user.email=t@e -c commit.gpgsign=false commit -qm pin
  git -C "$app" rev-parse HEAD
}
export APP="$app"
c="$(mkpin "$RT" "$D")"
REGISTRY="found $D" run 0 "ghcr.io/o/app $RT $D" r3 "$c" && ok "R3: the pin's digest is the registry's" || bad "R3 pass: $out"
REGISTRY="found $D2" run 1 "but the pin names" r3 "$c" && ok "R3: a different registry digest fails" || bad "R3 digest: $out"
REGISTRY=missing run 1 "has no ghcr.io/o/app:$RT" r3 "$c" && ok "R3: a missing tag fails" || bad "R3 missing: $out"
REGISTRY=error run 1 "registry error" r3 "$c" && ok "R3: a registry error fails" || bad "R3 error: $out"
c="$(mkpin x-0123456789abcdef "$D")"
REGISTRY="found $D" run 1 "not r-<64 hex>" r3 "$c" && ok "R3: an x- pin fails" || bad "R3 x-: $out"
printf 'dirty\n' > "$app/deploy/kustomization.yaml"
c="$(git -C "$app" rev-parse HEAD~1)"
REGISTRY="found $D" run 0 "R3 ok" r3 "$c" && ok "R3: reads the commit, not the work tree" || bad "R3 worktree: $out"

# --- existing and publish --------------------------------------------------------
newfix; fx404 repos/o/app/releases/tags/v0.2.0
run 0 create existing "$S" "$D" && ok "existing: none, so create" || bad "existing none: $out"
newfix; fx repos/o/app/releases/tags/v0.2.0 "{\"author\":{\"id\":41898282},\"body\":\"x $S $D\"}"
run 0 skip existing "$S" "$D" && ok "existing: the same commit and digest, so skip" || bad "existing skip: $out"
newfix; fx repos/o/app/releases/tags/v0.2.0 "{\"author\":{\"id\":41898282},\"body\":\"x $S other\"}"
run 1 "never edited" existing "$S" "$D" && ok "existing: a different Release fails" || bad "existing different: $out"
newfix; fxerr repos/o/app/releases/tags/v0.2.0 "gh: Server Error (HTTP 502)"
run 1 "cannot read the Release" existing "$S" "$D" && ok "existing: a 502 fails" || bad "existing 502: $out"

c="$(mkpin "$RT" "$D")"
newfix; fx repos/o/app/releases/generate-notes '{"body":"## What changed\n- a PR"}'
if run 0 "Released v0.2.0" publish "$c" v0.1.2 ghcr.io/o/app "$RT" "$D"; then
  grep -qx -- '--verify-tag' "$FIX/created" && grep -q "content tag: \`$RT\`" "$FIX/notes" && grep -q "tag commit: \`$c\`" "$FIX/notes" \
    && grep -q 'build args: https://github.com/o/app/blob/v0.2.0/args.env' "$FIX/notes" && grep -q '## What changed' "$FIX/notes" \
    && ok "publish: one Release, generated notes plus tag, digest, commit, build args link" || bad "publish notes: $(cat "$FIX/notes" "$FIX/created")"
else bad "publish: $out"; fi

run 2 "usage" bogus && ok "usage error exits 2" || bad "usage: $out"

echo "1..$n"
exit $failed
