#!/usr/bin/env bash
# Tests for content-tag.sh and pin-check.sh, against throwaway git repos and a
# fake registry. Needs git, jq, sha256sum and kustomize on PATH.
# shellcheck disable=SC2015 # `check && ok || bad`: ok and bad always succeed
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ct="$here/content-tag.sh"
pc="$here/pin-check.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fails=$((fails + 1)); }
echo "# $(git --version)"

newrepo() { # dir
  git init -q -b main "$1" 2>/dev/null
  git -C "$1" config user.name t
  git -C "$1" config user.email t@example.com
  git -C "$1" config commit.gpgsign false
}
commit() { git -C "$1" add -A && git -C "$1" commit -q --allow-empty -m "${2:-c}"; }

# --- the golden vector ------------------------------------------------------
# A fixed tree. Object ids depend only on content and mode, so the tag and the
# list below hold for any git, any machine, any commit time. Changing them
# means a new scheme: every image re-tags.
r="$work/golden"
newrepo "$r"
mkdir -p "$r/.github" "$r/src" "$r/deploy"
printf 'FROM scratch\nCOPY src /src\n' > "$r/Dockerfile"
printf 'package main\n' > "$r/src/main.go"
printf 'x\n' > "$r/src/skip.txt"
printf '# v\nGO_VERSION=1.27\nBASE=sha256:abc\n' > "$r/versions.env"
printf 'images: []\n' > "$r/deploy/kustomization.yaml"
ln -s main.go "$r/src/link.go"
cat > "$r/.github/image.json" <<'EOF'
{"image":"ghcr.io/example/app","dockerfile":"Dockerfile","paths":["Dockerfile","src",":(exclude)src/skip.txt","versions.env"],"pin_file":"deploy/kustomization.yaml","build_args":{"APP":"demo"},"build_args_file":"versions.env"}
EOF
commit "$r"

golden_tag="r-438f9b5cefc3ee5242be480677db5f5e2c9e3860dae4a5653027e9d7636ef7c8"
golden_list="100644 bc9c61c4f2ca3c9d17f5eb8d8f5e06cc8bc0cd92	.github/image.json
100644 c8f2602b3c46c66e4b4e2e7d3af80a74afcb10af	Dockerfile
120000 30de63477f0746368e3b6fbd5272f0284f31f20e	src/link.go
100644 06ab7d0f9a35a7d1070711496d6ca1cb892a258f	src/main.go
100644 7520e115f289b2b072e69c3e18720f3c8572d26f	versions.env"

got="$("$ct" "$r" HEAD)"
[ "$got" = "$golden_tag" ] && ok "golden vector: tag" || bad "golden vector: tag $got, want $golden_tag"
got="$("$ct" --list "$r" HEAD | tr '\0' '\n')"
[ "$got" = "$golden_list" ] && ok "golden vector: --list" || { bad "golden vector: --list"; printf '%s\n' "$got" | sed 's/^/    /'; }
[ "$("$ct" --list "$r" HEAD | tail -c1 | od -An -c | tr -d ' ')" = '\0' ] && ok "--list records end in NUL" || bad "--list records do not end in NUL"
# The tag is the hash of the scheme line and exactly the --list records.
want="r-$( { echo 'release-checks content tag 1'; "$ct" --list "$r" HEAD | tr '\0' '\n'; } | sha256sum | cut -d' ' -f1)"
[ "$want" = "$golden_tag" ] && ok "the tag hashes the scheme line and the --list records" || bad "tag and --list disagree"
got="$("$ct" --build-args "$r" HEAD)"
[ "$got" = $'APP=demo\nBASE=sha256:abc\nGO_VERSION=1.27' ] && ok "--build-args merges both sources, sorted" || bad "--build-args: $got"
got="$("$ct" --config "$r" HEAD | jq -c .)"
[ "$got" = '{"image":"ghcr.io/example/app","dockerfile":"Dockerfile","target":null,"pin_file":"deploy/kustomization.yaml","paths":["Dockerfile","src",":(exclude)src/skip.txt","versions.env"],"build_args":{"APP":"demo","BASE":"sha256:abc","GO_VERSION":"1.27"}}' ] \
  && ok "--config" || bad "--config: $got"

