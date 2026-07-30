#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= (URL or number) for an open PR, the compare
# side is ALWAYS a freshly fetched refs/pull/<n>/head by default so review stays
# current after no-mistakes fix rounds push to the PR. A recorded pr_head= is
# only a fallback when fetch fails (stale recorded SHAs must never win over a
# reachable remote PR head). If neither PR head can be resolved, fall back to
# the local branch with a warning. Without pr=, compare the local branch.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

# --- Combined multi-repo SDev review (phase 3) ------------------------------
# An SDev task (slug= in meta) compares each repo's task/<slug> branch against
# that repo's OWN default_base (from the registry; bases may differ per repo)
# and emits one combined diff labeled per repo, excluding untouched repos. A
# treehouse task (no slug=) falls through to the single-repo path below,
# byte-identical.
sdev_repo_base() {  # <repo-wt> <default_base> -> base ref (origin/<b> when remote-backed)
  local wt=$1 default_base=$2
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch origin "+refs/heads/$default_base:refs/remotes/origin/$default_base" --quiet 2>/dev/null || true
    printf 'origin/%s' "$default_base"
  else
    printf '%s' "$default_base"
  fi
}
review_sdev_one_repo() {  # <repo-wt> <label> <default_base>: emit labeled diff, 0 if changed
  local wt=$1 label=$2 default_base=$3 branch="task/$SLUG" base
  [ -d "$wt" ] || return 1
  git -C "$wt" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 || return 1
  base=$(sdev_repo_base "$wt" "$default_base")
  git -C "$wt" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
    || { echo "warning: repo $label base $base unresolved; skipping" >&2; return 1; }
  if git -C "$wt" diff --quiet "$base...$branch" --; then return 1; fi
  printf '\n===== repo: %s (base %s) =====\n' "$label" "$base"
  git -C "$wt" diff --stat "$base...$branch" --
  "$STAT_ONLY" || { echo; git -C "$wt" diff "$base...$branch" --; }
}
review_sdev_repos() {  # <workspace> <repos-tsv>: iterate, emitting only changed repos
  local ws=$1 repos=$2 emitted=0 key path base
  while IFS=$'\t' read -r key path base _; do
    [ -n "$path" ] || continue
    if review_sdev_one_repo "$ws/$path" "$key" "$base"; then emitted=$((emitted + 1)); fi
  done <<SDEV_REPOS
$repos
SDEV_REPOS
  [ "$emitted" -gt 0 ] || echo "no changes across the $SLUG workspace repos"
}
review_sdev_task() {
  local ws proj_name sdev_home repos
  ws=$(grep '^worktree=' "$META" | cut -d= -f2-)
  proj_name=$(basename "$(grep '^project=' "$META" | cut -d= -f2-)")
  sdev_home=$(grep '^sdev_home=' "$META" | cut -d= -f2-)
  [ -d "$ws" ] || { echo "error: workspace for task $ID is missing: $ws" >&2; return 1; }
  repos=$(SDEV_HOME="$sdev_home" "$SCRIPT_DIR/fm-sdev-registry.sh" repos "$proj_name") \
    || { echo "error: cannot resolve SDev repos for $proj_name under $sdev_home" >&2; return 1; }
  echo "combined review: $proj_name workspace $ws (slug $SLUG)"
  review_sdev_repos "$ws" "$repos"
}
SLUG=$(grep '^slug=' "$META" | cut -d= -f2- || true)
if [ -n "$SLUG" ]; then
  review_sdev_task
  exit $?
fi

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fetch_pull_head() {
  local n=$1 resolved
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  # Fetch into a private ref so a later base-branch fetch cannot clobber the
  # compare tip via FETCH_HEAD, and so we never review a stale local object.
  git -C "$WT" fetch --quiet origin \
    "+refs/pull/$n/head:refs/fm-review/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "refs/fm-review/pull/$n/head^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  n=$(pr_number_from_target "$pr_url") || true
  if [ -n "$n" ]; then
    if resolved=$(fetch_pull_head "$n"); then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  # Offline / unreachable remote: recorded pr_head is better than the local
  # branch, but never preferred over a successful pull-head fetch above.
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
