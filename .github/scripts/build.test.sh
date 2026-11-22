#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok and bad never fail, so A && ok || bad is if-then-else
# Tests for build-context.sh and dockerfile-syntax.sh. Offline; TAP output.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
n=0; failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
bad() { n=$((n + 1)); echo "not ok $n - $1"; failed=1; }
git_() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }

# --- build-context.sh --------------------------------------------------------
r="$tmp/repo"; mkdir -p "$r/.github" "$r/src/sub" "$r/other"
git_ init -q "$r"
printf 'FROM scratch\nCOPY src /src\n' > "$r/Dockerfile"
printf 'hello\n' > "$r/src/a.txt"
printf '#!/bin/sh\necho hi\n' > "$r/src/run.sh"; chmod 0755 "$r/src/run.sh"
printf 'deep\n' > "$r/src/sub/b.txt"
ln -s a.txt "$r/src/link"
printf 'secret-ish\n' > "$r/other/not-in-set.txt"
printf 'x\n' > "$r/deploy.yaml"
printf '{"image":"ghcr.io/example/app","dockerfile":"Dockerfile","paths":["Dockerfile","src"],"pin_file":"deploy.yaml"}\n' > "$r/.github/image.json"
git_ -C "$r" add -A; git_ -C "$r" commit -q -m init
# A work-tree change that must not reach the context.
printf 'dirty\n' > "$r/src/a.txt"; printf 'untracked\n' > "$r/src/new.txt"

d="$tmp/ctx"
if "$here/build-context.sh" "$r" HEAD "$d" >"$tmp/out" 2>&1; then ok "build-context writes a context"; else bad "build-context failed: $(cat "$tmp/out")"; fi
want=$'.github/image.json\nDockerfile\nsrc/a.txt\nsrc/link\nsrc/run.sh\nsrc/sub/b.txt'
got="$(cd "$d" && find . -mindepth 1 \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort)"
[ "$got" = "$want" ] && ok "exactly the input set, nothing else" || bad "files: got [$got]"
[ ! -e "$d/.git" ] && ok "no .git in the context" || bad ".git in the context"
[ "$(cat "$d/src/a.txt")" = hello ] && ok "content from the commit, not the work tree" || bad "work-tree content leaked"
[ ! -e "$d/src/new.txt" ] && ok "untracked file left out" || bad "untracked file in the context"
[ -x "$d/src/run.sh" ] && [ ! -x "$d/src/a.txt" ] && ok "modes kept (0755 and 0644)" || bad "modes wrong"
[ -L "$d/src/link" ] && [ "$(readlink "$d/src/link")" = a.txt ] && ok "symlink kept as a link" || bad "symlink not kept"
m="$(find "$d" -mindepth 1 -printf '%T@\n' | sort -u | tr '\n' ' ')"
[ "$m" = "0.0000000000 " ] && ok "every mtime is 0, links and dirs included" || bad "mtimes: $m"
if "$here/build-context.sh" "$r" HEAD "$d" >/dev/null 2>&1; then bad "a non-empty destination was accepted"; else ok "refuses a non-empty destination"; fi
if "$here/build-context.sh" "$r" HEAD >/dev/null 2>&1; then bad "usage error not reported"; else [ $? -eq 2 ] && ok "usage error exits 2" || bad "usage error exit code"; fi
printf '{bad' > "$r/.github/image.json"; git_ -C "$r" commit -q -am broken
if "$here/build-context.sh" "$r" HEAD "$tmp/ctx2" >"$tmp/out" 2>&1; then bad "a bad config was accepted"; else grep -q 'content-tag: config' "$tmp/out" && ok "a content-tag rule failure stops it, with the rule" || bad "wrong error: $(cat "$tmp/out")"; fi

