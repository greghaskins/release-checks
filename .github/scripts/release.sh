#!/usr/bin/env bash
# The release job's rules (release.yml): a reviewed `v*` tag publishes the
# GitHub Release, once, checked from the API and the tag commit's own files.
#
#   release.sh commit     prints the tag's commit (annotated tags peeled)
#   release.sh r0 <sha>   the latest release-review from the reviewer's
#                         account is a success whose first word is the tag
#   release.sh r1 <sha>   the tag is vMAJOR.MINOR.PATCH; prints the
#                         predecessor (the highest lower v* tag with a
#                         Release by github-actions[bot]), or nothing; the
#                         commit descends from it
#   release.sh r2 <sha>   the commit is on main
#   release.sh r3 <sha>   the pin file (from .github/image.json at <sha>)
#                         names an r- tag whose index digest the registry
#                         still returns; prints "<image> <tag> <digest>"
#   release.sh existing <sha> <digest>
#                         prints "skip" when github-actions[bot] already made
#                         this Release for this commit and digest, "create"
#                         when there is none; fails on any other Release
#   release.sh publish <sha> <pred> <image> <tag> <digest>
#                         creates the Release once, with generated notes
#
# Environment: REPO (owner/name), TAG (the pushed tag), APP (a git repo that
# holds <sha>, fetched by the workflow; no work tree is read), CHECKS (this
# repository's .github/scripts), REVIEWER_ID (repository variable
# RELEASE_REVIEWER_ID), GH_TOKEN for gh. Each failure prints "R<n>: <why>",
# appends it to $GITHUB_STEP_SUMMARY, and exits 1. Usage errors exit 2.
set -euo pipefail
export LC_ALL=C

RELEASER_ID=41898282 # github-actions[bot], which creates every Release
semver='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
sha_re='^[0-9a-f]{40}$'

