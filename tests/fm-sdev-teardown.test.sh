#!/usr/bin/env bash
# Tests for fm-teardown.sh's multi-repo SDev teardown safety (phase 5).
#
# For an SDev task (slug= in meta) the landed-work gate applies PER REPO: every
# changed repo's task/<slug> branch must be landed (a phase-4 landed_<key>=
# marker, content already in its default, or - for a local-only repo - merged
# into its local base) and clean, or teardown refuses and names the offenders.
# On success it archives the workspace with `sdev end` instead of a treehouse
# return. A treehouse task (no slug=) is unchanged - guarded by the existing
# tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-sdev-teardown)
SLUG=task-td-x1

make_fakebin() {
  local dir=$1 sdev_log=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/sdev" <<SH
#!/usr/bin/env bash
printf 'sdev %s\n' "\$*" >> '$sdev_log'
exit 0
SH
  chmod +x "$fakebin/sdev"
  fm_fake_exit0 "$fakebin" tmux gh gh-axi treehouse tasks-axi
  printf '%s\n' "$fakebin"
}

# A remote repo worktree on task/<slug> with a change (origin/base lacks it).
make_remote_repo() {
  local work=$1 ws=$2 path=$3 base=$4 src origin
  src="$work/src-$path"; origin="$work/o-$path.git"
  git init -q "$src"; printf 'base\n' > "$src/f.txt"
  git -C "$src" add f.txt; git -C "$src" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$src" branch -M "$base"
  git clone -q --bare "$src" "$origin"
  git -C "$src" remote add origin "file://$origin"; git -C "$src" push -q origin "$base"
  git -C "$src" worktree add -q -b "task/$SLUG" "$ws/$path" "$base"
  printf 'change\n' > "$ws/$path/f.txt"
  git -C "$ws/$path" add f.txt; git -C "$ws/$path" -c user.email=t@t -c user.name=t commit -qm change
}

# A local-only repo worktree on task/<slug> with a change; merged=1 fast-forwards
# the source base to include it.
make_local_repo() {
  local work=$1 ws=$2 path=$3 base=$4 merged=$5 src
  src="$work/src-$path"
  git init -q "$src"; printf 'base\n' > "$src/f.txt"
  git -C "$src" add f.txt; git -C "$src" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$src" branch -M "$base"
  git -C "$src" worktree add -q -b "task/$SLUG" "$ws/$path" "$base"
  printf 'change\n' > "$ws/$path/f.txt"
  git -C "$ws/$path" add f.txt; git -C "$ws/$path" -c user.email=t@t -c user.name=t commit -qm change
  [ "$merged" = 1 ] || return 0
  git -C "$src" merge --ff-only --quiet "task/$SLUG"
}

# Build a 2-repo SDev task: api remote (no-mistakes), common local-only.
# api_landed=1 records landed_api; common_merged=1 merges common's local base.
setup_task() {
  local case_dir=$1 api_landed=$2 common_merged=$3 home ws sdev cfg
  home="$case_dir/home"; ws="$case_dir/ws"; sdev="$case_dir/sdev"; cfg="$home/config"
  mkdir -p "$home/state" "$ws" "$sdev/core/projects.d" "$cfg"
  make_remote_repo "$case_dir" "$ws" api_src develop
  make_local_repo "$case_dir" "$ws" common_src develop "$common_merged"
  cat > "$sdev/core/projects.d/scdi.yml" <<'YML'
repos:
  api: { path: api_src, default_base: develop, compose_role: api }
  common: { path: common_src, default_base: develop, compose_role: common }
YML
  cat > "$cfg/landing-policy.json" <<'JSON'
{ "projects": { "scdi": { "default": {"mode":"no-mistakes"}, "repos": { "common": {"mode":"local-only"} } } } }
JSON
  fm_write_meta "$home/state/$SLUG.meta" \
    "window=firstmate:fm-$SLUG" "worktree=$ws" "project=$home/projects/scdi" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "sdev_home=$sdev" "slug=$SLUG" "repos=api common"
  [ "$api_landed" = 1 ] && echo "landed_api=https://github.com/o/api/pull/1" >> "$home/state/$SLUG.meta"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

run_teardown() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" SDEV_HOME="$home/sdev" \
    "$TEARDOWN" "$@"
}