# --- dockerfile-syntax.sh ----------------------------------------------------
ds() { # name, want (pass|fail), dockerfile text, [allowlist text]
  local f="$tmp/Dockerfile.$n" a="$tmp/allow.$n"
  printf '%b' "$3" > "$f"; printf '%b' "${4:-}" > "$a"
  if "$here/dockerfile-syntax.sh" "$f" "$a" >"$tmp/out" 2>&1; then r=pass; else r=fail; fi
  [ "$r" = "$2" ] && ok "syntax: $1" || bad "syntax: $1 (want $2, got $r: $(cat "$tmp/out"))"
}
P="docker/dockerfile:1.12@sha256:$(printf 'a%.0s' {1..64})"
ds "no directive" pass 'FROM scratch\n'
ds "syntax directive" fail '# syntax=docker/dockerfile:1\nFROM scratch\n'
ds "any case, spaces" fail '#  SyNtAx  =  docker/dockerfile:1\nFROM scratch\n'
ds "no space after #" fail '#syntax=x\nFROM scratch\n'
ds "after another directive" fail '# escape=`\n# syntax=x\nFROM scratch\n'
ds "after a BOM" fail '\xef\xbb\xbf# syntax=x\nFROM scratch\n'
ds "allowlisted by digest" pass "# syntax=$P\nFROM scratch\n" "$P\n"
ds "allowlisted name, other digest" fail "# syntax=docker/dockerfile:1.12@sha256:$(printf 'b%.0s' {1..64})\nFROM scratch\n" "$P\n"
ds "after a comment, not a directive" pass '# hello\n# syntax=x\nFROM scratch\n'
ds "after a blank line, not a directive" pass '\n# syntax=x\nFROM scratch\n'
ds "after an instruction" pass 'FROM scratch\n# syntax=x\n'
ds "allowlisted by tag only" fail '# syntax=docker/dockerfile:1\nFROM scratch\n' 'docker/dockerfile:1\n'
ds "check directive is fine" pass '# check=skip=all\nFROM scratch\n'


# --- registry-state.sh (docker stubbed) ----------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$STUB" in
  index) echo '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:'"$(printf 'e%.0s' {1..64})"'","manifests":[{"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"linux","architecture":"amd64"}}]}' ;;
  attest) echo '{"digest":"sha256:'"$(printf 'e%.0s' {1..64})"'","manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"unknown","architecture":"unknown"}}]}' ;;
  single) echo '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:'"$(printf 'e%.0s' {1..64})"'"}' ;;
  variant) echo '{"digest":"sha256:'"$(printf 'e%.0s' {1..64})"'","manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}' ;;
  # ghcr's real answers through buildx (measured): a missing tag, package or
  # owner all read "<ref>: not found"; another repo's private package, 403.
  missing-tag) echo 'ERROR: ghcr.io/x/y:r-1: not found' >&2; exit 1 ;;
  denied) echo 'ERROR: unexpected status from HEAD request to https://ghcr.io/v2/x/y/manifests/r-1: 403 Forbidden' >&2; exit 1 ;;
  server) echo 'ERROR: unexpected status from HEAD request to https://ghcr.io/v2/x/y/manifests/r-1: 500 Internal Server Error' >&2; exit 1 ;;
  manifest-unknown) echo 'ERROR: ghcr.io/x/y:r-1: not found: MANIFEST_UNKNOWN: manifest unknown' >&2; exit 1 ;;
  net) echo 'ERROR: dial tcp: lookup ghcr.io: no such host' >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/docker"
rs() { # name, stub, want exit, want stdout prefix
  local out rc
  out="$(STUB="$2" PATH="$tmp/bin:$PATH" "$here/registry-state.sh" ghcr.io/x/y:r-1 2>"$tmp/err")"; rc=$?
  if [ "$rc" = "$3" ] && [[ "$out" == "$4"* ]]; then ok "registry-state: $1"; else bad "registry-state: $1 (rc=$rc out=[$out] err=[$(cat "$tmp/err")])"; fi
}
rs "an index of exactly amd64 and arm64 is found" index 0 "found sha256:"
rs "an index with an attestation entry fails" attest 1 ""
rs "a single-platform manifest fails" single 1 ""
rs "an arm64 variant does not count as linux/arm64" variant 1 ""
rs "ghcr's 'not found' is missing" missing-tag 0 missing
rs "MANIFEST_UNKNOWN wording is missing too" manifest-unknown 0 missing
rs "403 is an error, not missing" denied 1 ""
rs "500 is an error" server 1 ""
rs "a network error is an error" net 1 ""

echo "1..$n"
exit $failed
