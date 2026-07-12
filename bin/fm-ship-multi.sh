#!/usr/bin/env bash
# fm-ship-multi.sh - all-or-nothing multi-repo SDev ship.
#
# A multi-repo SDev feature lands as one atomic unit. This coordinator takes the
# CHANGED repos in a task's workspace (each repo whose task/<slug> branch differs
# from its own base), resolves each repo's landing mode from the landing overlay
# (bin/fm-landing-policy.sh), and requires EVERY changed repo to be a ready
# landing candidate before ANY repo lands:
#   - a remote repo (no-mistakes / direct-PR) needs a recorded pr_<key>=<url>
#     whose PR is OPEN, APPROVED, and green;
#   - a local-only repo needs its task/<slug> branch to fast-forward onto its
#     local base.
# Partial-failure policy: NEVER partial-merge. If any changed repo is not ready,
# nothing lands, the blocking repo is reported, and the batch is left for
# firstmate to escalate. Ready repos land together in dependency order - the
# overlay's `order` array for the project, or common-first-then-registry-order
# when unset. A remote repo lands by squash-merging its PR (gh-axi); a local-only
# repo lands by a local fast-forward merge into its base branch. A per-repo
# landed_<key>= marker is recorded in meta for teardown (phase 5).
#
# Driving each repo to a candidate (running its pipeline, opening its PR) happens
# through the existing per-repo tooling before ship; this coordinator gates and
# lands. Single-repo ship (fm-pr-check.sh / fm-pr-merge.sh for a treehouse task)
# is untouched.
#
# Usage:
#   fm-ship-multi.sh <task-id>            report the ship plan and readiness; exit
#                                         non-zero if any changed repo is blocked
#   fm-ship-multi.sh <task-id> --merge    land every changed repo atomically, or
#                                         refuse and land nothing if any is blocked
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() { echo "usage: fm-ship-multi.sh <task-id> [--merge]" >&2; exit 2; }

ID=${1:-}
[ -n "$ID" ] || usage
MERGE=false
case "${2:-}" in '') ;; --merge) MERGE=true ;; *) usage ;; esac
[ $# -le 2 ] || usage

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
meta_field() { grep "^$1=" "$META" | tail -1 | cut -d= -f2-; }
SLUG=$(meta_field slug)
[ -n "$SLUG" ] || { echo "error: task $ID is not an SDev task (no slug= in meta)" >&2; exit 1; }
WS=$(meta_field worktree)
PROJ=$(basename "$(meta_field project)")
export SDEV_HOME
SDEV_HOME=$(meta_field sdev_home)
BRANCH="task/$SLUG"

repo_base() {  # <repo-wt> <default_base> -> base ref (origin/<b> when remote-backed)
  local wt=$1 default_base=$2
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch origin "+refs/heads/$default_base:refs/remotes/origin/$default_base" --quiet 2>/dev/null || true
    printf 'origin/%s' "$default_base"
  else
    printf '%s' "$default_base"
  fi
}

repo_changed() {  # <repo-wt> <base-ref>: 0 iff task/<slug> differs from base
  local wt=$1 base=$2
  git -C "$wt" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1 || return 1
  git -C "$wt" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 || return 1
  ! git -C "$wt" diff --quiet "$base...$BRANCH" --
}

pr_ready() {  # <url>: 0 iff PR is OPEN, APPROVED, and green
  local url=$1 st rd
  st=$(gh-axi pr view "$url" --json state -q .state 2>/dev/null) || return 1
  [ "$st" = OPEN ] || return 1
  rd=$(gh-axi pr view "$url" --json reviewDecision -q .reviewDecision 2>/dev/null) || return 1
  [ "$rd" = APPROVED ] || return 1
  gh-axi pr checks "$url" >/dev/null 2>&1
}

repo_ready() {  # <key> <mode> <pr_url> <wt> <base-ref>: echo reason iff NOT ready
  local key=$1 mode=$2 pr_url=$3 wt=$4 base=$5
  if [ "$mode" = local-only ]; then
    git -C "$wt" merge-base --is-ancestor "$base" "$BRANCH" 2>/dev/null && return 0
    echo "$key: local-only branch does not fast-forward onto $base"; return 1
  fi
  [ -n "$pr_url" ] || { echo "$key: no PR recorded (pr_$key= missing in meta)"; return 1; }
  pr_ready "$pr_url" && return 0
  echo "$key: PR not OPEN+APPROVED+green ($pr_url)"
  return 1
}

# Build the ship PLAN: one TAB line per CHANGED repo: key path base_ref mode pr_url.
build_plan() {
  local key path base wt base_ref mode pr_url
  while IFS=$'\t' read -r key path base _; do
    [ -n "$path" ] || continue
    wt="$WS/$path"
    base_ref=$(repo_base "$wt" "$base")
    repo_changed "$wt" "$base_ref" || continue
    mode=$("$SCRIPT_DIR/fm-landing-policy.sh" "$PROJ" "$key" | cut -d' ' -f1)
    pr_url=$(meta_field "pr_$key")
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$path" "$base_ref" "$mode" "$pr_url"
  done <<EOF
$1
EOF
}

landing_order_priority() {  # explicit overlay order, else common-first default
  local explicit
  explicit=$("$SCRIPT_DIR/fm-landing-policy.sh" order "$PROJ" | tr '\n' ' ')
  [ -n "$explicit" ] && printf '%s' "$explicit" || printf 'common'
}

landing_order() {  # <changed-keys-space-list>: priority keys first, then the rest
  local changed=$1 k emitted=" "
  for k in $(landing_order_priority) $changed; do
    case " $changed " in *" $k "*) : ;; *) continue ;; esac
    case "$emitted" in *" $k "*) continue ;; esac
    emitted="$emitted$k "
    printf '%s\n' "$k"
  done
}

