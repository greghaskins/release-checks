#!/usr/bin/env bash
# Writes an app's build context: exactly the files content-tag.sh --list
# names at <commit>, each from its git blob, with its mode and an mtime of 0,
# into the empty directory <dest>. Nothing else: no .git, no other file. Not
# `git archive`, which matches pathspecs again and applies .gitattributes.
#
#   build-context.sh <repo> <commit> <dest>
#
# Exit 1 on a content-tag rule (its message passes through) or a write error;
# exit 2 on usage.
set -euo pipefail
export LC_ALL=C
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 3 ]; then
  echo "usage: build-context.sh <repo> <commit> <dest>" >&2
  exit 2
fi
repo="$1" commit="$2" dest="$3"
mkdir -p "$dest"
if [ -n "$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "build-context: ${dest} is not empty" >&2
  exit 1
fi

list="$(mktemp)"; trap 'rm -f "$list"' EXIT
"$here/content-tag.sh" --list "$repo" "$commit" > "$list"

n=0
while IFS= read -r -d '' rec; do
  meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
  mode="${meta%% *}"; oid="${meta#* }"
  out="${dest}/${path}"
  mkdir -p "$(dirname "$out")"
  case "$mode" in
    100644 | 100755)
      git -C "$repo" cat-file blob "$oid" > "$out"
      if [ "$mode" = 100755 ]; then chmod 0755 "$out"; else chmod 0644 "$out"; fi
      ;;
    120000)
      # content-tag.sh rejects control bytes and escapes in targets, so the
      # command substitution loses nothing.
      ln -s "$(git -C "$repo" cat-file blob "$oid")" "$out"
      ;;
    *)
      echo "build-context: ${path}: unexpected mode ${mode}" >&2
      exit 1
      ;;
  esac
  n=$((n + 1))
done < "$list"

# One fixed mtime for every entry, links and directories included, so the
# context does not vary with the checkout time.
find "$dest" -mindepth 1 -exec touch -h -d @0 {} +
echo "build-context: ${n} files"