die() { # rule, message
  local line="${1:+$1: }$2"
  echo "$line" >&2
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- release ${TAG:-?}: ${line}" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}
need() { for v in "$@"; do [ -n "${!v:-}" ] || { echo "release.sh: ${v} is not set" >&2; exit 2; }; done; }
need REPO TAG
err="$(mktemp)"; trap 'rm -f "$err"' EXIT

cmd="${1:-}"; shift || true
case "$cmd" in
  commit)
    [[ "$TAG" =~ $semver ]] || die R1 "${TAG} is not vMAJOR.MINOR.PATCH"
    obj="$(gh api "repos/${REPO}/git/ref/tags/${TAG}" --jq '.object.type + " " + .object.sha' 2>"$err")" \
      || die "" "cannot read tag ${TAG}: $(cat "$err")"
    while [ "${obj%% *}" = tag ]; do
      obj="$(gh api "repos/${REPO}/git/tags/${obj#* }" --jq '.object.type + " " + .object.sha' 2>"$err")" \
        || die "" "cannot peel tag ${TAG}: $(cat "$err")"
    done
    if [ "${obj%% *}" != commit ] || ! [[ "${obj#* }" =~ $sha_re ]]; then die "" "tag ${TAG} does not point at a commit"; fi
    echo "${obj#* }"
    ;;

  r0)
    sha="${1:?}"
    [[ "${REVIEWER_ID:-}" =~ ^[0-9]+$ ]] || die R0 "repository variable RELEASE_REVIEWER_ID is not set: the reviewer's bot account id, under Settings > Secrets and variables > Actions > Variables"
    # Statuses come newest first; only the reviewer's account counts (any
    # other account's release-review is ignored, spec 4).
    s="$(gh api --paginate "repos/${REPO}/commits/${sha}/statuses" \
          --jq '.[] | select(.context == "release-review" and (.creator.id|tostring) == env.REVIEWER_ID) | [.state, .creator.login, .creator.type, (.description // "")] | @tsv' 2>"$err")" \
      || die R0 "cannot read the statuses of ${sha}: $(cat "$err")"
    s="${s%%$'\n'*}"
    [ -n "$s" ] || die R0 "no release-review from the reviewer (account ${REVIEWER_ID}) on ${sha}"
    IFS=$'\t' read -r state login type desc <<<"$s"
    [ "$type" = Bot ] || die R0 "account ${REVIEWER_ID} (${login}) is a ${type}, not a Bot"
    [ "$state" = success ] || die R0 "the latest release-review from ${login} on ${sha} is ${state}"
    first="${desc%% *}"
    [ "$first" = "$TAG" ] || die R0 "release-review names '${first}', not ${TAG}"
    echo "R0 ok: ${TAG} reviewed by ${login}" >&2
    ;;

  r1)
    sha="${1:?}"
    [[ "$TAG" =~ $semver ]] || die R1 "${TAG} is not vMAJOR.MINOR.PATCH"
    tags="$(gh api --paginate "repos/${REPO}/git/matching-refs/tags/v" --jq '.[].ref | ltrimstr("refs/tags/")' 2>"$err")" \
      || die R1 "cannot list tags: $(cat "$err")"
    pred=""
    # Lower SemVer tags, highest first. Only a 404 means "no Release"; any
    # other error stops, so an unreadable Release never skips to an older one.
    while read -r t; do
      [ -n "$t" ] || continue
      if author="$(gh api "repos/${REPO}/releases/tags/${t}" --jq '(.author.id|tostring) + " " + (.draft|tostring)' 2>"$err")"; then
        if [ "$author" = "${RELEASER_ID} false" ]; then pred="$t"; break; fi
      elif ! grep -q 'HTTP 404' "$err"; then
        die R1 "cannot read the Release for ${t}: $(cat "$err")"
      fi
    done < <(grep -E "$semver" <<<"$tags" | { cat; echo "$TAG"; } | sort -uV | sed "/^${TAG//./\\.}\$/,\$d" | tac)
    if [ -n "$pred" ]; then
      status="$(gh api "repos/${REPO}/compare/${pred}...${sha}" --jq .status 2>"$err")" \
        || die R1 "cannot compare ${pred} with ${sha}: $(cat "$err")"
      [ "$status" = ahead ] || die R1 "${sha} does not descend from ${pred} (compare: ${status})"
      echo "R1 ok: predecessor ${pred}" >&2
    else
      echo "R1 ok: ${TAG} is the first release" >&2
    fi
    echo "$pred"
    ;;

  r2)
    sha="${1:?}"
    status="$(gh api "repos/${REPO}/compare/${sha}...main" --jq .status 2>"$err")" \
      || die R2 "cannot compare ${sha} with main: $(cat "$err")"
    [ "$status" = ahead ] || [ "$status" = identical ] || die R2 "${sha} is not on main (compare: ${status})"
    echo "R2 ok: ${sha} is on main" >&2
    ;;

  r3)
    sha="${1:?}"; need APP CHECKS
    config="$("$CHECKS/content-tag.sh" --config "$APP" "$sha" 2>"$err")" \
      || die R3 "cannot read .github/image.json at ${sha}: $(cat "$err")"
    image="$(jq -r .image <<<"$config")"; pin_file="$(jq -r .pin_file <<<"$config")"
    pin="$(git -C "$APP" show "${sha}:${pin_file}" 2>"$err")" \
      || die R3 "cannot read ${pin_file} at ${sha}: $(cat "$err")"
    entry="$(IMG="$image" yq -o=json '[.images[] | select(.name == strenv(IMG))]' <<<"$pin" 2>"$err")" \
      || die R3 "${pin_file} at ${sha} does not parse: $(cat "$err")"
    [ "$(jq length <<<"$entry")" = 1 ] || die R3 "${pin_file} at ${sha} has no single images entry for ${image}"
    tag="$(jq -r '.[0].newTag // ""' <<<"$entry")"; digest="$(jq -r '.[0].digest // ""' <<<"$entry")"
    [[ "$tag" =~ ^r-[0-9a-f]{64}$ ]] || die R3 "${pin_file} at ${sha} pins tag '${tag}', not r-<64 hex>"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die R3 "${pin_file} at ${sha} pins digest '${digest}'"
    state="$("$CHECKS/registry-state.sh" "${image}:${tag}" 2>"$err")" \
      || die R3 "registry error for ${image}:${tag}: $(cat "$err")"
    [ "$state" != missing ] || die R3 "the registry has no ${image}:${tag}"
    [ "${state#found }" = "$digest" ] || die R3 "${image}:${tag} is ${state#found }, but the pin names ${digest}"
    echo "R3 ok: ${image}:${tag}@${digest}" >&2
    echo "${image} ${tag} ${digest}"
    ;;

  existing)
    sha="${1:?}" digest="${2:?}"
    if ! rel="$(gh api "repos/${REPO}/releases/tags/${TAG}" 2>"$err")"; then
      grep -q 'HTTP 404' "$err" || die "" "cannot read the Release for ${TAG}: $(cat "$err")"
      echo create
      exit 0
    fi
    author="$(jq -r '.author.id|tostring' <<<"$rel")"; body="$(jq -r '.body // ""' <<<"$rel")"
    if [ "$author" = "$RELEASER_ID" ] && grep -qF "$sha" <<<"$body" && grep -qF "$digest" <<<"$body"; then
      echo "Release ${TAG} already exists for ${sha} and ${digest}; nothing to do" >&2
      echo skip
      exit 0
    fi
    die "" "a different Release ${TAG} already exists (author id ${author}); it is never edited"
    ;;

  publish)
    sha="${1:?}" pred="${2-}" image="${3:?}" ctag="${4:?}" digest="${5:?}"
    notes="$(mktemp)"
    args=(-f "tag_name=${TAG}" -f "target_commitish=${sha}")
    [ -z "$pred" ] || args+=(-f "previous_tag_name=${pred}")
    # The notes `--generate-notes --notes-start-tag` would write, made first so
    # the Release is created once and never edited.
    gh api "repos/${REPO}/releases/generate-notes" "${args[@]}" --jq .body > "$notes" 2>"$err" \
      || die "" "cannot generate the notes: $(cat "$err")"
    {
      echo
      echo "### Image"
      echo
      echo "- content tag: \`${ctag}\`"
      echo "- digest: \`${digest}\`"
      echo "- reference: \`${image}:${ctag}@${digest}\`"
      echo "- tag commit: \`${sha}\`"
      # The build args file, when the image has one.
      # Read from the raw image.json at the tag, for this link only.
      if [ -n "${APP:-}" ]; then
        f="$(git -C "$APP" show "${sha}:.github/image.json" 2>/dev/null | jq -r '.build_args_file // empty' 2>/dev/null || true)"
        [ -z "$f" ] || echo "- build args: https://github.com/${REPO}/blob/${TAG}/${f}"
      fi
    } >> "$notes"
    gh release create "$TAG" -R "$REPO" --verify-tag --title "$TAG" --notes-file "$notes" 2>"$err" \
      || die "" "cannot create the Release: $(cat "$err")"
    echo "Released ${TAG} at ${sha} (${image}@${digest})" >&2
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- released ${TAG} at ${sha} (${image}@${digest})" >> "$GITHUB_STEP_SUMMARY"
    ;;

  *)
    echo "usage: release.sh commit | r0|r1|r2|r3 <sha> | existing <sha> <digest> | publish <sha> <pred> <image> <tag> <digest>" >&2
    exit 2
    ;;
esac
