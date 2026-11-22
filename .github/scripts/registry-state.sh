#!/usr/bin/env bash
# What the registry holds under <image>:<tag>, for build.yml.
#
#   registry-state.sh <image>:<tag>
#
# Prints `found <index digest>` when it is an index of exactly linux/amd64 and
# linux/arm64, or `missing` when the registry says the tag or repository does
# not exist. Exits 1 on anything else: a registry or network error, an answer
# that is not such an index, or a missing tool. Never reports an error as
# missing, so a flaky registry cannot make build.yml overwrite a tag.
set -euo pipefail
if [ $# -ne 1 ]; then echo "usage: registry-state.sh <image>:<tag>" >&2; exit 2; fi
ref="$1"
command -v docker >/dev/null || { echo "registry-state: docker is not installed" >&2; exit 1; }
err="$(mktemp)"; trap 'rm -f "$err"' EXIT
if out="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>"$err")"; then
  digest="$(jq -r '.digest // empty' <<<"$out")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "registry-state: ${ref}: no digest in the answer: ${out}" >&2; exit 1; }
  plats="$(jq -r '[.manifests[]? | "\(.platform.os)/\(.platform.architecture)\(if .platform.variant then "/" + .platform.variant else "" end)"] | sort | join(" ")' <<<"$out")"
  if [ "$plats" != "linux/amd64 linux/arm64" ]; then
    echo "registry-state: ${ref} is ${digest}, but not an index of exactly linux/amd64 and linux/arm64 (has: ${plats:-none})" >&2
    exit 1
  fi
  echo "found ${digest}"
elif grep -Eq 'MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest unknown|name unknown|: not found$' "$err"; then
  echo missing
else
  echo "registry-state: cannot read ${ref}: $(tr '\n' ' ' < "$err")" >&2
  exit 1
fi
