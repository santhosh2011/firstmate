#!/usr/bin/env bash
# Behavior tests for the orphaned-stack sweep.
#
# The load-bearing one is test_live_task_stack_is_never_stopped: the sweep runs
# while the captain is working, so stopping a live task's stack destroys the
# environment he is testing in. Every other case here guards the same boundary
# from a different side - unattributable stacks, report-only invocation, and
# stopping strictly the set that was listed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-stack-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-stack-sweep)

# --- fixture ----------------------------------------------------------------
#
# Each case gets a home, a fake docker whose `ps` output is a fixture file and
# whose `stop` calls are appended to a log, and a fake tmux whose window
# inventory decides which recorded tasks still have an endpoint.

make_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  : > "$dir/containers.tsv"
  : > "$dir/stats.tsv"
  : > "$dir/stopped.log"
  : > "$dir/windows.txt"

  : > "$dir/volumes.tsv"
  : > "$dir/removed.log"
  : > "$dir/removed-volumes.log"

  cat > "$dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ps)
    cat "${FM_TEST_CONTAINERS:?}"
    ;;
  stats)
    cat "${FM_TEST_STATS:?}"
    ;;
  system)
    # `docker system df -v` with a range template over .Volumes: name and size.
    awk -F'\t' '{ printf "%s\t%s\n", $1, $3 }' "${FM_TEST_VOLUMES:?}"
    ;;
  volume)
    shift
    case "$1" in
      ls)
        # Only the compose-project label filter is ever used for targeting.
        project=
        for arg in "$@"; do
          case "$arg" in
            label=com.docker.compose.project=*)
              project=${arg#label=com.docker.compose.project=} ;;
          esac
        done
        awk -F'\t' -v p="$project" '$2 == p { print $1 }' "${FM_TEST_VOLUMES:?}"
        ;;
      rm)
        shift
        printf '%s\n' "$@" >> "${FM_TEST_REMOVED_VOLUMES:?}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  stop)
    shift
    printf '%s\n' "$@" >> "${FM_TEST_STOPPED:?}"
    ;;
  rm)
    shift
    printf '%s\n' "$@" >> "${FM_TEST_REMOVED:?}"
    ;;
  *)
    exit 1
    ;;
esac
exit 0
SH

  # tmux is consulted only through the backend's recovery-grade liveness probe:
  # a window listed here exists, and its foreground command is a harness, so the
  # task reads as alive. A window absent from the inventory reads as missing.
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    cat "${FM_TEST_WINDOWS:?}"
    ;;
  display-message)
    printf 'claude\n'
    ;;
  *)
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/docker" "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

# add_container <dir> <container-id> <stack> <working-dir>
add_container() {
  printf '%s\t%s\t%s\t%s-1\n' "$2" "$3" "$4" "$3" >> "$1/containers.tsv"
  printf '%s\t128MiB / 8GiB\n' "$2" >> "$1/stats.tsv"
}

# add_volume <dir> <volume-name> <stack> <docker-size>: a volume docker labels
# as belonging to <stack>.
add_volume() {
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$1/volumes.tsv"
}

# add_live_task <dir> <id> <worktree>: a recorded task whose window exists.
add_live_task() {
  local dir=$1 id=$2 wt=$3
  mkdir -p "$wt"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$dir/project" "harness=claude" "kind=ship"
  printf 'fm-%s\n' "$id" >> "$dir/windows.txt"
}

# add_recorded_task_without_endpoint <dir> <id> <worktree>: still has a durable
# record, but its window is gone from the inventory.
add_recorded_task_without_endpoint() {
  local dir=$1 id=$2 wt=$3
  mkdir -p "$wt"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$dir/project" "harness=claude" "kind=ship"
}

run_sweep() {  # <dir> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_CONTAINERS="$dir/containers.tsv" FM_TEST_STATS="$dir/stats.tsv" \
  FM_TEST_STOPPED="$dir/stopped.log" FM_TEST_WINDOWS="$dir/windows.txt" \
  FM_TEST_VOLUMES="$dir/volumes.tsv" FM_TEST_REMOVED="$dir/removed.log" \
  FM_TEST_REMOVED_VOLUMES="$dir/removed-volumes.log" \
  PATH="$dir/fakebin:$PATH" \
    "$SWEEP" "$@" 2>&1
}

# --- tests ------------------------------------------------------------------

