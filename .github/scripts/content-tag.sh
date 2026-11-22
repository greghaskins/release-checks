#!/usr/bin/env bash
# Prints the content tag of an image: x- and the first 16 hex digits of a
# SHA-256 over the image's inputs at a revision.
#
#   content-tag.sh <repo root> <inputs file> [rev]
#
# The inputs file lists one path per line, relative to the repo root; blank
# lines and lines starting with # are skipped. A path may be a file or a
# directory: git gives a blob id for a file and a tree id for a directory, so a
# whole directory counts as one input. The hashed text is one line per input,
# `path<TAB>object id`, sorted bytewise, each ending in a newline. Equal inputs
# give an equal tag, on any machine, at any commit.
#
# rev defaults to HEAD. A missing input is an error that names the path, never
# a silent omission. The pin file must not be an input: pinning would then
# change the tag it pins.
set -euo pipefail

usage="usage: content-tag.sh <repo root> <inputs file> [rev]"
root="${1:?$usage}"
inputs="${2:?$usage}"
rev="${3:-HEAD}"

if [ ! -f "$inputs" ]; then
  echo "content-tag: inputs file not found: $inputs" >&2
  exit 1
fi

lines=""
n=0
while IFS= read -r p || [ -n "$p" ]; do
  p="${p%$'\r'}"
  case "$p" in
    "" | "#"*) continue ;;
  esac
  if ! id="$(git -C "$root" rev-parse --verify --quiet "${rev}:${p}")"; then
    echo "content-tag: input path missing at ${rev}: ${p}" >&2
    exit 1
  fi
  lines+="${p}"$'\t'"${id}"$'\n'
  n=$((n + 1))
done < "$inputs"

if [ "$n" -eq 0 ]; then
  echo "content-tag: no input paths in $inputs" >&2
  exit 1
fi

hash="$(printf '%s' "$lines" | LC_ALL=C sort | sha256sum)"
printf 'x-%s\n' "${hash:0:16}"
