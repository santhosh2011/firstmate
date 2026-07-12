#!/usr/bin/env bash
# Tests for fm-review-diff.sh's combined multi-repo SDev review (phase 3).
#
# When the task meta is an SDev task (slug=/repos=/sdev_home=), fm-review-diff
# compares each repo's task/<slug> branch against that repo's OWN authoritative
# base (its default_base from the registry, which may differ per repo) and emits
# one combined diff labeled per repo, excluding untouched repos. A treehouse task
# (project=, no slug=) is unchanged - guarded by the existing
# tests/fm-review-diff.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-sdev-review-diff)
SLUG=task-rev-x1

# make_repo: a source repo with a named base branch and an origin, plus a
# task/<slug> worktree in the workspace; commit a change only when changed=1.
make_repo() {
  local work=$1 ws=$2 path=$3 base=$4 changed=$5 src origin
  src="$work/src-$path"
  origin="$work/origin-$path.git"
  git init -q "$src"
  printf 'base\n' > "$src/file.txt"
  git -C "$src" add file.txt
  git -C "$src" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$src" branch -M "$base"
  git clone -q --bare "$src" "$origin"
  git -C "$src" remote add origin "file://$origin"
  git -C "$src" push -q origin "$base"
  git -C "$src" worktree add -q -b "task/$SLUG" "$ws/$path" "$base"
  [ "$changed" = 1 ] || return 0
  printf '%s-changed-content\n' "$path" > "$ws/$path/file.txt"
  git -C "$ws/$path" add file.txt
  git -C "$ws/$path" -c user.email=t@t -c user.name=t commit -qm "$path change"
}

# Build a 3-repo SDev task: api (base develop, changed), ui (base main, changed),
# common (base develop, UNCHANGED). Registry carries per-repo path + default_base.
setup_task() {
  local case_dir=$1 home ws sdev
  home="$case_dir/home"
  ws="$case_dir/ws"
  sdev="$case_dir/sdev"
  mkdir -p "$home/state" "$ws" "$sdev/core/projects.d"
  make_repo "$case_dir" "$ws" api_src develop 1
  make_repo "$case_dir" "$ws" ui_src main 1
  make_repo "$case_dir" "$ws" common_src develop 0
  cat > "$sdev/core/projects.d/scdi.yml" <<'YML'
repos:
  api:
    path: api_src
    default_base: develop
    compose_role: api
  ui:
    path: ui_src
    default_base: main
    compose_role: ui
  common:
    path: common_src
    default_base: develop
    compose_role: common
YML
  fm_write_meta "$home/state/$SLUG.meta" \
    "window=fm-$SLUG" \
    "worktree=$ws" \
    "project=$home/projects/scdi" \
    "harness=claude" \
    "kind=ship" \
    "sdev_home=$sdev" \
    "slug=$SLUG" \
    "repos=api ui common"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

run_review() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$REVIEW" "$@"
}

test_combined_diff_shows_only_changed_repos() {
  local case_dir home out
  case_dir="$TMP_ROOT/combined"
  home=$(setup_task "$case_dir")
  out=$(run_review "$home" "$SLUG" 2>"$case_dir/err") \
    || { cat "$case_dir/err"; fail "combined review should succeed"; }

  assert_contains "$out" "repo: api (base origin/develop)" "combined: api labeled with its own base"
  assert_contains "$out" "api_src-changed-content" "combined: api change content shown"
  assert_contains "$out" "repo: ui (base origin/main)" "combined: ui labeled with its own (different) base"
  assert_contains "$out" "ui_src-changed-content" "combined: ui change content shown"
  assert_not_contains "$out" "repo: common" "combined: the untouched repo is excluded"
  assert_not_contains "$out" "common_src-changed" "combined: no content from the untouched repo"
  pass "fm-review-diff shows one combined diff over only the changed repos, labeled per repo"
}

test_stat_only_covers_changed_repos() {
  local case_dir home out
  case_dir="$TMP_ROOT/stat"
  home=$(setup_task "$case_dir")
  out=$(run_review "$home" "$SLUG" --stat 2>"$case_dir/err") \
    || { cat "$case_dir/err"; fail "combined --stat review should succeed"; }
  assert_contains "$out" "repo: api (base origin/develop)" "stat: api section present"
  assert_contains "$out" "repo: ui (base origin/main)" "stat: ui section present"
  assert_not_contains "$out" "repo: common" "stat: untouched repo excluded"
  assert_not_contains "$out" "api_src-changed-content" "stat: full diff body omitted with --stat"
  pass "fm-review-diff --stat summarizes the changed repos without full diff bodies"
}

test_combined_diff_shows_only_changed_repos
test_stat_only_covers_changed_repos
