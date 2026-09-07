#!/usr/bin/env bash
# Shared landed-work safety predicates for teardown and unattended retention.
#
# Callers provide the existing teardown context variables before invoking either
# predicate: SCRIPT_DIR, META, ID, WT, PROJ, KIND, MODE, PR_URL, FORCE, and the
# SDev variables SDEV_HOME_DIR, SDEV_PROJ, SDEV_WS, and SDEV_BRANCH.
#
# validate_worktree_teardown_safety accepts a missing worktree as already gone,
# but refuses dirty, uninspectable, or unlanded work exactly as teardown does.
# validate_sdev_teardown_safety checks every repository resolved by the SDev
# registry and refuses when any repository is dirty or cannot be proven landed.
# FM_LANDED_WORK_NO_FETCH=1 makes remote refresh fail-safe and read-only: current
# remote-tracking refs may prove work landed, while missing or stale proof retains
# the workspace.

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

pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$(cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*) n=${target%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  [ "${FM_LANDED_WORK_NO_FETCH:-0}" != 1 ] || return 1
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in MERGED|merged) ;; *) return 1 ;; esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    if [ "${FM_LANDED_WORK_NO_FETCH:-0}" != 1 ]; then
      git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    fi
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

sdev_repo_base() {
  local wt=$1 default_base=$2
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    if [ "${FM_LANDED_WORK_NO_FETCH:-0}" != 1 ]; then
      git -C "$wt" fetch origin "+refs/heads/$default_base:refs/remotes/origin/$default_base" --quiet 2>/dev/null || true
    fi
    printf 'origin/%s' "$default_base"
  else
    printf '%s' "$default_base"
  fi
}

sdev_repo_dirty() {
  local wt=$1 status
  status=$(git -C "$wt" status --porcelain 2>/dev/null) || return 2
  [ -n "$(printf '%s\n' "$status" | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1)" ]
}

sdev_repo_content_in_default() {
  local wt=$1 base=$2 dtree mtree
  dtree=$(git -C "$wt" rev-parse --quiet --verify "$base^{tree}" 2>/dev/null) || return 1
  mtree=$(git -C "$wt" merge-tree --write-tree "$base" "$SDEV_BRANCH" 2>/dev/null | head -1) || return 1
  [ -n "$mtree" ] && [ "$mtree" = "$dtree" ]
}

sdev_repo_landed() {
  local key=$1 wt=$2 base=$3 mode=$4
  git -C "$wt" rev-parse --verify --quiet "refs/heads/$SDEV_BRANCH" >/dev/null 2>&1 || return 0
  git -C "$wt" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 || return 1
  if git -C "$wt" diff --quiet "$base...$SDEV_BRANCH" -- 2>/dev/null; then return 0; fi
  if [ -f "$META" ] && grep -q "^landed_$key=" "$META"; then return 0; fi
  if [ "$mode" = local-only ]; then
    git -C "$wt" merge-base --is-ancestor "$SDEV_BRANCH" "$base" 2>/dev/null
  else
    sdev_repo_content_in_default "$wt" "$base"
  fi
}

sdev_teardown_refuse() {
  [ -z "$1" ] && [ -z "$2" ] && return 0
  echo "REFUSED: SDev task $ID has repos not safe to tear down (workspace $SDEV_WS)." >&2
  [ -z "$1" ] || echo "  dirty repos:$1 (commit or discard, then --force)" >&2
  [ -z "$2" ] || echo "  unlanded repos:$2 (land via fm-ship-multi.sh, or --force to discard)" >&2
  return 1
}

validate_sdev_teardown_safety() {
  local repos key path base wt base_ref mode dirty="" unlanded="" seen=0 dirty_rc branch
  repos=$(SDEV_HOME="$SDEV_HOME_DIR" "$SCRIPT_DIR/fm-sdev-registry.sh" repos "$SDEV_PROJ") \
    || { echo "REFUSED: cannot resolve SDev repos for $SDEV_PROJ (SDEV_HOME=$SDEV_HOME_DIR)" >&2; return 1; }
  while IFS=$'\t' read -r key path base _; do
    [ -n "$key" ] || continue
    seen=$((seen + 1))
    if [ -z "$path" ] || [ ! -d "$SDEV_WS/$path" ]; then
      unlanded="$unlanded $key(uninspectable)"
      continue
    fi
    wt="$SDEV_WS/$path"
    if sdev_repo_dirty "$wt"; then
      dirty="$dirty $key"
    else
      dirty_rc=$?
      if [ "$dirty_rc" -eq 2 ]; then
        unlanded="$unlanded $key(uninspectable)"
        continue
      fi
    fi
    if [ "${FM_LANDED_WORK_REQUIRE_TASK_BRANCH:-0}" = 1 ]; then
      branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ "$branch" != "$SDEV_BRANCH" ]; then
        unlanded="$unlanded $key(ownership-unclear)"
        continue
      fi
    fi
    base_ref=$(sdev_repo_base "$wt" "$base")
    mode=$("$SCRIPT_DIR/fm-landing-policy.sh" "$SDEV_PROJ" "$key" | cut -d' ' -f1)
    sdev_repo_landed "$key" "$wt" "$base_ref" "$mode" || unlanded="$unlanded $key"
  done <<EOF
$repos
EOF
  [ "$seen" -gt 0 ] || unlanded="$unlanded registry-empty"
  sdev_teardown_refuse "$dirty" "$unlanded"
}

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  (cd "$target" && pwd -P)
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# shellcheck disable=SC2034 # Consumed by fm-teardown.sh after this library is sourced.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3
# shellcheck disable=SC2034 # Consumed by fm-teardown.sh after this library is sourced.
TEARDOWN_PROCEVENT_RESTORE_FAILED=4

worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0
  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"
  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi
  if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi
  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in secondmate|scout) return 0 ;; esac
  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"; fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)
  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"; fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)
  # shellcheck disable=SC2153 # MODE is required caller context documented in this library header.
  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"; fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}
