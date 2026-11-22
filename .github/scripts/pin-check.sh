#!/usr/bin/env bash
# The pin check: the commit names its own image by content tag and digest,
# and that image exists. Run from the caller's checkout, with the base commit
# available (fetch depth 2 or more).
#
# Settings, from the environment:
#   INPUTS     content-tag inputs file (required)
#   IMAGE      image name, e.g. ghcr.io/owner/app (required)
#   PIN_FILE   the kustomization that pins IMAGE (required)
#   BASE       revision to compare with for rule 4 (default HEAD^1: the base
#              branch on a pull request's merge ref, the previous commit on a
#              push)
#   RENDER_DIR directory to render for rule 3 (default: PIN_FILE's directory)
#   DROP_COMPONENTS  true: render a copy with the kustomization's top-level
#              `components:` removed, for components CI cannot fetch. Only
#              safe when they set no IMAGE.
#   PIN_FIX    how to re-pin, shown in failures (default: run the pin script)
#   INSPECT    registry command (default: docker buildx imagetools inspect);
#              it gets `<ref> --format {{json .Manifest}}`
#   KUSTOMIZE  kustomize binary (default: kustomize)
#
# The pin file holds, in the images entry for IMAGE:
#     newTag: x-<16 hex>
#     digest: sha256:<64 hex>
#
# Rules, each failure printed with its number, what is wrong and the fix:
#   1. the pinned tag is this tree's content tag;
#   2. the registry holds that tag, under the pinned digest;
#   3. the render references IMAGE only by the pinned digest;
#   4. a tag the base already pins keeps its digest.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${INPUTS:?set INPUTS}" "${IMAGE:?set IMAGE}" "${PIN_FILE:?set PIN_FILE}"
BASE="${BASE:-HEAD^1}"
RENDER_DIR="${RENDER_DIR:-$(dirname "$PIN_FILE")}"
DROP_COMPONENTS="${DROP_COMPONENTS:-false}"
PIN_FIX="${PIN_FIX:-run the pin script on the branch}"
KUSTOMIZE="${KUSTOMIZE:-kustomize}"
read -r -a inspect <<<"${INSPECT:-docker buildx imagetools inspect}"

errd="$(mktemp -d)"
trap 'rm -rf "$errd"' EXIT

failed=0
fail() { # rule, what, fix
  failed=$((failed + 1))
  printf 'pin rule %s: %s\n  fix: %s\n' "$1" "$2" "$3" >&2
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::error title=pin rule %s::%s. Fix: %s\n' "$1" "$2" "$3" >&2
  fi
}

digest_re='^sha256:[0-9a-f]{64}$'

# pin_of <content>: prints "<tag> <digest>" (tag may be empty), or fails.
# "unpinned" means no pin at all: no digest line, and no newTag line or the
# old placeholder `newTag: unpinned`.
pin_of() {
  local c="$1" entry digests tags
  # The images entry for IMAGE: from its `- name: IMAGE` line to the next
  # list item or a line indented less than the entry's keys.
  entry="$(awk -v img="$IMAGE" '
    match($0, /^[[:space:]]*- name:[[:space:]]*/) {
      inside = (substr($0, RLENGTH + 1) == img); ind = RLENGTH - length("name: "); next
    }
    inside && /^[[:space:]]*$/ { next }
    inside { match($0, /^[[:space:]]*/); if (RLENGTH <= ind - 2 || $0 ~ /^[[:space:]]*- /) inside = 0 }
    inside { print }
  ' <<<"$c")"
  digests="$(grep -E '^[[:space:]]+digest:[[:space:]]' <<<"$entry" || true)"
  tags="$(grep -E '^[[:space:]]+newTag:[[:space:]]' <<<"$entry" || true)"
  local nd nt
  nd="$(grep -c . <<<"$digests" || true)"
  nt="$(grep -c . <<<"$tags" || true)"
  if [ "$nd" -eq 0 ]; then
    if [ "$nt" -eq 0 ] || { [ "$nt" -eq 1 ] && [ "$(awk '{print $2}' <<<"$tags")" = unpinned ]; }; then
      echo unpinned
      return 0
    fi
  fi
  if [ "$nd" -ne 1 ] || [ "$nt" -gt 1 ]; then
    echo "want one digest line and at most one newTag line, found ${nd} and ${nt}" >&2
    return 1
  fi
  local d t=""
  d="$(awk '{print $2}' <<<"$digests")"
  if ! [[ "$d" =~ $digest_re ]]; then
    echo "digest '${d}' is not sha256:<64 hex>" >&2
    return 1
  fi
  [ "$nt" -eq 1 ] && t="$(awk '{print $2}' <<<"$tags")"
  echo "$t $d"
}

# --- the pin at HEAD -------------------------------------------------------
if ! content="$(git show "HEAD:${PIN_FILE}" 2>/dev/null)"; then
  fail 1 "cannot read ${PIN_FILE} at HEAD" "restore the pin file"
  exit 1
fi
if ! p="$(pin_of "$content" 2>"$errd"/pin-of.err)"; then
  fail 1 "${PIN_FILE}: $(cat "$errd"/pin-of.err)" "keep one images entry for ${IMAGE} with one newTag and one digest line"
  exit 1
fi
if [ "$p" = unpinned ]; then
  fail 1 "${PIN_FILE} pins no image yet (no digest)" "$PIN_FIX"
  exit 1
