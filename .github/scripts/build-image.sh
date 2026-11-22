#!/usr/bin/env bash
# One platform of build.yml: builds an app's image from its input set alone.
#
#   build-image.sh push    build, push by digest, print `digest=` to
#                          $GITHUB_OUTPUT
#   build-image.sh cache   on main's head only: build to the registry cache
#                          tag buildcache-<arch>, push no image
#
# Run from the job's work directory, with the app checked out at caller/ and
# release-checks at checks/. Environment: ARCH (amd64|arm64), COMMIT, TAG,
# IMAGE, TOKEN, ACTOR, BUILDKIT_IMAGE, SOURCE_DATE_EPOCH; cache mode also REPO.
#
# The build context is the input set and nothing else (build-context.sh). The
# Dockerfile may not pick its frontend unless allowlisted
# (dockerfile-syntax.sh). Build args come from the config; CONTENT_TAG is set
# here; a BUILDKIT_* arg would steer BuildKit itself and fails. No
# entitlements, no provenance or SBOM, timestamps rewritten to
# SOURCE_DATE_EPOCH so equal inputs give equal digests.
set -euo pipefail
export LC_ALL=C
mode="${1:-}"
case "$mode" in push | cache) ;; *) echo "usage: build-image.sh push|cache" >&2; exit 2 ;; esac
case "${ARCH:-}" in amd64 | arm64) ;; *) echo "build-image: ARCH must be amd64 or arm64" >&2; exit 2 ;; esac
for v in COMMIT TAG IMAGE TOKEN ACTOR BUILDKIT_IMAGE; do
  [ -n "${!v:-}" ] || { echo "build-image: ${v} is not set" >&2; exit 2; }
done
s=checks/.github/scripts
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1" >> "$GITHUB_STEP_SUMMARY"; }

# Cache writes only from the current head of main: a re-run of an old main run
# must not roll the cache back. If that cannot be told, write nothing, stay
# green. The token is passed to this one command, never stored.
if [ "$mode" = cache ]; then
  auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)"
  echo "::add-mask::$auth"
  if ! head="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="$auth" \
         git ls-remote "https://github.com/${REPO}.git" refs/heads/main 2>/dev/null | cut -f1)" || [ -z "$head" ]; then
    echo "::warning::cannot read main's head; the ${ARCH} cache is not written"
    summary "- warning: cannot read main's head; the ${ARCH} cache is not written"
    exit 0
  fi
  if [ "$head" != "$COMMIT" ]; then
    echo "main has moved on (${head}); the ${ARCH} cache is left for that run"
    exit 0
  fi
fi

# The commit and the tag must still agree (the tag job computed it).
got="$("$s/content-tag.sh" caller "$COMMIT")"
[ "$got" = "$TAG" ] || { echo "build-image: content tag ${got} differs from the tag job's ${TAG}" >&2; exit 1; }
config="$("$s/content-tag.sh" --config caller "$COMMIT")"
dockerfile="$(jq -r .dockerfile <<<"$config")"
target="$(jq -r '.target // empty' <<<"$config")"
cfg_image="$(jq -r .image <<<"$config")"
[ "$cfg_image" = "$IMAGE" ] || { echo "build-image: image ${cfg_image} differs from the tag job's ${IMAGE}" >&2; exit 1; }

ctx="${RUNNER_TEMP:-/tmp}/context"
rm -rf "$ctx"
"$s/build-context.sh" caller "$COMMIT" "$ctx"
"$s/dockerfile-syntax.sh" "$ctx/$dockerfile" checks/.github/frontends.txt

args=()
while IFS= read -r kv; do
  [ -n "$kv" ] || continue
  key="${kv%%=*}"
  case "$key" in
    BUILDKIT_*) echo "build-image: build arg ${key} would configure BuildKit itself; not allowed" >&2; exit 1 ;;
  esac
  args+=(--build-arg "$kv")
done < <("$s/content-tag.sh" --build-args caller "$COMMIT")
args+=(--build-arg "CONTENT_TAG=${TAG}")
[ -z "$target" ] || args+=(--target "$target")

printf '%s' "$TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin >/dev/null
# A builder of our own, BuildKit pinned by digest; no insecure entitlements.
docker buildx create --name release-checks --driver docker-container \
  --driver-opt "image=${BUILDKIT_IMAGE}" --use --bootstrap >/dev/null
summary "- ${ARCH}: $(docker --version); $(docker buildx version); BuildKit ${BUILDKIT_IMAGE}"

cache="${IMAGE}:buildcache-${ARCH}"
common=(--platform "linux/${ARCH}" --provenance=false --sbom=false
  -f "$ctx/$dockerfile" "${args[@]}" --cache-from "type=registry,ref=${cache}")

if [ "$mode" = push ]; then
  meta="${RUNNER_TEMP:-/tmp}/metadata.json"
  docker buildx build "${common[@]}" \
    --output "type=image,name=${IMAGE},push-by-digest=true,name-canonical=true,push=true,rewrite-timestamp=true" \
    --metadata-file "$meta" "$ctx"
  digest="$(jq -r '."containerimage.digest" // empty' "$meta")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "build-image: no digest from the build: $(cat "$meta")" >&2; exit 1; }
  echo "${ARCH}: ${IMAGE}@${digest}"
  summary "- ${ARCH}: ${IMAGE}@${digest}"
  echo "digest=${digest}" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  docker buildx build "${common[@]}" --output type=cacheonly \
    --cache-to "type=registry,ref=${cache},mode=max,image-manifest=true,oci-mediatypes=true" "$ctx"
  echo "${ARCH}: wrote ${cache}"
  summary "- ${ARCH}: wrote ${cache}"
fi
