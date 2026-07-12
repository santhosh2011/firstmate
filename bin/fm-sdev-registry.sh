#!/usr/bin/env bash
# fm-sdev-registry.sh - read an SDev project's repo composition and answer whether
# a project is SDev-backed, without changing any spawn/ship/teardown behavior.
#
# SDev's own registry at $SDEV_HOME/core/projects.d/<name>.yml already declares
# each project's repos, so firstmate reads it as the source of truth for
# composition instead of duplicating it. This reader is phase 1's data layer: it
# only reports; nothing here mutates a project or the fleet.
#
# SDEV_HOME resolves from the SDEV_HOME env var first, then the first non-empty,
# non-comment line of config/sdev-home (local, gitignored). When neither points
# at an existing directory, or the project has no registry entry there, the
# reader is "not SDev-backed": it exits non-zero and stays silent, so the feature
# is inert for any fleet that has not opted in.
#
# Usage:
#   fm-sdev-registry.sh backed <project>
#     Exit 0 if the project is SDev-backed; exit 3 (silent) if not.
#   fm-sdev-registry.sh repos <project>
#     Print one line per repo, TAB-separated:
#       <key>\t<path>\t<default_base>\t<compose_role>
#     in registry document order. Exit 3 (silent) if not SDev-backed.
#
# Exit codes: 0 ok; 2 usage error; 3 not SDev-backed (inert); 127 yq missing.
# Parsing needs mikefarah yq v4 (already required by SDev).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NOT_BACKED=3

usage() {
  echo "usage: fm-sdev-registry.sh <backed|repos> <project>" >&2
  exit 2
}

# Echo the resolved SDEV_HOME: the env var wins, else the first meaningful line
# of config/sdev-home. Echoes nothing when neither is set.
resolve_sdev_home() {
  if [ -n "${SDEV_HOME:-}" ]; then
    printf '%s\n' "$SDEV_HOME"
    return 0
  fi
  [ -f "$CONFIG/sdev-home" ] || return 0
  awk 'NF && $1 !~ /^#/ { print; exit }' "$CONFIG/sdev-home"
}

# Echo the registry yml for a project, or return 1 when it is not SDev-backed.
registry_file() {
  local home
  home=$(resolve_sdev_home)
  [ -n "$home" ] && [ -d "$home" ] || return 1
  [ -f "$home/core/projects.d/$1.yml" ] || return 1
  printf '%s\n' "$home/core/projects.d/$1.yml"
}

emit_repos() {
  command -v yq >/dev/null 2>&1 || { echo "fm-sdev-registry.sh: mikefarah yq v4 required" >&2; exit 127; }
  yq -r '.repos | to_entries | .[]
    | [.key, (.value.path // ""), (.value.default_base // ""), (.value.compose_role // "")]
    | @tsv' "$1"
}

sub=${1:-}
project=${2:-}
[ -n "$sub" ] && [ -n "$project" ] || usage

case "$sub" in
  backed)
    registry_file "$project" >/dev/null 2>&1 || exit "$NOT_BACKED"
    ;;
  repos)
    file=$(registry_file "$project") || exit "$NOT_BACKED"
    emit_repos "$file"
    ;;
  *)
    usage
    ;;
esac
