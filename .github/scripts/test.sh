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

D_A="sha256:$(printf 'a%.0s' {1..64})"
D_B="sha256:$(printf 'b%.0s' {1..64})"

newrepo() { # dir
  git init -q -b main "$1"
  git -C "$1" config user.name t
  git -C "$1" config user.email t@example.com
  git -C "$1" config commit.gpgsign false
}
commit() { git -C "$1" add -A && git -C "$1" commit -q --allow-empty -m "${2:-c}"; }

# --- content-tag.sh ---------------------------------------------------------
r="$work/ct"
newrepo "$r"
mkdir -p "$r/src" "$r/.github"
echo a > "$r/src/a.go"
echo m > "$r/go.mod"
printf '# inputs\nsrc\n\ngo.mod\n' > "$r/.github/image-inputs"
commit "$r"
t1="$("$ct" "$r" "$r/.github/image-inputs")"
[[ "$t1" =~ ^x-[0-9a-f]{16}$ ]] && ok "content tag shape ($t1)" || bad "content tag shape: $t1"

# The formula: sorted `path<TAB>oid` lines.
want="x-$(printf 'go.mod\t%s\nsrc\t%s\n' "$(git -C "$r" rev-parse HEAD:go.mod)" "$(git -C "$r" rev-parse HEAD:src)" | sha256sum | cut -c1-16)"
[ "$t1" = "$want" ] && ok "content tag formula" || bad "content tag formula: $t1 != $want"

printf 'go.mod\nsrc\n' > "$r/.github/image-inputs"
[ "$("$ct" "$r" "$r/.github/image-inputs")" = "$t1" ] && ok "input order does not matter" || bad "input order changed the tag"

echo b > "$r/src/a.go"; commit "$r"
[ "$("$ct" "$r" "$r/.github/image-inputs")" != "$t1" ] && ok "an input change changes the tag" || bad "input change kept the tag"
[ "$("$ct" "$r" "$r/.github/image-inputs" HEAD~1)" = "$t1" ] && ok "rev argument" || bad "rev argument"

echo nope >> "$r/.github/image-inputs"
if out="$("$ct" "$r" "$r/.github/image-inputs" 2>&1)"; then bad "missing input passed"; else
  grep -q 'missing at HEAD: nope' <<<"$out" && ok "missing input names the path" || bad "missing input message: $out"
fi
printf '# none\n' > "$r/.github/empty"
if "$ct" "$r" "$r/.github/empty" >/dev/null 2>&1; then bad "empty inputs passed"; else ok "empty inputs fail"; fi

# --- pin-check.sh -------------------------------------------------------------
img=ghcr.io/example/app
p="$work/pin"
newrepo "$p"
mkdir -p "$p/src" "$p/deploy" "$p/.github"
echo code > "$p/src/main.go"
echo src > "$p/.github/image-inputs"
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
kust() { # tag digest -> pin file text
  printf 'resources:\n  - deployment.yaml\nimages:\n  - name: %s\n' "$img"
  [ -n "$1" ] && printf '    newTag: %s\n' "$1"
  [ -n "$2" ] && printf '    digest: %s\n' "$2"
  true
}
kust unpinned "" > "$p/deploy/kustomization.yaml"
commit "$p" base
tag="$("$ct" "$p" "$p/.github/image-inputs")"

# Fake registry: a file of "tag digest" lines; missing tag = not found.
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

check() { # name, expected rules ("" = pass), expected text
  local name="$1" want_rules="$2" text="${3:-}" out rc=0 got
  out="$(cd "$p" && INPUTS=.github/image-inputs IMAGE="$img" PIN_FILE=deploy/kustomization.yaml \
    INSPECT="$work/inspect" BASE="${CHECK_BASE:-HEAD^1}" PIN_FIX="run pin" "$pc" 2>&1)" || rc=$?
  got="$(grep -oE '^pin rule [0-9]' <<<"$out" | awk '{print $3}' | paste -sd' ' - || true)"
  if [ "$got" != "$want_rules" ] || { [ -z "$want_rules" ] && [ "$rc" -ne 0 ]; } || { [ -n "$want_rules" ] && [ "$rc" -eq 0 ]; }; then
    bad "$name: rules '$got' (rc $rc), want '$want_rules'"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  if [ -n "$text" ] && ! grep -qF -- "$text" <<<"$out"; then
    bad "$name: output lacks '$text'"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  ok "$name"
}
pin() { kust "$1" "$2" > "$p/deploy/kustomization.yaml"; commit "$p" "pin: $1"; }

echo "$tag $D_A" > "$reg"
pin "$tag" "$D_A"
check "all rules hold; base unpinned" ""
pin "$tag" "$D_A"
git -C "$p" commit -q --allow-empty -m docs
check "docs-only commit, same pin as base" ""

pin "" ""
check "rule 1: no pin yet" "1" "pins no image yet"
pin "x-0000000000000000" "$D_A"
check "rule 1: stale tag" "1" "the pin is stale"