test_refuses_while_a_repo_unlanded() {
  local case_dir home fakebin sdev_log code
  case_dir="$TMP_ROOT/unlanded"
  home=$(setup_task "$case_dir" 0 1)   # api NOT landed, common merged
  sdev_log="$case_dir/sdev.log"; : > "$sdev_log"
  fakebin=$(make_fakebin "$case_dir/fake" "$sdev_log")
  set +e
  run_teardown "$home" "$fakebin" "$SLUG" >/dev/null 2>"$case_dir/err"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "unlanded: teardown must refuse while a repo is unlanded"
  assert_grep "api" "$case_dir/err" "unlanded: the unlanded repo (api) is named"
  assert_grep "REFUSED" "$case_dir/err" "unlanded: teardown reports REFUSED"
  assert_no_grep "end" "$sdev_log" "unlanded: sdev end must NOT run when refused"
  assert_present "$home/state/$SLUG.meta" "unlanded: meta preserved on refusal"
  pass "fm-teardown refuses an SDev task while any repo is unlanded"
}

test_refuses_dirty_repo() {
  local case_dir home fakebin sdev_log code
  case_dir="$TMP_ROOT/dirty"
  home=$(setup_task "$case_dir" 1 1)   # both landed...
  printf 'dirty\n' > "$case_dir/ws/api_src/f.txt"   # ...but api worktree is dirty
  sdev_log="$case_dir/sdev.log"; : > "$sdev_log"
  fakebin=$(make_fakebin "$case_dir/fake" "$sdev_log")
  set +e
  run_teardown "$home" "$fakebin" "$SLUG" >/dev/null 2>"$case_dir/err"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "dirty: teardown must refuse a dirty repo even when landed"
  assert_grep "api" "$case_dir/err" "dirty: the dirty repo (api) is named"
  assert_no_grep "end" "$sdev_log" "dirty: sdev end must NOT run when refused"
  pass "fm-teardown refuses an SDev task with a dirty repo"
}

test_succeeds_when_all_landed() {
  local case_dir home fakebin sdev_log
  case_dir="$TMP_ROOT/landed"
  home=$(setup_task "$case_dir" 1 1)   # api landed marker, common merged
  sdev_log="$case_dir/sdev.log"; : > "$sdev_log"
  fakebin=$(make_fakebin "$case_dir/fake" "$sdev_log")
  run_teardown "$home" "$fakebin" "$SLUG" >/dev/null 2>"$case_dir/err" \
    || { cat "$case_dir/err"; fail "landed: teardown should succeed when all repos landed"; }
  assert_grep "end $SLUG" "$sdev_log" "landed: sdev end archives the workspace"
  assert_absent "$home/state/$SLUG.meta" "landed: meta removed on success"
  pass "fm-teardown archives the SDev workspace once every repo has landed"
}

test_force_discards_unlanded() {
  local case_dir home fakebin sdev_log
  case_dir="$TMP_ROOT/force"
  home=$(setup_task "$case_dir" 0 0)   # nothing landed
  sdev_log="$case_dir/sdev.log"; : > "$sdev_log"
  fakebin=$(make_fakebin "$case_dir/fake" "$sdev_log")
  run_teardown "$home" "$fakebin" "$SLUG" --force >/dev/null 2>"$case_dir/err" \
    || { cat "$case_dir/err"; fail "force: --force must discard and archive regardless"; }
  assert_grep "end $SLUG" "$sdev_log" "force: sdev end still archives under --force"
  assert_absent "$home/state/$SLUG.meta" "force: meta removed under --force"
  pass "fm-teardown --force discards and archives an SDev task without the landed gate"
}

test_refuses_while_a_repo_unlanded
test_refuses_dirty_repo
test_succeeds_when_all_landed
test_force_discards_unlanded
