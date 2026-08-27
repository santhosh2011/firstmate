#!/usr/bin/env bash
# Tests for fm-brief.sh --sdev: the multi-repo SDev ship brief variant.
#
# It lists one git worktree per repo (resolved from the SDev registry), each on
# branch task/<slug>, and gives a combined definition of done across the repos.
# The flag is ship-only and requires the project to be SDev-backed. The
# single-repo ship brief is unchanged when the flag is absent (guarded by the
# existing fm-brief.test.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
FIXTURES="$ROOT/tests/fixtures/sdev"
TMP_ROOT=$(fm_test_tmproot fm-sdev-brief)

# make_case builds an fm HOME and a SDEV_HOME carrying the registry fixture.
make_case() {
  local name=$1 proj=$2 fixture=$3 home sdev
  home="$TMP_ROOT/$name/home"
  sdev="$TMP_ROOT/$name/sdev"
  mkdir -p "$home/data" "$home/state" "$sdev/core/projects.d"
  cp "$FIXTURES/$fixture" "$sdev/core/projects.d/$proj.yml"
  printf '%s|%s\n' "$home" "$sdev"
}

run_brief() {
  local home=$1 sdev=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    SDEV_HOME="$sdev" "$BRIEF" "$@"
}

test_sdev_ship_brief_lists_repos_and_branches() {
  local parts home sdev brief
  parts=$(make_case list scdi multi-repo.yml)
  IFS='|' read -r home sdev <<<"$parts"
  run_brief "$home" "$sdev" task-list scdi --sdev --mode no-mistakes >/dev/null 2>&1 \
    || fail "sdev ship brief should scaffold for an SDev-backed project"
  brief="$home/data/task-list/brief.md"
  assert_present "$brief" "sdev brief: written"
  assert_grep "multi-repo SDev workspace" "$brief" "sdev brief: describes the multi-repo workspace"
  assert_grep "- api (worktree: multi_api_src/, branch task/task-list)" "$brief" "sdev brief: lists api with its worktree dir and task branch"
  assert_grep "- ui (worktree: multi_ui_src/, branch task/task-list)" "$brief" "sdev brief: lists ui"
  assert_grep "- common (worktree: common/, branch task/task-list)" "$brief" "sdev brief: lists common"
  assert_grep "done: ready for review across repos" "$brief" "sdev brief: combined definition of done"
  assert_grep "you do not push or open PRs yourself" "$brief" "sdev brief: firstmate coordinates the ship"
  pass "fm-brief --sdev scaffolds a multi-repo ship brief with per-repo worktrees and branches"
}

test_sdev_flag_rejected_for_scout() {
  local parts home sdev err
  parts=$(make_case scout scdi multi-repo.yml)
  IFS='|' read -r home sdev <<<"$parts"
  err="$TMP_ROOT/scout.err"
  run_brief "$home" "$sdev" task-scout scdi --scout --sdev >/dev/null 2>"$err" \
    && fail "sdev: --sdev with --scout must be rejected"
  assert_grep "applies only to crewmate ship briefs" "$err" "sdev: error explains ship-only"
  pass "fm-brief --sdev is rejected for a scout brief"
}

test_sdev_flag_rejected_for_non_sdev_project() {
  local home err
  home="$TMP_ROOT/nonsdev/home"
  mkdir -p "$home/data" "$home/state"
  err="$TMP_ROOT/nonsdev.err"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    env -u SDEV_HOME "$BRIEF" task-x notaproject --sdev --mode no-mistakes >/dev/null 2>"$err" \
    && fail "sdev: --sdev for a non-SDev project must be rejected"
  assert_grep "not SDev-backed" "$err" "sdev: error explains the project is not SDev-backed"
  pass "fm-brief --sdev refuses a project that is not SDev-backed"
}

test_sdev_ship_brief_lists_repos_and_branches
test_sdev_flag_rejected_for_scout
test_sdev_flag_rejected_for_non_sdev_project