test_orphaned_stack_is_identified() {
  local dir out
  dir=$(make_home orphan)
  # One live task holds the worktree root, so the root is derivable; the stack
  # under test was composed from a sibling directory that no task claims.
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_container "$dir" c-orphan-2 gone-stack "$dir/pool/returned"

  out=$(run_sweep "$dir")
  assert_contains "$out" "ORPHANED  gone-stack" "orphaned stack not reported"
  assert_contains "$out" "2 container(s)" "orphaned container count not reported"
  assert_contains "$out" "Re-run with --stop" "report did not offer the stop step"
  pass "an orphaned stack is identified"
}

test_retired_task_stack_is_identified() {
  local dir out
  dir=$(make_home retired)
  # The task is gone from state/, but its durable per-task directory survives
  # cleanup and still names it, so the stack is confidently this home's debris.
  mkdir -p "$dir/home/data/old-task"
  add_container "$dir" c-old-1 old-task /somewhere/else

  out=$(run_sweep "$dir")
  assert_contains "$out" "ORPHANED  old-task" "stack of a retired task not reported as orphaned"
  pass "a stack named for a retired task is identified"
}

test_live_task_stack_is_never_stopped() {
  local dir out
  dir=$(make_home live)
  add_live_task "$dir" busy-task "$dir/pool/busy"
  add_container "$dir" c-live-1 busy-stack "$dir/pool/busy"
  add_volume "$dir" busy-stack_data busy-stack 900MB

  out=$(run_sweep "$dir")
  assert_contains "$out" "live      busy-stack" "live task's stack not reported as live"
  assert_not_contains "$out" "ORPHANED" "live task's stack was classified as orphaned"

  # The boundary that matters: even asked to stop, it stops nothing.
  out=$(run_sweep "$dir" --stop)
  assert_not_contains "$out" "Stopping" "--stop acted while only a live stack was running"
  [ ! -s "$dir/stopped.log" ] \
    || fail "a live task's stack was stopped: $(cat "$dir/stopped.log")"

  # And with the destructive flag typed too, its data is still untouched.
  out=$(run_sweep "$dir" --stop --remove-volumes)
  [ ! -s "$dir/stopped.log" ] \
    || fail "a live task's stack was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a live task's volumes were removed: $(cat "$dir/removed-volumes.log")"
  pass "a live task's stack is never stopped"
}

test_remove_volumes_requires_stop() {
  local dir out rc
  dir=$(make_home needs-stop)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_data gone-stack 500MB

  set +e
  out=$(run_sweep "$dir" --remove-volumes)
  rc=$?
  set -e
  expect_code 1 "$rc" "--remove-volumes without --stop"
  assert_contains "$out" "requires --stop" "the destructive flag was accepted on its own"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "volumes removed without --stop: $(cat "$dir/removed-volumes.log")"
  pass "--remove-volumes is refused unless --stop is typed too"
}

test_report_prices_volumes_without_touching_them() {
  local dir out
  dir=$(make_home price)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_db gone-stack 1GB
  add_volume "$dir" gone-stack_cache gone-stack 1GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "2 volume(s)" "report did not count the orphaned stack's volumes"
  assert_contains "$out" "1.9GiB" "report did not price the orphaned stack's volumes"
  assert_contains "$out" "--stop alone does NOT reclaim" "report did not distinguish disk from memory"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "report mode removed volumes: $(cat "$dir/removed-volumes.log")"
  pass "the report prices volumes per stack and in total without touching them"
}

test_stop_alone_removes_nothing() {
  local dir out
  dir=$(make_home stop-only)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_db gone-stack 1GB

  out=$(run_sweep "$dir" --stop)
  assert_contains "$out" "Stopped 1 container(s)" "stop run did not report the stopped count"
  assert_contains "$out" "Left 1 volume(s)" "stop run did not report the disk it left behind"
  [ ! -s "$dir/removed.log" ] \
    || fail "--stop removed containers: $(cat "$dir/removed.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "--stop removed volumes: $(cat "$dir/removed-volumes.log")"
  pass "--stop removes nothing and says what disk it left"
}