# The work tree never counts; only the commit does.
echo changed > "$r/src/main.go"
[ "$("$ct" "$r" HEAD)" = "$golden_tag" ] && ok "an uncommitted change does not change the tag" || bad "the work tree changed the tag"
git -C "$r" checkout -q -- src/main.go

# --- usage and rules ----------------------------------------------------------
expect() { # name, exit code, stderr text, args...
  local name="$1" code="$2" text="$3" out rc=0
  shift 3
  out="$("$ct" "$@" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq "$code" ] && grep -qF -- "$text" <<<"$out"; then ok "$name"; else
    bad "$name: exit $rc, want $code with '$text'"; printf '%s\n' "$out" | sed 's/^/    /'; fi
}
expect "usage: no arguments" 2 "content-tag: usage:"
expect "usage: unknown option" 2 "unknown option --nope" --nope "$r" HEAD
expect "usage: not a commit" 2 "is not a commit" "$r" no-such-rev

c="$work/rules"
cfg() { mkdir -p "$c/.github"; printf '%s\n' "$1" > "$c/.github/image.json"; commit "$c"; }
base_cfg='{"image":"ghcr.io/example/app","dockerfile":"Dockerfile","paths":["Dockerfile","src"],"pin_file":"deploy/kustomization.yaml"}'
newrepo "$c"
mkdir -p "$c/.github" "$c/src" "$c/deploy"
printf 'FROM scratch\n' > "$c/Dockerfile"
printf 'a\n' > "$c/src/a.go"
printf 'images: []\n' > "$c/deploy/kustomization.yaml"
cfg "$base_cfg"
"$ct" "$c" HEAD >/dev/null && ok "the rules fixture passes" || bad "the rules fixture fails"

git -C "$c" rm -q .github/image.json && commit "$c"
expect "config: missing image.json" 1 "content-tag: config: .github/image.json is missing" "$c" HEAD
cfg '{not json'
expect "config: invalid JSON" 1 "content-tag: config: .github/image.json is not valid JSON" "$c" HEAD
cfg "$(jq -c '. + {extra: 1}' <<<"$base_cfg")"
expect "config: unknown key" 1 "content-tag: config: .github/image.json: unknown key extra" "$c" HEAD
cfg "$(jq -c 'del(.image)' <<<"$base_cfg")"
expect "config: missing image" 1 "content-tag: config: .github/image.json: image must be" "$c" HEAD
cfg "$(jq -c '.paths = []' <<<"$base_cfg")"
expect "config: empty paths" 1 "paths must be a non-empty array" "$c" HEAD

