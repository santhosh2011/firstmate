#!/usr/bin/env bash
# Tests for bin/fm-run.sh: bring an SDev task's stack up and surface its live URL.
#
# fm-run reads the task's meta (sdev_home, slug, project), then drives the sdev
# CLI: `up` boots the stack, `url` prints the task's live URL from `sdev ls
# --json`, `open` opens it. A task with no slug= in meta is not an SDev task and
# is rejected, so fm-run never guesses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN="$ROOT/bin/fm-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-tests)

assert_eq() {
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- expected ---"$'\n'"$2"$'\n'"--- actual ---"$'\n'"$1"
}

# Fake sdev: `up`/`open` drop a marker naming the target; `ls --json` reports one
# running task with a URL. FM_FAKE_SDEV_URL overrides the reported URL.
make_run_fakebin() {
  local dir=$1 marker=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/sdev" <<SH
#!/usr/bin/env bash
set -u
marker='$marker'
proj=
while [ "\${1:-}" = "-p" ]; do proj=\$2; shift 2; done
cmd=\${1:-}; slug=\${2:-}
case "\$cmd" in
  up) printf 'up %s %s\n' "\$proj" "\$slug" >> "\$marker" ;;
  open) printf 'open %s %s\n' "\$proj" "\$slug" >> "\$marker" ;;
  ls)
    printf '{"alive":[{"task":"scdi/%s","nginx_port":5600,"url":"%s","status":"running"}]}\n' \
      "\${FM_FAKE_SDEV_SLUG:-task-x}" "\${FM_FAKE_SDEV_URL-http://localhost:5600/}"
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/sdev"
  printf '%s\n' "$fakebin"
}

setup_case() {
  local name=$1 slug=$2 case_dir home fakebin marker
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  marker="$case_dir/sdev.log"
  mkdir -p "$home/state" "$home/projects/scdi"
  fakebin=$(make_run_fakebin "$case_dir/fake" "$marker")
  fm_write_meta "$home/state/task-$name.meta" \
    "window=fm-task-$name" \
    "worktree=$case_dir/sdev/projects/scdi/$slug" \
    "project=$home/projects/scdi" \
    "harness=claude" \
    "kind=ship" \
    "sdev_home=$case_dir/sdev" \
    "slug=$slug" \
    "repos=api ui common"
  printf '%s|%s|%s|%s\n' "$case_dir" "$home" "$fakebin" "$marker"
}

run_run() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$RUN" "$@"
}

test_up_brings_stack_up() {
  local parts case_dir home fakebin marker
  parts=$(setup_case up "$FM_FAKE_SDEV_SLUG_UP")
  IFS='|' read -r case_dir home fakebin marker <<<"$parts"
  run_run "$home" "$fakebin" task-up up >/dev/null 2>"$case_dir/err" \
    || { cat "$case_dir/err"; fail "fm-run up should succeed"; }
  assert_grep "up scdi task-up-slug" "$marker" "up: sdev up called with project and slug"
  pass "fm-run up brings the SDev task stack up"
}

test_url_prints_live_url() {
  local parts case_dir home fakebin marker out
  parts=$(setup_case url task-url-slug)
  IFS='|' read -r case_dir home fakebin marker <<<"$parts"
  out=$(FM_FAKE_SDEV_SLUG=task-url-slug FM_FAKE_SDEV_URL="http://localhost:5600/" \
    run_run "$home" "$fakebin" task-url url 2>"$case_dir/err") \
    || { cat "$case_dir/err"; fail "fm-run url should succeed"; }
  assert_eq "$out" "http://localhost:5600/" "url: prints the task's live URL from sdev ls"
  pass "fm-run url surfaces the task's live URL"
}

test_url_missing_is_reported() {
  local parts case_dir home fakebin marker out code
  parts=$(setup_case nourl task-nourl-slug)
  IFS='|' read -r case_dir home fakebin marker <<<"$parts"
  set +e
  out=$(FM_FAKE_SDEV_SLUG=task-nourl-slug FM_FAKE_SDEV_URL="" \
    run_run "$home" "$fakebin" task-nourl url 2>"$case_dir/err")
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "url: an empty URL (stack not up) should be a non-zero result"
  assert_eq "$out" "" "url: nothing printed when there is no live URL"
  pass "fm-run url reports when there is no live URL yet"
}

test_non_sdev_task_rejected() {
  local case_dir home fakebin marker code
  case_dir="$TMP_ROOT/nonsdev"
  home="$case_dir/home"
  marker="$case_dir/sdev.log"
  mkdir -p "$home/state"
  fakebin=$(make_run_fakebin "$case_dir/fake" "$marker")
  fm_write_meta "$home/state/task-th.meta" \
    "window=fm-task-th" "worktree=$case_dir/wt" "project=$home/projects/foo" \
    "harness=claude" "kind=ship"
  set +e
  run_run "$home" "$fakebin" task-th up >/dev/null 2>"$case_dir/err"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "non-sdev: a treehouse task (no slug=) must be rejected"
  assert_grep "not an SDev task" "$case_dir/err" "non-sdev: error explains the task is not SDev-backed"
  pass "fm-run rejects a non-SDev task instead of guessing"
}

FM_FAKE_SDEV_SLUG_UP=task-up-slug
test_up_brings_stack_up
test_url_prints_live_url
test_url_missing_is_reported
test_non_sdev_task_rejected
