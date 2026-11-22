#!/usr/bin/env bash
# The pin check: the commit names its own image by content tag and digest,
# and that image exists. Run from the caller's checkout of the commit to
# check (a pull request's head, never GitHub's merge commit).
#
# The image name and the pin file come from the commit's .github/image.json,
# read through content-tag.sh --config, the same as the build and the pin
# script read it.
#
# Settings, from the environment:
#   BASE_DIR   a checkout of the base commit (a pull request's base, or the
#              previous commit on a push), for rule 4. Unset or empty: there
#              is no base, and rule 4 has nothing to compare.
#   RENDER_DIR directory to render for rule 3 (default: the pin file's)
#   DROP_COMPONENTS  true: render a copy without the remote entries of the
#              kustomization's top-level components: (ones CI cannot fetch).
#              Local components stay.
#   PIN_FIX    how to re-pin, shown in failures (default: run the pin script)
#   INSPECT    registry command (default: docker buildx imagetools inspect);
#              it gets `<ref> --format {{json .Manifest}}`
#   KUSTOMIZE  kustomize binary (default: kustomize)
#
# The pin file holds, in the images entry for the image:
#     newTag: r-<64 hex>
#     digest: sha256:<64 hex>
#
# Rules, each failure printed with its number, what is wrong and the fix:
#   1. the pinned tag is this commit's content tag;
#   2. the registry holds that tag, under the pinned digest;
#   3. the render references the image only by the pinned digest;
#   4. a tag the base already pins keeps its digest.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${BASE_DIR:-}"
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
      inside = (substr($0, RLENGTH + 1) == img); ind = RLENGTH - length("name: ")
      if (inside) print "#entry"
      next
    }
    inside && /^[[:space:]]*$/ { next }
    inside { match($0, /^[[:space:]]*/); if (RLENGTH <= ind - 2 || $0 ~ /^[[:space:]]*- /) inside = 0 }
    inside { print }
  ' <<<"$c")"
  if ! grep -qx '#entry' <<<"$entry"; then
    # No entry for IMAGE: unpinned, unless the file names IMAGE some other
    # way this parser does not follow (then say so, never read it as unpinned).
    # Comment lines don't count: a kustomization may describe the image in a
    # comment before it pins it.
    # Filtered into a variable first: `grep -v | grep -q` under pipefail
    # fails on SIGPIPE for a large file and would read as "no mention".
    nc="$(grep -v -E '^[[:space:]]*#' <<<"$c" || true)"
    if grep -qF -- "$IMAGE" <<<"$nc"; then
      echo "names ${IMAGE}, but not in an images entry this check can read (- name: ${IMAGE}, then newTag and digest)" >&2
      return 1
    fi
    echo unpinned
    return 0
  fi
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

# --- the image config --------------------------------------------------------
if ! config="$("$here/content-tag.sh" --config . HEAD 2>"$errd"/config.err)"; then
  fail 1 "cannot read the image config: $(cat "$errd"/config.err)" "fix .github/image.json or the file it names"
  exit 1
fi
IMAGE="$(jq -r .image <<<"$config")"
PIN_FILE="$(jq -r .pin_file <<<"$config")"
RENDER_DIR="${RENDER_DIR:-$(dirname "$PIN_FILE")}"

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
if ! want="$("$here/content-tag.sh" . HEAD 2>"$errd"/content-tag.err)"; then
  fail 1 "cannot compute the content tag: $(cat "$errd"/content-tag.err)" "fix .github/image.json or the file it names"
elif [ -z "$tag" ]; then
  fail 1 "${PIN_FILE} has no newTag for ${IMAGE}; this tree's content tag is ${want}" "$PIN_FIX"
elif [ "$tag" != "$want" ]; then
  fail 1 "pinned tag ${tag} is not this tree's content tag ${want}; the pin is stale" "$PIN_FIX"
fi

# --- rule 2 ----------------------------------------------------------------
if ! command -v "${inspect[0]}" >/dev/null; then
  fail 2 "the registry command ${inspect[0]} is not installed here" "run this check where ${inspect[0]} is available"
  want=""
fi
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
  elif ! grep -qi 'command not found' "$errd"/inspect.err &&
       grep -Eqi 'not found|MANIFEST_UNKNOWN|NAME_UNKNOWN' "$errd"/inspect.err; then
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
  # Drop only remote entries (a URL, or a github.com/ or git@ address) from
  # the top-level components: list. Local components stay in the render, so
  # one that sets the image is still checked.
  awk '
    /^components:/ { inc = 1; print; next }
    inc && /^[^[:space:]#-]/ { inc = 0 }
    inc && /^[[:space:]]*-[[:space:]]*"?([a-z]+:\/\/|github\.com\/|git@)/ { dropped++; next }
    { print }
    END { if (dropped == 0) exit 3 }
  ' "$k" > "$k.new" || { rc=$?; [ "$rc" -eq 3 ] || exit "$rc"; }
  mv "$k.new" "$k"
  dir="$tmp/render"
fi
if ! rendered="$("$KUSTOMIZE" build "$dir" 2>"$errd"/kustomize.err)"; then
  fail 3 "kustomize build ${RENDER_DIR} failed: $(tr '\n' ' ' <"$errd"/kustomize.err)" "fix the kustomization so it builds"
else
  refs="$(grep -oE "image:[[:space:]]*[\"']?${IMAGE//./\\.}([:@][^[:space:]\"']*)?([[:space:]\"']|\$)" <<<"$rendered" | sed -E "s/^image:[[:space:]]*[\"']?//; s/[[:space:]\"']+\$//" || true)"
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
if [ -z "$BASE_DIR" ]; then
  echo "pin: no base commit, so rule 4 has nothing to compare (a first push)"
elif [ ! -d "$BASE_DIR" ]; then
  fail 4 "cannot read the base pin: ${BASE_DIR} is not a checkout" "re-run this job; the base must be readable to rule out a re-pushed tag"
elif [ -f "${BASE_DIR}/${PIN_FILE}" ]; then
  base_content="$(cat "${BASE_DIR}/${PIN_FILE}")"
  if ! bp="$(pin_of "$base_content" 2>"$errd"/pin-of.err)"; then
    fail 4 "cannot read the base pin (${PIN_FILE}): $(cat "$errd"/pin-of.err)" "escalate to the repo owner: the base's pin file is malformed"
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
