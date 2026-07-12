#!/usr/bin/env bash
# fm-landing-policy.sh - resolve (project, repo) to "<mode> <yolo>" from a
# firstmate-side landing overlay, for SDev-backed multi-repo projects.
#
# Landing policy (delivery mode + yolo) has no slot in SDev's registry YAML and
# must not pollute it, so it lives in a firstmate-private overlay at
# config/landing-policy.json (local, gitignored, the same pattern as
# config/crew-dispatch.json). See docs/examples/landing-policy.json.
#
# Overlay shape:
#   { "projects": {
#       "<project>": {
#         "default": { "mode": "<mode>", "yolo": <bool> },
#         "repos":   { "<repo>": { "mode": "<mode>", "yolo": <bool> } } } } }
#
# Resolution: a per-repo override merges over the project default, and mode and
# yolo each fall back independently. When the overlay is absent, the project or
# repo is unknown, or the file is unreadable, this resolves to "no-mistakes off"
# - the exact fail-safe bin/fm-project-mode.sh uses, so an unknown or broken
# overlay never silently drops the gate.
#
# This is a NEW standalone resolver for the multi-repo path; it does not replace
# bin/fm-project-mode.sh, which stays the single-repo/treehouse resolver.
#
# Output: two words to stdout, "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# Exit codes: 0 ok; 2 usage error; 127 jq missing while an overlay exists.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
POLICY="$CONFIG/landing-policy.json"

usage() {
  echo "usage: fm-landing-policy.sh <project> <repo>" >&2
  exit 2
}

# Print the gate-preserving default and exit; the fail-safe for every absent,
# unknown, or unreadable case.
fallback() {
  echo "no-mistakes off"
  exit 0
}

# jq resolves the per-repo override merged over the project default, each axis
# falling back independently to the built-in "no-mistakes"/false. It selects on
# has() rather than `//` so an explicitly set `false` (e.g. a per-repo yolo:false
# over a default yolo:true) overrides instead of being treated as absent, which
# would fail open on the approval axis. type=="object" guards a null project,
# default block, or repo entry from erroring under has().
resolve() {
  jq -r --arg p "$1" --arg r "$2" '
    .projects[$p] as $proj
    | $proj.repos[$r] as $ro
    | $proj.default as $pd
    | (if ($ro|type=="object") and ($ro|has("mode")) then $ro.mode
       elif ($pd|type=="object") and ($pd|has("mode")) then $pd.mode
       else "no-mistakes" end) as $mode
    | (if ($ro|type=="object") and ($ro|has("yolo")) then $ro.yolo
       elif ($pd|type=="object") and ($pd|has("yolo")) then $pd.yolo
       else false end) as $yolo
    | "\($mode) \(if $yolo then "on" else "off" end)"' "$POLICY"
}

project=${1:-}
repo=${2:-}
[ -n "$project" ] && [ -n "$repo" ] || usage
[ -f "$POLICY" ] || fallback
command -v jq >/dev/null 2>&1 || { echo "fm-landing-policy.sh: jq required to read $POLICY" >&2; exit 127; }

if ! raw=$(resolve "$project" "$repo" 2>/dev/null); then
  echo "warn: unreadable landing overlay $POLICY; defaulting $project/$repo to no-mistakes off" >&2
  fallback
fi

mode=${raw%% *}
yolo=${raw##* }
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *)
    echo "warn: unknown mode \"$mode\" for $project/$repo; defaulting to no-mistakes off" >&2
    mode=no-mistakes
    yolo=off
    ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
echo "$mode $yolo"
