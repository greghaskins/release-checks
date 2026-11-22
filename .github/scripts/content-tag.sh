#!/usr/bin/env bash
# The content tag of an app's image, and the input set it is computed from.
#
#   content-tag.sh [--list | --build-args | --config] <repo> <commit>
#
# Everything comes from <commit>, never the work tree: the image config
# .github/image.json, the input set and the build args file.
#
#   (no mode)     prints r-<64 hex>: SHA-256 over the scheme line
#                 "release-checks content tag 1" and one line per file of
#                 the input set, "<mode> <object id><TAB><path>", sorted
#                 bytewise by path, each ending in a newline.
#   --list        the hashed files, NUL-terminated records
#                 "<mode> <object id><TAB><path>", in the same order. The
#                 build context is exactly this list.
#   --build-args  the build args, sorted "KEY=value" lines.
#   --config      the validated config as one JSON object: image,
#                 dockerfile, target (or null), pin_file, paths, and
#                 build_args merged from build_args and build_args_file.
#
# .github/image.json:
#   image            image name, e.g. ghcr.io/owner/app (required)
#   dockerfile       the Dockerfile's path from the repo root (required)
#   paths            git pathspecs selecting the input set; only the glob and
#                    exclude magic (required, at least one)
#   pin_file         the kustomization that pins the image (required)
#   target           a Dockerfile stage (optional)
#   build_args       an object of literal strings (optional)
#   build_args_file  a file in the input set, one KEY=value per line; blank
#                    lines and # lines skipped; read as data (optional)
# The input set is what paths matches, plus .github/image.json itself.
#
# Exit 1 on a rule, with "content-tag: <rule>: <detail>" on stderr. Rules:
#   config, pathspec-magic, no-match, no-dockerfile, no-build-args-file,
#   pin-file-in-set, submodule, control-byte, symlink-escape, build-arg-key,
#   build-arg-duplicate, build-arg-value.
# Exit 2 on a usage error. Needs git, jq and sha256sum.
set -euo pipefail
export LC_ALL=C

scheme="release-checks content tag 1"
config_path=".github/image.json"
tab=$'\t'

usage() { echo "content-tag: usage: ${1}; usage: content-tag.sh [--list | --build-args | --config] <repo> <commit>" >&2; exit 2; }
rule() { echo "content-tag: $1: $2" >&2; exit 1; }

mode=tag
case "${1:-}" in
  --list | --build-args | --config) mode="${1#--}"; shift ;;
  -*) usage "unknown option ${1}" ;;
esac
[ "$#" -eq 2 ] || usage "want <repo> <commit>"
repo="$1"
commit="$2"
g() { git -C "$repo" -c core.ignorecase=false -c core.quotepath=false "$@"; }
sha="$(g rev-parse --verify --quiet "${commit}^{commit}")" || usage "${commit} is not a commit in ${repo}"

# --- the config ------------------------------------------------------------
raw="$(g show "${sha}:${config_path}" 2>/dev/null)" || rule config "${config_path} is missing at ${sha}"
problem="$(jq -r '
  if type != "object" then "not a JSON object"
  else
    ([keys[] | select(IN("image","dockerfile","paths","pin_file","target","build_args","build_args_file") | not)]) as $unknown
    | if ($unknown | length) > 0 then "unknown key \($unknown[0])"
      elif (.image | type) != "string" or .image == "" then "image must be a non-empty string"
      elif (.dockerfile | type) != "string" or .dockerfile == "" then "dockerfile must be a non-empty string"
      elif (.pin_file | type) != "string" or .pin_file == "" then "pin_file must be a non-empty string"
      elif (.paths | type) != "array" or (.paths | length) == 0 then "paths must be a non-empty array"
      elif any(.paths[]; type != "string" or . == "") then "every path must be a non-empty string"
      elif has("target") and ((.target | type) != "string" or .target == "") then "target must be a non-empty string"
      elif has("build_args") and (.build_args | type) != "object" then "build_args must be an object"
      elif has("build_args") and any(.build_args[]; type != "string") then "every build_args value must be a string"
      elif has("build_args_file") and ((.build_args_file | type) != "string" or .build_args_file == "") then "build_args_file must be a non-empty string"
      else empty end
  end' <<<"$raw" 2>&1)" || rule config "${config_path} is not valid JSON: ${problem}"
[ -z "$problem" ] || rule config "${config_path}: ${problem}"

dockerfile="$(jq -r .dockerfile <<<"$raw")"
pin_file="$(jq -r .pin_file <<<"$raw")"
args_file="$(jq -r '.build_args_file // ""' <<<"$raw")"
mapfile -t paths < <(jq -r '.paths[]' <<<"$raw")

# --- pathspecs: only glob and exclude magic ---------------------------------
positives=()
for p in "${paths[@]}"; do
  case "$p" in
    ":("*")"*)
      magic="${p#:(}"; magic="${magic%%)*}"; rest="${p#*)}"
      keep=""
      IFS=, read -r -a words <<<"$magic"
      for w in "${words[@]}"; do
        case "$w" in
          glob) keep="glob" ;;
          exclude) ;;
          *) rule pathspec-magic "${p}: only glob and exclude are allowed, not '${w}'" ;;
        esac
      done
      positives+=("${keep:+:(${keep})}${rest}") ;;
    ":!"* | ":^"*) positives+=("${p:2}") ;;
    ":"*) rule pathspec-magic "${p}: only :(glob), :(exclude), :! and :^ are allowed" ;;
    *) positives+=("$p") ;;
  esac
done

# --- the input set, from the commit's tree in a private index ---------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_INDEX_FILE="$tmp/index"
g read-tree "$sha"