pin "$tag" "$D_A"
: > "$reg"
check "rule 2: not built (image job failed, or a fork)" "2" "not built"
touch "$work/registry-error"
check "rule 2: registry error is not 'not built'" "2" "cannot read"
rm "$work/registry-error"
echo "$tag $D_B" > "$reg"
check "rule 2: tag re-pushed under the pin" "2" "may have been re-pushed"

echo "$tag $D_A" > "$reg"
pin "$tag" "$D_A"
# A reference kustomize's images transformer does not rewrite.
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: c}\ndata:\n  spec: |\n    image: ghcr.io/example/app:latest\n' > "$p/deploy/cm.yaml"
kust "$tag" "$D_A" | sed 's/^  - deployment.yaml$/  - deployment.yaml\n  - cm.yaml/' > "$p/deploy/kustomization.yaml"
commit "$p"
check "rule 3: render does not use the pinned digest" "3" "the render references ghcr.io/example/app:latest"
rm "$p/deploy/cm.yaml"

# Only the entry for IMAGE counts: another image's pin is not this one.
printf 'resources:\n  - deployment.yaml\nimages:\n  - name: other\n    newTag: x-1\n    digest: %s\n  - name: %s\n    newTag: %s\n    digest: %s\n' "$D_B" "$img" "$tag" "$D_A" > "$p/deploy/kustomization.yaml"
commit "$p"
check "another image's entry is ignored" ""

pin "$tag" "$D_A"
pin "$tag" "$D_B"
echo "$tag $D_B" > "$reg"
check "rule 4: same tag, new digest" "4" "same tag $tag now has digest $D_B; escalate to the repo owner; change a hashed input to get a new tag"

pin "$tag" "$D_B"
CHECK_BASE=no-such-rev check "rule 4: unreadable base fails, not skipped" "4" "does not resolve"

# Components CI cannot fetch, dropped for the render.
pin "$tag" "$D_B"
{ printf 'components:\n  - https://example.invalid//nope?ref=1\n'; kust "$tag" "$D_B"; } > "$p/deploy/kustomization.yaml"
commit "$p"
out="$(cd "$p" && DROP_COMPONENTS=true INPUTS=.github/image-inputs IMAGE="$img" PIN_FILE=deploy/kustomization.yaml INSPECT="$work/inspect" "$pc" 2>&1)" \
  && ok "drop-components renders without the remote component" || { bad "drop-components"; printf '%s\n' "$out" | sed 's/^/    /'; }

# A local component stays in the render: one that sets the image is caught.
mkdir -p "$p/deploy/comp"
# The component adds a reference the images transformer does not rewrite.
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: evil}\ndata:\n  spec: |\n    image: %s:evil\n' "$img" > "$p/deploy/comp/cm.yaml"
printf 'apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nresources:\n  - cm.yaml\n' > "$p/deploy/comp/kustomization.yaml"
{ printf 'components:\n  - comp\n  - https://example.invalid//nope?ref=1\n'; kust "$tag" "$D_B"; } > "$p/deploy/kustomization.yaml"
commit "$p"
out="$(cd "$p" && DROP_COMPONENTS=true INPUTS=.github/image-inputs IMAGE="$img" PIN_FILE=deploy/kustomization.yaml INSPECT="$work/inspect" "$pc" 2>&1)" \
  && { bad "a local component's image reference was not rendered"; printf '%s\n' "$out" | sed 's/^/    /'; } \
  || { grep -q '^pin rule 3' <<<"$out" && ok "drop-components keeps local components in the render" || { bad "local component: wrong failure"; printf '%s\n' "$out" | sed 's/^/    /'; }; }
rm -r "$p/deploy/comp"

# Rule 3 matches the image name exactly, not as a prefix.
pin "$tag" "$D_B"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: c}\ndata:\n  spec: |\n    image: ghcr.io/example/app-sidecar:latest\n' > "$p/deploy/cm.yaml"
kust "$tag" "$D_B" | sed 's/^  - deployment.yaml$/  - deployment.yaml\n  - cm.yaml/' > "$p/deploy/kustomization.yaml"
commit "$p"
check "rule 3 ignores another image that shares the prefix" ""
rm "$p/deploy/cm.yaml"

# A base that names the image in a way the parser cannot read fails rule 4.
printf 'resources:\n  - deployment.yaml\nimages:\n- {name: %s, newTag: %s, digest: %s}\n' "$img" "$tag" "$D_A" > "$p/deploy/kustomization.yaml"
commit "$p"
pin "$tag" "$D_B"
check "rule 4: unreadable base entry fails, not read as unpinned" "4" "not in an images entry this check can read"

# A missing registry command is not "not built".
out="$(cd "$p" && INPUTS=.github/image-inputs IMAGE="$img" PIN_FILE=deploy/kustomization.yaml INSPECT="$work/no-such-command" "$pc" 2>&1)" || true
grep -q 'pin rule 2: the registry command .* is not installed' <<<"$out" && ! grep -q 'not built' <<<"$out" \
  && ok "a missing registry command is reported as such" || { bad "missing registry command"; printf '%s\n' "$out" | sed 's/^/    /'; }

if [ "$fails" -gt 0 ]; then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
