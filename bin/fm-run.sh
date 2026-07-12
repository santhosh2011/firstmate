#!/usr/bin/env bash
# fm-run.sh - bring an SDev task's stack up and surface its live URL.
#
# This is firstmate's run layer for SDev tasks (phase 2): the captain gets a
# run/test step before review. It reads the task meta (sdev_home, slug, project)
# that fm-spawn's SDev provider wrote and drives the sdev CLI in that home. A
# task with no slug= is a treehouse task, not an SDev task, and is rejected so
# fm-run never guesses.
#
# Usage:
#   fm-run.sh <id> up     bring the task's stack up (sdev up)
#   fm-run.sh <id> url    print the task's live URL (from sdev ls --json), or
#                         exit non-zero when there is none yet
#   fm-run.sh <id> open   open the task's live URL in a browser (sdev open)
#
# The URL/liveness read is deliberately distinct from the pane-endpoint liveness
# check the watcher uses: it reports whether the stack serves a URL, not whether
# the crewmate pane is alive.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: fm-run.sh <id> <up|url|open>" >&2
  exit 2
}

ID=${1:-}
ACTION=${2:-}
[ -n "$ID" ] && [ -n "$ACTION" ] || usage
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

meta_field() { grep "^$1=" "$META" | head -1 | cut -d= -f2-; }

SLUG=$(meta_field slug)
PROJECT=$(meta_field project)
[ -n "$SLUG" ] || { echo "error: task $ID is not an SDev task (no slug= in meta)" >&2; exit 1; }
PROJ=$(basename "$PROJECT")
export SDEV_HOME
SDEV_HOME=$(meta_field sdev_home)

task_url() {
  sdev ls --json 2>/dev/null | jq -r --arg t "$PROJ/$SLUG" '.alive[]? | select(.task==$t) | .url' | head -1
}

case "$ACTION" in
  up) sdev -p "$PROJ" up "$SLUG" ;;
  open) sdev -p "$PROJ" open "$SLUG" ;;
  url)
    url=$(task_url)
    [ -n "$url" ] || { echo "warning: no live URL for $PROJ/$SLUG (stack not up?)" >&2; exit 1; }
    printf '%s\n' "$url"
    ;;
  *) usage ;;
esac