for i in "${!paths[@]}"; do
  if [ -z "$(g ls-files -z -- "${positives[$i]}" | head -c1)" ]; then
    rule no-match "pathspec '${paths[$i]}' matches nothing at ${sha}"
  fi
done

# ls-files -s -z: "<mode> <oid> <stage><TAB><path>\0". The set is the
# pathspecs' match plus the config file, each path once.
declare -A seen=()
records=()
add() { # one ls-files record
  local rec="$1" meta path
  meta="${rec%%"$tab"*}"
  path="${rec#*"$tab"}"
  [ -n "${seen[$path]+x}" ] && return 0
  seen[$path]=1
  records+=("${meta% *}${tab}${path}")
}
while IFS= read -r -d '' rec; do add "$rec"; done < <(g ls-files -s -z -- "${paths[@]}")
while IFS= read -r -d '' rec; do add "$rec"; done < <(g ls-files -s -z -- ":(literal)${config_path}")

ctl=$'[\001-\037]'
for rec in "${records[@]}"; do
  path="${rec#*"$tab"}"
  [[ "$path" =~ $ctl ]] && rule control-byte "a path holds a byte below 0x20: $(printf '%q' "$path")"
  case "${rec%% *}" in
    160000) rule submodule "${path} is a submodule; its files are not in the tree" ;;
  esac
done
[ -n "${seen[$dockerfile]+x}" ] || rule no-dockerfile "the input set lacks the dockerfile ${dockerfile}"
[ -z "$args_file" ] || [ -n "${seen[$args_file]+x}" ] || rule no-build-args-file "the input set lacks build_args_file ${args_file}"
[ -z "${seen[$pin_file]+x}" ] || rule pin-file-in-set "the input set holds the pin file ${pin_file}; pinning would change the tag it pins"

# Symlinks: the target must be relative and resolve inside the set (a file
# of the set, or a directory holding one).
in_set_or_dir() {
  local t="$1" p
  [ -n "${seen[$t]+x}" ] && return 0
  for p in "${!seen[@]}"; do [[ "$p" == "$t/"* ]] && return 0; done
  return 1
}
for rec in "${records[@]}"; do
  [ "${rec%% *}" = 120000 ] || continue
  path="${rec#*"$tab"}"
  oid="${rec%%"$tab"*}"; oid="${oid#* }"
  target="$(g cat-file blob "$oid")"
  [[ "$target" == /* ]] && rule symlink-escape "${path} -> ${target} is absolute"
  base="$(dirname "$path")"; [ "$base" = . ] && base=""
  IFS=/ read -r -a parts <<<"${base:+$base/}${target}"
  out=()
  for part in "${parts[@]}"; do
    case "$part" in
      "" | .) ;;
      ..) [ "${#out[@]}" -gt 0 ] || rule symlink-escape "${path} -> ${target} leaves the repo"
          unset 'out[${#out[@]}-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  resolved="$(IFS=/; echo "${out[*]}")"
  in_set_or_dir "$resolved" || rule symlink-escape "${path} -> ${target} resolves to ${resolved:-the repo root}, outside the input set"
done

# --- build args --------------------------------------------------------------
declare -A args=()
check_arg() { # source key value
  local src="$1" k="$2" v="$3"
  [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || rule build-arg-key "${src}: '${k}' must match ^[A-Z][A-Z0-9_]*\$"
  [[ "$k" == BUILDKIT_* ]] && rule build-arg-key "${src}: ${k} starts with BUILDKIT_"
  case "$k" in
    HTTP_PROXY | HTTPS_PROXY | FTP_PROXY | NO_PROXY | ALL_PROXY)
      rule build-arg-key "${src}: ${k} is a predefined proxy arg, left out of BuildKit's cache key" ;;
  esac
  [ -z "${args[$k]+x}" ] || rule build-arg-duplicate "${src}: ${k} is given twice"
  [[ "$v" =~ $ctl ]] && rule build-arg-value "${src}: ${k}'s value holds a byte below 0x20"
  args[$k]="$v"
}
while IFS= read -r -d '' k && IFS= read -r -d '' v; do
  check_arg "build_args" "$k" "$v"
done < <(jq -j '(.build_args // {}) | to_entries[] | "\(.key)\u0000\(.value)\u0000"' <<<"$raw")
if [ -n "$args_file" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in "" | "#"*) continue ;; esac
    [[ "$line" == *=* ]] || rule build-arg-key "${args_file}:${n}: no '=' in the line"
    check_arg "${args_file}:${n}" "${line%%=*}" "${line#*=}"
  done < <(g cat-file blob "${sha}:${args_file}")
fi

# --- output ------------------------------------------------------------------
sorted() { for rec in "${records[@]}"; do printf '%s\n' "$rec"; done | sort -t "$tab" -k2; }
case "$mode" in
  tag)
    h="$( { printf '%s\n' "$scheme"; sorted; } | sha256sum)"
    printf 'r-%s\n' "${h%% *}" ;;
  list)
    sorted | tr '\n' '\0' ;;
  build-args)
    for k in "${!args[@]}"; do printf '%s=%s\n' "$k" "${args[$k]}"; done | sort ;;
  config)
    for k in "${!args[@]}"; do printf '%s\0%s\0' "$k" "${args[$k]}"; done |
      jq -Rs --argjson c "$raw" '
        (split("\u0000") | .[:-1] | [range(0; length; 2) as $i | {key: .[$i], value: .[$i + 1]}] | from_entries) as $args
        | {image: $c.image, dockerfile: $c.dockerfile, target: ($c.target // null), pin_file: $c.pin_file,
           paths: $c.paths, build_args: ($args | to_entries | sort_by(.key) | from_entries)}' ;;
esac