test_remove_volumes_targets_only_the_orphaned_stack() {
  local dir out removed
  dir=$(make_home rmvol)
  add_live_task "$dir" busy-task "$dir/pool/busy"
  add_container "$dir" c-live-1 busy-stack "$dir/pool/busy"
  add_volume "$dir" busy-stack_db busy-stack 2GB
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_db gone-stack 1GB
  add_volume "$dir" gone-stack_cache gone-stack 500MB
  add_container "$dir" c-foreign-1 someone-elses-db /opt/unrelated
  add_volume "$dir" someone-elses-db_data someone-elses-db 4GB

  out=$(run_sweep "$dir" --stop --remove-volumes)

  removed=$(sort "$dir/removed-volumes.log" | tr '\n' ' ')
  [ "$removed" = "gone-stack_cache gone-stack_db " ] \
    || fail "--remove-volumes targeted volumes outside the orphaned stack: $removed"

  removed=$(sort "$dir/removed.log" | tr '\n' ' ')
  [ "$removed" = "c-orphan-1 " ] \
    || fail "--remove-volumes removed containers outside the orphaned stack: $removed"

  assert_contains "$out" "Reclaimed 1.4GiB" "reclaimed disk total not reported"
  pass "--remove-volumes targets only the orphaned stack's volumes"
}

test_unattributable_stack_is_left_alone() {
  local dir out
  dir=$(make_home unknown)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-foreign-1 someone-elses-db /opt/unrelated

  out=$(run_sweep "$dir")
  assert_contains "$out" "unknown   someone-elses-db" "unattributable stack not reported as unknown"
  assert_contains "$out" "matches no task of this home" "unknown stack gave no reason"
  assert_not_contains "$out" "ORPHANED" "unattributable stack was classified as orphaned"

  out=$(run_sweep "$dir" --stop)
  [ ! -s "$dir/stopped.log" ] \
    || fail "an unattributable stack was stopped: $(cat "$dir/stopped.log")"
  pass "an unattributable stack is left alone"
}

test_bare_invocation_changes_nothing() {
  local dir out
  dir=$(make_home report)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"

  out=$(run_sweep "$dir")
  assert_contains "$out" "Would stop 1 container(s)" "report mode did not say what it would stop"
  [ ! -s "$dir/stopped.log" ] \
    || fail "bare invocation stopped containers: $(cat "$dir/stopped.log")"
  pass "bare invocation changes nothing"
}

test_stop_stops_only_what_it_listed() {
  local dir out stopped
  dir=$(make_home stop)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-live-1 busy-stack "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_container "$dir" c-orphan-2 gone-stack "$dir/pool/returned"
  add_container "$dir" c-foreign-1 someone-elses-db /opt/unrelated

  out=$(run_sweep "$dir" --stop)
  assert_contains "$out" "ORPHANED  gone-stack" "stop run did not list the stack it stopped"
  assert_contains "$out" "Stopped 2 container(s)" "stop run did not report the stopped count"

  stopped=$(sort "$dir/stopped.log" | tr '\n' ' ')
  [ "$stopped" = "c-orphan-1 c-orphan-2 " ] \
    || fail "--stop touched containers it did not list: $stopped"
  pass "--stop stops only what it listed"
}

test_no_go_path_stack_is_protected() {
  local dir out
  dir=$(make_home nogo)
  add_live_task "$dir" live-task "$dir/pool/live"
  printf '%s\n' "$dir/pool" > "$dir/home/config/no-go-paths"
  add_container "$dir" c-nogo-1 gone-stack "$dir/pool/returned"

  out=$(run_sweep "$dir" --stop)
  assert_contains "$out" "declared no-go path" "no-go stack gave no reason"
  assert_not_contains "$out" "ORPHANED" "a stack inside a no-go path was classified as orphaned"
  [ ! -s "$dir/stopped.log" ] \
    || fail "a stack inside a no-go path was stopped: $(cat "$dir/stopped.log")"
  pass "a stack composed from inside a no-go path is protected"
}

test_unreadable_docker_is_a_blocker() {
  local dir out rc
  dir=$(make_home nodocker)
  cat > "$dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon" >&2
exit 1
SH
  chmod +x "$dir/fakebin/docker"

  set +e
  out=$(run_sweep "$dir")
  rc=$?
  set -e
  expect_code 1 "$rc" "unreadable docker"
  assert_contains "$out" "daemon did not answer" "docker failure was not reported as a blocker"
  assert_not_contains "$out" "Nothing to stop" "docker failure was reported as a clean sweep"
  pass "an unreadable docker is a blocker, not an empty sweep"
}

test_orphaned_stack_is_identified
test_retired_task_stack_is_identified
test_live_task_stack_is_never_stopped
test_unattributable_stack_is_left_alone
test_bare_invocation_changes_nothing
test_stop_stops_only_what_it_listed
test_no_go_path_stack_is_protected
test_unreadable_docker_is_a_blocker
test_remove_volumes_requires_stop
test_report_prices_volumes_without_touching_them
test_stop_alone_removes_nothing
test_remove_volumes_targets_only_the_orphaned_stack