cfg "$(jq -c '.paths += [":(icase)src"]' <<<"$base_cfg")"
expect "pathspec-magic: icase" 1 "content-tag: pathspec-magic: :(icase)src" "$c" HEAD
cfg "$(jq -c '.paths += [":/src"]' <<<"$base_cfg")"
expect "pathspec-magic: short top" 1 "content-tag: pathspec-magic: :/src" "$c" HEAD
cfg "$(jq -c '.paths += [":(attr:x)src"]' <<<"$base_cfg")"
expect "pathspec-magic: attr" 1 "content-tag: pathspec-magic" "$c" HEAD
cfg "$(jq -c '.paths += [":(glob)src/*.go", ":(exclude)src/a.go"]' <<<"$base_cfg")"
"$ct" "$c" HEAD >/dev/null && ok "glob and exclude magic are allowed" || bad "glob/exclude rejected"

cfg "$(jq -c '.paths += ["nope"]' <<<"$base_cfg")"
expect "no-match: a plain path" 1 "content-tag: no-match: pathspec 'nope'" "$c" HEAD
cfg "$(jq -c '.paths += [":(exclude)nope"]' <<<"$base_cfg")"
expect "no-match: an exclude that excludes nothing" 1 "content-tag: no-match: pathspec ':(exclude)nope'" "$c" HEAD

cfg "$(jq -c '.paths = ["src"]' <<<"$base_cfg")"
expect "no-dockerfile" 1 "content-tag: no-dockerfile: the input set lacks the dockerfile Dockerfile" "$c" HEAD
cfg "$(jq -c '.build_args_file = "src/args"' <<<"$base_cfg")"
expect "no-build-args-file" 1 "content-tag: no-build-args-file: the input set lacks build_args_file src/args" "$c" HEAD
cfg "$(jq -c '.paths += ["deploy"]' <<<"$base_cfg")"
expect "pin-file-in-set" 1 "content-tag: pin-file-in-set: the input set holds the pin file" "$c" HEAD

cfg "$(jq -c '.paths = [":(exclude).github/image.json", "Dockerfile", "src"]' <<<"$base_cfg")"
"$ct" --list "$c" HEAD | tr '\0' '\n' | grep -q $'\t.github/image.json$' && ok "image.json is always in the set, even if excluded" || bad "image.json left out"

cfg "$base_cfg"
git -C "$c" update-index --add --cacheinfo "160000,$(git -C "$c" rev-parse HEAD),src/sub"
git -C "$c" commit -q -m sub
expect "submodule" 1 "content-tag: submodule: src/sub is a submodule" "$c" HEAD
git -C "$c" rm -q --cached src/sub && commit "$c"

printf 'x\n' > "$c/src/a"$'\t'"b"
commit "$c"
expect "control-byte: a TAB in a path" 1 "content-tag: control-byte" "$c" HEAD
rm "$c/src/a"$'\t'"b"
printf 'x\n' > "$c/src/a"$'\n'"b"
commit "$c"
expect "control-byte: a newline in a path" 1 "content-tag: control-byte" "$c" HEAD
rm "$c/src/a"$'\n'"b"; commit "$c"

ln -s /etc/passwd "$c/src/abs"; commit "$c"
expect "symlink-escape: absolute" 1 "content-tag: symlink-escape: src/abs -> /etc/passwd is absolute" "$c" HEAD
rm "$c/src/abs"; ln -s ../../x "$c/src/up"; commit "$c"
expect "symlink-escape: leaves the repo" 1 "content-tag: symlink-escape: src/up -> ../../x leaves the repo" "$c" HEAD
rm "$c/src/up"; ln -s ../deploy/kustomization.yaml "$c/src/out"; commit "$c"
expect "symlink-escape: outside the set" 1 "content-tag: symlink-escape: src/out -> ../deploy/kustomization.yaml resolves to deploy/kustomization.yaml, outside the input set" "$c" HEAD
rm "$c/src/out"; ln -s ../Dockerfile "$c/src/in"; commit "$c"
"$ct" "$c" HEAD >/dev/null && ok "a symlink inside the set is fine" || bad "an in-set symlink was rejected"
rm "$c/src/in"; commit "$c"

cfg "$(jq -c '.build_args = {"lower": "x"}' <<<"$base_cfg")"
expect "build-arg-key: lowercase" 1 "content-tag: build-arg-key: build_args: 'lower'" "$c" HEAD
cfg "$(jq -c '.build_args = {"BUILDKIT_X": "x"}' <<<"$base_cfg")"
expect "build-arg-key: BUILDKIT_" 1 "content-tag: build-arg-key: build_args: BUILDKIT_X starts with BUILDKIT_" "$c" HEAD
cfg "$(jq -c '.build_args = {"HTTPS_PROXY": "x"}' <<<"$base_cfg")"
expect "build-arg-key: proxy arg" 1 "HTTPS_PROXY is a predefined proxy arg" "$c" HEAD
printf 'A=1\nnoequals\n' > "$c/src/args"
cfg "$(jq -c '.build_args_file = "src/args"' <<<"$base_cfg")"
expect "build-arg-key: a file line without =" 1 "content-tag: build-arg-key: src/args:2: no '=' in the line" "$c" HEAD
printf 'A=1\nA=2\n' > "$c/src/args"; commit "$c"
expect "build-arg-duplicate: twice in the file" 1 "content-tag: build-arg-duplicate: src/args:2: A is given twice" "$c" HEAD
printf 'A=1\n' > "$c/src/args"
cfg "$(jq -c '.build_args_file = "src/args" | .build_args = {"A": "0"}' <<<"$base_cfg")"
expect "build-arg-duplicate: across both sources" 1 "content-tag: build-arg-duplicate: src/args:1: A is given twice" "$c" HEAD
cfg "$(jq -c '.build_args = {"A": "x\ny"}' <<<"$base_cfg")"
expect "build-arg-value: a newline in a value" 1 "content-tag: build-arg-value: build_args: A's value" "$c" HEAD
printf 'A=x\r\n' > "$c/src/args"
cfg "$(jq -c '.build_args_file = "src/args"' <<<"$base_cfg")"
expect "build-arg-value: a CR from a CRLF file" 1 "content-tag: build-arg-value: src/args:1: A's value" "$c" HEAD
# shellcheck disable=SC2016 # a literal $( ) on purpose: values are data
printf 'A=$(echo hi) "q"\n' > "$c/src/args"; commit "$c"
# shellcheck disable=SC2016
[ "$("$ct" --build-args "$c" HEAD)" = 'A=$(echo hi) "q"' ] && ok "build_args_file values are data, verbatim" || bad "build_args_file value changed"

# Review fixes: exact symlink targets, control bytes and duplicates in the
# config, plain config paths, the caller's environment, CONTENT_TAG.
cfg "$base_cfg"
# A symlink target can hold any bytes: make one with a newline in it.
blob="$(printf 'ok\n/../../../etc/passwd' | git -C "$c" hash-object -w --stdin)"
git -C "$c" update-index --add --cacheinfo "120000,${blob},src/sneaky"
git -C "$c" commit -q -m sneaky
expect "control-byte: a symlink target with a newline (not just its first line)" 1 "content-tag: control-byte: the symlink src/sneaky" "$c" HEAD
git -C "$c" rm -q --cached src/sneaky && commit "$c"
blob="$(printf 'main.go\0x' | git -C "$c" hash-object -w --stdin)"
git -C "$c" update-index --add --cacheinfo "120000,${blob},src/nul"
git -C "$c" commit -q -m nul
expect "control-byte: a symlink target with a NUL" 1 "content-tag: control-byte: the symlink src/nul" "$c" HEAD 2>/dev/null
git -C "$c" rm -q --cached src/nul && commit "$c"

cfg "$(jq -c '.paths = ["Dockerfile\nsrc"]' <<<"$base_cfg")"
expect "control-byte: a newline in a pathspec" 1 "content-tag: control-byte: .github/image.json: paths.0" "$c" HEAD
cfg "$(jq -c '.image = "ghcr.io/x\ny"' <<<"$base_cfg")"
expect "control-byte: a newline in image" 1 "content-tag: control-byte: .github/image.json: image" "$c" HEAD
cfg "$(jq -c '.pin_file = "deploy/k\ty"' <<<"$base_cfg")"
expect "control-byte: a TAB in pin_file" 1 "content-tag: control-byte: .github/image.json: pin_file" "$c" HEAD
cfg '{"image":"ghcr.io/example/app","dockerfile":"Dockerfile","paths":["Dockerfile"],"paths":["Dockerfile","src"],"pin_file":"deploy/kustomization.yaml"}'
expect "config: a key given twice" 1 "content-tag: config: .github/image.json: key paths is given twice" "$c" HEAD
cfg '{"image":"ghcr.io/example/app","dockerfile":"Dockerfile","paths":["Dockerfile","src"],"pin_file":"deploy/kustomization.yaml","build_args":{"A":"1","A":"2"}}'
expect "build-arg-duplicate: a key twice in build_args" 1 "content-tag: build-arg-duplicate: build_args: A is given twice" "$c" HEAD
cfg "$(jq -c '.pin_file = "./deploy/kustomization.yaml" | .paths += ["deploy"]' <<<"$base_cfg")"
expect "config: ./ in pin_file cannot dodge pin-file-in-set" 1 "content-tag: config: .github/image.json: pin_file './deploy/kustomization.yaml' must be a plain path" "$c" HEAD
cfg "$(jq -c '.dockerfile = "src/../Dockerfile"' <<<"$base_cfg")"
expect "config: .. in dockerfile" 1 "content-tag: config: .github/image.json: dockerfile" "$c" HEAD
cfg "$(jq -c '.build_args = {"CONTENT_TAG": "x"}' <<<"$base_cfg")"
expect "build-arg-key: CONTENT_TAG is reserved" 1 "content-tag: build-arg-key: build_args: CONTENT_TAG is reserved" "$c" HEAD
cfg "$(jq -c '.paths = ["Dockerfile", "src/*.go"]' <<<"$base_cfg")"
t1="$("$ct" "$c" HEAD)"
t2="$(GIT_LITERAL_PATHSPECS=1 GIT_ICASE_PATHSPECS=1 "$ct" "$c" HEAD)"
[ "$t1" = "$t2" ] && ok "GIT_*_PATHSPECS in the environment do not change the tag" || bad "GIT_*_PATHSPECS changed the tag ($t1 vs $t2)"

# --- pin-check.sh -------------------------------------------------------------
img=ghcr.io/example/app
p="$work/pin"
newrepo "$p"
mkdir -p "$p/src" "$p/deploy" "$p/.github"
printf 'FROM scratch\n' > "$p/Dockerfile"
echo code > "$p/src/main.go"
printf '{"image":"%s","dockerfile":"Dockerfile","paths":["Dockerfile","src"],"pin_file":"deploy/kustomization.yaml"}\n' "$img" > "$p/.github/image.json"
cat > "$p/deploy/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: app}
spec:
  selector: {matchLabels: {app: app}}
  template:
    metadata: {labels: {app: app}}
    spec:
      containers:
        - name: app
          image: ghcr.io/example/app:unset
EOF
D_A="sha256:$(printf 'a%.0s' {1..64})"
D_B="sha256:$(printf 'b%.0s' {1..64})"
kust() { # tag digest -> pin file text
  printf 'resources:\n  - deployment.yaml\nimages:\n  - name: %s\n' "$img"
  [ -n "$1" ] && printf '    newTag: %s\n' "$1"
  [ -n "$2" ] && printf '    digest: %s\n' "$2"
  true
}
kust unpinned "" > "$p/deploy/kustomization.yaml"
commit "$p" base
tag="$("$ct" "$p" HEAD)"

reg="$work/registry"
cat > "$work/inspect" <<EOF
#!/usr/bin/env bash
ref="\$1"; t="\${ref##*:}"
if [ -f "$work/registry-error" ]; then echo "dial tcp: timeout" >&2; exit 1; fi
d="\$(awk -v t="\$t" '\$1==t {print \$2}' "$reg")"
if [ -z "\$d" ]; then echo "\$ref: not found" >&2; exit 1; fi
printf '{"digest":"%s"}\n' "\$d"
EOF
chmod +x "$work/inspect"

basedir="$work/base"
setbase() { # rev: check out the base commit into $basedir
  rm -rf "$basedir"
  git -C "$p" worktree prune
  git -C "$p" worktree add -q --detach "$basedir" "$1"
}
check() { # name, expected rules ("" = pass), expected text
  local name="$1" want_rules="$2" text="${3:-}" out rc=0 got
  out="$(cd "$p" && BASE_DIR="${CHECK_BASE_DIR-$basedir}" INSPECT="$work/inspect" PIN_FIX="run pin" "$pc" 2>&1)" || rc=$?
  got="$(grep -oE '^pin rule [0-9]:' <<<"$out" | awk '{print $3}' | tr -d : | paste -sd' ' - || true)"
  if [ "$got" != "$want_rules" ] || { [ -z "$want_rules" ] && [ "$rc" -ne 0 ]; } || { [ -n "$want_rules" ] && [ "$rc" -eq 0 ]; }; then
    bad "$name: rules '$got' (rc $rc), want '$want_rules'"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  if [ -n "$text" ] && ! grep -qF -- "$text" <<<"$out"; then
    bad "$name: output lacks '$text'"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  ok "$name"
}
pin() { # tag digest: commit a pin, with the previous commit as the base
  kust "$1" "$2" > "$p/deploy/kustomization.yaml"
  setbase HEAD
  commit "$p" "pin: $1"
}

echo "$tag $D_A" > "$reg"
pin "$tag" "$D_A"
check "all rules hold; base unpinned" ""
setbase HEAD
git -C "$p" commit -q --allow-empty -m docs
check "docs-only commit, same pin as base" ""
CHECK_BASE_DIR="" check "no base (a first push)" ""

pin "" ""
check "rule 1: no pin yet" "1" "pins no image yet"
pin "r-$(printf '0%.0s' {1..64})" "$D_A"
check "rule 1: stale tag" "1" "the pin is stale"
pin "$tag" "$D_A"
printf '{bad' > "$p/.github/image.json"; setbase HEAD; commit "$p"
check "rule 1: an image.json that does not validate" "1" "cannot read the image config: content-tag: config:"
printf '{"image":"%s","dockerfile":"Dockerfile","paths":["Dockerfile","src"],"pin_file":"deploy/kustomization.yaml"}\n' "$img" > "$p/.github/image.json"
commit "$p"

pin "$tag" "$D_A"
: > "$reg"
check "rule 2: not built (image job failed, or a fork)" "2" "not built"
touch "$work/registry-error"
check "rule 2: registry error is not 'not built'" "2" "cannot read"
rm "$work/registry-error"
echo "$tag $D_B" > "$reg"
check "rule 2: tag re-pushed under the pin" "2" "may have been re-pushed"
echo "$tag $D_A" > "$reg"
out="$(cd "$p" && BASE_DIR="$basedir" INSPECT="$work/no-such-command" "$pc" 2>&1)" || true
grep -q 'pin rule 2: the registry command .* is not installed' <<<"$out" && ! grep -q 'not built' <<<"$out" \
  && ok "rule 2: a missing registry command is reported as such" || { bad "missing registry command"; printf '%s\n' "$out" | sed 's/^/    /'; }

printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: c}\ndata:\n  spec: |\n    image: ghcr.io/example/app:latest\n' > "$p/deploy/cm.yaml"
kust "$tag" "$D_A" | sed 's/^  - deployment.yaml$/  - deployment.yaml\n  - cm.yaml/' > "$p/deploy/kustomization.yaml"
setbase HEAD; commit "$p"
check "rule 3: render does not use the pinned digest" "3" "the render references ghcr.io/example/app:latest"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: c}\ndata:\n  spec: |\n    image: ghcr.io/example/app-sidecar:latest\n' > "$p/deploy/cm.yaml"
setbase HEAD; commit "$p"
check "rule 3 ignores another image that shares the prefix" ""
rm "$p/deploy/cm.yaml"
printf 'resources:\n  - deployment.yaml\nimages:\n  - name: other\n    newTag: x-1\n    digest: %s\n  - name: %s\n    newTag: %s\n    digest: %s\n' "$D_B" "$img" "$tag" "$D_A" > "$p/deploy/kustomization.yaml"
setbase HEAD; commit "$p"
check "another image's entry is ignored" ""

pin "$tag" "$D_A"
pin "$tag" "$D_B"
echo "$tag $D_B" > "$reg"
check "rule 4: same tag, new digest" "4" "same tag $tag now has digest $D_B; escalate to the repo owner; change a hashed input to get a new tag"
CHECK_BASE_DIR="$work/no-such-dir" check "rule 4: a base that is not a checkout fails" "4" "is not a checkout"
printf 'resources:\n  - deployment.yaml\nimages:\n- {name: %s, newTag: %s, digest: %s}\n' "$img" "$tag" "$D_A" > "$p/deploy/kustomization.yaml"
commit "$p"
pin "$tag" "$D_B"
check "rule 4: unreadable base entry fails, not read as unpinned" "4" "not in an images entry this check can read"

# Components: remote entries are dropped for the render, local ones stay.
pin "$tag" "$D_B"
{ printf 'components:\n  - https://example.invalid//nope?ref=1\n'; kust "$tag" "$D_B"; } > "$p/deploy/kustomization.yaml"
setbase HEAD; commit "$p"
out="$(cd "$p" && DROP_COMPONENTS=true BASE_DIR="$basedir" INSPECT="$work/inspect" "$pc" 2>&1)" \
  && ok "drop-components renders without the remote component" || { bad "drop-components"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$p/deploy/comp"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: evil}\ndata:\n  spec: |\n    image: %s:evil\n' "$img" > "$p/deploy/comp/cm.yaml"
printf 'apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nresources:\n  - cm.yaml\n' > "$p/deploy/comp/kustomization.yaml"
{ printf 'components:\n  - comp\n  - https://example.invalid//nope?ref=1\n'; kust "$tag" "$D_B"; } > "$p/deploy/kustomization.yaml"
setbase HEAD; commit "$p"
out="$(cd "$p" && DROP_COMPONENTS=true BASE_DIR="$basedir" INSPECT="$work/inspect" "$pc" 2>&1)" \
  && { bad "a local component's image reference was not rendered"; printf '%s\n' "$out" | sed 's/^/    /'; } \
  || { grep -q '^pin rule 3' <<<"$out" && ok "drop-components keeps local components in the render" || { bad "local component: wrong failure"; printf '%s\n' "$out" | sed 's/^/    /'; }; }

if [ "$fails" -gt 0 ]; then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