record_landed() { grep -qxF "landed_$1=$2" "$META" || echo "landed_$1=$2" >> "$META"; }

land_remote() {  # <key> <pr_url>
  local n owner repo
  [[ "$2" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$ ]] \
    || { echo "error: bad PR URL for $1: $2" >&2; return 1; }
  owner=${BASH_REMATCH[1]}; repo=${BASH_REMATCH[2]}; n=${BASH_REMATCH[3]}
  gh-axi pr merge "$n" --repo "$owner/$repo" --squash
  record_landed "$1" "$2"
}

land_local() {  # <key> <workspace-wt> <base-branch>
  # The base branch is checked out in the repo's source (main) worktree, not the
  # task worktree, so fast-forward it there; a branch cannot be checked out twice.
  local main_wt cur
  main_wt=$(cd "$2" && cd "$(git rev-parse --git-common-dir)/.." && pwd -P)
  cur=$(git -C "$main_wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$cur" = "$3" ] || { echo "error: local-only $1 base '$3' not checked out at $main_wt (on '${cur:-detached}')" >&2; return 1; }
  git -C "$main_wt" merge --ff-only --quiet "$BRANCH"
  record_landed "$1" local
}

plan_line() { printf '%s\n' "$PLAN" | awk -F'\t' -v k="$1" '$1==k {print; exit}'; }

land_key() {  # <key>
  local line path base mode pr_url
  line=$(plan_line "$1")
  IFS=$'\t' read -r _ path base mode pr_url <<EOF
$line
EOF
  if [ "$mode" = local-only ]; then land_local "$1" "$WS/$path" "$base"; else land_remote "$1" "$pr_url"; fi
  echo "landed: $1"
}

REPOS_TSV=$("$SCRIPT_DIR/fm-sdev-registry.sh" repos "$PROJ") \
  || { echo "error: cannot resolve SDev repos for $PROJ under $SDEV_HOME" >&2; exit 1; }
PLAN=$(build_plan "$REPOS_TSV")
[ -n "$PLAN" ] || { echo "no changed repos to ship for $PROJ (slug $SLUG)"; exit 0; }

echo "ship plan for $PROJ (slug $SLUG):"
BLOCKERS=""
CHANGED_KEYS=""
while IFS=$'\t' read -r key path base mode pr_url; do
  [ -n "$key" ] || continue
  CHANGED_KEYS="$CHANGED_KEYS$key "
  if reason=$(repo_ready "$key" "$mode" "$pr_url" "$WS/$path" "$base"); then
    echo "  $key mode=$mode ready"
  else
    echo "  $key mode=$mode BLOCKED"
    BLOCKERS="$BLOCKERS$reason"$'\n'
  fi
done <<EOF
$PLAN
EOF

if [ -n "$BLOCKERS" ]; then
  echo "ship blocked - nothing landed:" >&2
  printf '%s' "$BLOCKERS" >&2
  exit 1
fi

if ! $MERGE; then
  echo "ready to land (all changed repos ready): ${CHANGED_KEYS}- re-run with --merge"
  exit 0
fi

for key in $(landing_order "$CHANGED_KEYS"); do
  land_key "$key"
done
echo "all $(printf '%s' "$CHANGED_KEYS" | wc -w | tr -d ' ') repos landed atomically for $PROJ (slug $SLUG)"
