#!/usr/bin/env bash
# Fails when a Dockerfile picks its own frontend with a `syntax` parser
# directive, unless the directive names a frontend listed, by digest, in
# <allowlist> (one reference per line). Follows BuildKit's directive rules:
# directives are `# key=value` comment lines at the very top, any case, with
# spaces allowed around the key, `=` and value; an optional UTF-8 BOM first.
# The first line that is not a directive (an instruction, a blank line, or a
# comment that is not `key=value`) ends them. Checks start at the first
# non-whitespace byte (leading blank lines are skipped, as BuildKit does for
# JSON). A file starting with `#!`, `//` or `{` fails: BuildKit can read
# directives in those forms too.
#
#   dockerfile-syntax.sh <dockerfile> <allowlist>
set -euo pipefail
export LC_ALL=C
if [ $# -ne 2 ]; then
  echo "usage: dockerfile-syntax.sh <dockerfile> <allowlist>" >&2
  exit 2
fi
df="$1" allow="$2"
# The whole file, minus a UTF-8 BOM and any leading whitespace (blank lines
# included): BuildKit skips them before a JSON body, so every check starts at
# the first non-whitespace byte.
content="$(cat -- "$df"; printf x)"; content="${content%x}"
content="${content#$'\xef\xbb\xbf'}"
content="${content#"${content%%[![:space:]]*}"}"
# BuildKit also reads a directive after a `#!` line, in `//` comments, and
# from a JSON body. No Dockerfile here needs any of them: refuse all three.
case "$content" in
  '#!'* | '//'* | '{'*)
    echo "dockerfile-syntax: ${df}: starts with '${content:0:2}', a form BuildKit reads directives from; not allowed" >&2
    exit 1 ;;
esac
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ ^#[[:space:]]*([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
    key="${BASH_REMATCH[1],,}" value="${BASH_REMATCH[2]}"
    if [ "$key" = syntax ]; then
      if [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]] && grep -qxF -- "$value" "$allow"; then
        echo "dockerfile-syntax: ${df}: frontend ${value} is allowlisted"
        exit 0
      fi
      echo "dockerfile-syntax: ${df}: a syntax directive (${value}) picks the frontend; only frontends allowlisted by digest may" >&2
      exit 1
    fi
    continue
  fi
  break
done <<<"$content"
echo "dockerfile-syntax: ${df}: no syntax directive"