fi
read -r tag digest <<<"$p" || true
if [ -z "$digest" ]; then digest="$tag"; tag=""; fi

# --- rule 1 ----------------------------------------------------------------
want=""
if ! want="$("$here/content-tag.sh" . "$INPUTS" HEAD 2>"$errd"/content-tag.err)"; then
  fail 1 "cannot compute the content tag: $(cat "$errd"/content-tag.err)" "fix the paths in ${INPUTS}"
elif [ -z "$tag" ]; then
  fail 1 "${PIN_FILE} has no newTag for ${IMAGE}; this tree's content tag is ${want}" "$PIN_FIX"
elif [ "$tag" != "$want" ]; then
  fail 1 "pinned tag ${tag} is not this tree's content tag ${want}; the pin is stale" "$PIN_FIX"
fi

# --- rule 2 ----------------------------------------------------------------
if [ -n "$want" ]; then
  ref="${IMAGE}:${want}"
  if out="$("${inspect[@]}" "$ref" --format '{{json .Manifest}}' 2>"$errd"/inspect.err)"; then
    got="$(jq -r '.digest // empty' <<<"$out" 2>/dev/null || true)"
    if ! [[ "$got" =~ $digest_re ]]; then
      fail 2 "unexpected registry answer for ${ref}: ${out}" "re-run this job; if it keeps failing, check the registry"
    elif [ "$got" != "$digest" ] && [ "$tag" = "$want" ]; then
      fail 2 "pinned digest ${digest} is not the registry's digest ${got} for ${want}, and the pin already names this tree's tag: the tag may have been re-pushed" \
        "do not re-pin; escalate to the repo owner; change a hashed input to get a new tag"
    elif [ "$got" != "$digest" ]; then
      fail 2 "pinned digest ${digest} is not the registry's digest ${got} for ${want}" "$PIN_FIX"
    fi
  elif grep -Eqi 'not found|MANIFEST_UNKNOWN|NAME_UNKNOWN' "$errd"/inspect.err; then
    fail 2 "image ${ref} not built" \
      "wait for the image job on this pull request to pass, then ${PIN_FIX}. A pull request from a fork that changes image inputs cannot be built here; the repo owner handles it"
  else
    fail 2 "cannot read ${ref} from the registry: $(tr '\n' ' ' <"$errd"/inspect.err)" "re-run this job; if it keeps failing, check the registry"
  fi
fi

# --- rule 3 ----------------------------------------------------------------
dir="$RENDER_DIR"
if [ "$DROP_COMPONENTS" = true ]; then
  tmp="$(mktemp -d)"
  cp -R "$RENDER_DIR" "$tmp/render"
  k="$tmp/render/kustomization.yaml"
  # Drop the top-level components: list, up to the next top-level key.
  awk '/^components:/ {skip=1; next} skip && /^[^[:space:]#-]/ {skip=0} !skip' "$k" > "$k.new"
  mv "$k.new" "$k"
  dir="$tmp/render"
fi
if ! rendered="$("$KUSTOMIZE" build "$dir" 2>"$errd"/kustomize.err)"; then
  fail 3 "kustomize build ${RENDER_DIR} failed: $(tr '\n' ' ' <"$errd"/kustomize.err)" "fix the kustomization so it builds"
else
  refs="$(grep -oE "image:[[:space:]]*[\"']?${IMAGE//./\\.}[^[:space:]\"']*" <<<"$rendered" | sed -E "s/^image:[[:space:]]*[\"']?//" || true)"
  if [ -z "$refs" ]; then
    fail 3 "the render has no ${IMAGE} image at all" "keep the images entry for ${IMAGE} in ${PIN_FILE}"
  else
    bad="$(grep -v -- "@${digest}\$" <<<"$refs" | sort -u | paste -sd, - || true)"
    if [ -n "$bad" ]; then
      fail 3 "the render references ${bad}" "pin the image only through the images entry in ${PIN_FILE}; set no other image for ${IMAGE}"
    fi
  fi
fi

# --- rule 4 ----------------------------------------------------------------
if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  fail 4 "cannot read the base pin: revision ${BASE} does not resolve" "fetch at least two commits; the base must be readable to rule out a re-pushed tag"
elif [ -n "$(git ls-tree --name-only "$BASE" -- "$PIN_FILE")" ]; then
  base_content="$(git show "${BASE}:${PIN_FILE}")"
  if ! bp="$(pin_of "$base_content" 2>"$errd"/pin-of.err)"; then
    fail 4 "cannot read the base pin (${PIN_FILE} at ${BASE}): $(cat "$errd"/pin-of.err)" "escalate to the repo owner: the base's pin file is malformed"
  elif [ "$bp" != unpinned ]; then
    read -r btag bdigest <<<"$bp" || true
    if [ -n "$bdigest" ] && [ "$btag" = "$tag" ] && [ "$bdigest" != "$digest" ]; then
      fail 4 "same tag ${tag} now has digest ${digest}; escalate to the repo owner; change a hashed input to get a new tag" \
        "do not re-pin this tag. The base pinned ${bdigest}; a changed digest may mean the tag was re-pushed"
    fi
  fi
fi

if [ "$failed" -gt 0 ]; then
  echo "pin: ${failed} of 4 rules failed" >&2
  exit 1
fi
echo "pin: ok, ${IMAGE}:${tag}@${digest}"
