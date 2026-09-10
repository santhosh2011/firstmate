#!/usr/bin/env bash
# Behavior tests for the orphaned-stack sweep.
#
# Cleaning is the sweep's default action, so these tests carry more weight than
# usual. The load-bearing one is test_live_task_stack_is_never_touched: the
# sweep runs while the captain is working, so removing a live task's containers
# or volumes destroys the environment he is testing in. The rest guard the same
# boundary from other sides - unattributable stacks, unattributed volumes,
# --dry-run, targeting strictly the attributed set, and never reaching for a
# blanket prune that could take unrelated projects on this machine with it.
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
  : > "$dir/unreadable.txt"

  : > "$dir/volumes.tsv"
  : > "$dir/removed.log"
  : > "$dir/removed-volumes.log"

  : > "$dir/cmd.log"

  cat > "$dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_CMDLOG:?}"
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
        # Targeting uses only the compose-project label filter; the dangling
        # filter enumerates unreferenced volumes for the report.
        project=
        dangling=0
        for arg in "$@"; do
          case "$arg" in
            label=com.docker.compose.project=*)
              project=${arg#label=com.docker.compose.project=} ;;
            dangling=true) dangling=1 ;;
          esac
        done
        if [ "$dangling" -eq 1 ]; then
          awk -F'\t' '$4 == "dangling" { print $1 }' "${FM_TEST_VOLUMES:?}"
        else
          awk -F'\t' -v p="$project" '$2 == p { print $1 }' "${FM_TEST_VOLUMES:?}"
        fi
        ;;
      inspect)
        shift
        name=
        for arg in "$@"; do
          case "$arg" in
            --format|*'{{'*) ;;
            *) name=$arg ;;
          esac
        done
        awk -F'\t' -v v="$name" '$1 == v { print $2 }' "${FM_TEST_VOLUMES:?}"
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
    # A session the server will not answer for reads as neither present nor
    # gone: the inventory fails with an error the adapter cannot classify.
    session=
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && session=$arg
      prev=$arg
    done
    if [ -n "$session" ] && grep -Fqx "$session" "${FM_TEST_UNREADABLE:?}"; then
      echo "lost server" >&2
      exit 1
    fi
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

# add_volume <dir> <volume-name> <stack> <docker-size> [dangling]: a volume
# docker labels as belonging to <stack>. The fifth field marks it as one docker
# reports under its dangling filter (referenced by no container).
add_volume() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "${5:-}" >> "$1/volumes.tsv"
}

# record_task <dir> <id> <worktree> <session>: the durable record a task leaves
# under state/, without saying anything about whether its endpoint still exists.
record_task() {
  local dir=$1 id=$2 wt=$3 session=$4
  mkdir -p "$wt"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=$session:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$dir/project" "harness=claude" "kind=ship"
}

# add_live_task <dir> <id> <worktree>: a recorded task whose window exists.
add_live_task() {
  local dir=$1 id=$2 wt=$3
  record_task "$dir" "$id" "$wt" firstmate
  printf 'fm-%s\n' "$id" >> "$dir/windows.txt"
}

# add_finished_task <dir> <id> <worktree>: a task whose record survives but whose
# window is gone - what a finished, not-yet-cleaned-up task looks like, and what
# a reissued worktree slot leaves behind beside its current occupant.
add_finished_task() {
  record_task "$1" "$2" "$3" firstmate
}

# add_unreadable_task <dir> <id> <worktree>: a recorded task whose session the
# server will not answer for, so its endpoint is neither present nor gone.
add_unreadable_task() {
  local dir=$1 id=$2 wt=$3
  record_task "$dir" "$id" "$wt" wedged
  printf 'wedged\n' >> "$dir/unreadable.txt"
}

# record_written_at <dir> <id> <touch-stamp>: pin when a task's record was
# written, so "the slot's current occupant" is decided by the fixture rather
# than by how fast the test ran.
record_written_at() {
  touch -t "$3" "$1/home/state/$2.meta"
}

run_sweep() {  # <dir> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_CONTAINERS="$dir/containers.tsv" FM_TEST_STATS="$dir/stats.tsv" \
  FM_TEST_STOPPED="$dir/stopped.log" FM_TEST_WINDOWS="$dir/windows.txt" \
  FM_TEST_UNREADABLE="$dir/unreadable.txt" \
  FM_TEST_VOLUMES="$dir/volumes.tsv" FM_TEST_REMOVED="$dir/removed.log" \
  FM_TEST_REMOVED_VOLUMES="$dir/removed-volumes.log" \
  FM_TEST_CMDLOG="$dir/cmd.log" \
  PATH="$dir/fakebin:$PATH" \
    "$SWEEP" "$@" 2>&1
}

# --- tests ------------------------------------------------------------------

# assert_no_prune <dir> <msg>: no blanket sweep was ever invoked. Boundary 2 -
# a prune cannot tell this machine's unrelated projects from ours.
assert_no_prune() {
  local dir=$1 msg=$2
  ! grep -Eq '(^| )prune( |$)|--volumes|(^| )-a( |$)' "$dir/cmd.log" \
    || fail "$msg: $(grep -E 'prune|--volumes' "$dir/cmd.log" | tr '\n' ' ')"
}

test_orphaned_stack_is_cleaned_by_default() {
  local dir out
  dir=$(make_home orphan)
  # One live task holds the worktree root, so the root is derivable; the stack
  # under test was composed from a sibling directory that no task claims.
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_container "$dir" c-orphan-2 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_db gone-stack 1GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "ORPHANED  gone-stack" "orphaned stack not reported"
  assert_contains "$out" "2 container(s)" "orphaned container count not reported"
  assert_contains "$out" "Reclaimed" "reclaimed space not reported"

  # Cleaning is the default: no flag was passed and the stack is gone.
  assert_grep c-orphan-1 "$dir/stopped.log" "orphaned container was not stopped"
  assert_grep c-orphan-1 "$dir/removed.log" "orphaned container was not removed"
  assert_grep gone-stack_db "$dir/removed-volumes.log" "orphaned stack's volume was not removed"
  assert_no_prune "$dir" "a blanket prune was used to clean an orphaned stack"
  pass "an orphaned stack is stopped, removed and freed by a normal run"
}

test_retired_task_stack_is_identified() {
  local dir out
  dir=$(make_home retired)
  # The task is gone from state/, but its durable per-task directory survives
  # cleanup and still names it, so the stack is confidently this home's debris.
  mkdir -p "$dir/home/data/old-task"
  add_container "$dir" c-old-1 old-task /somewhere/else

  out=$(run_sweep "$dir" --dry-run)
  assert_contains "$out" "ORPHANED  old-task" "stack of a retired task not reported as orphaned"
  pass "a stack named for a retired task is identified"
}

test_live_task_stack_is_never_touched() {
  local dir out
  dir=$(make_home live)
  add_live_task "$dir" busy-task "$dir/pool/busy"
  add_container "$dir" c-live-1 busy-stack "$dir/pool/busy"
  add_volume "$dir" busy-stack_data busy-stack 900MB

  out=$(run_sweep "$dir")
  assert_contains "$out" "live      busy-stack" "live task's stack not reported as live"
  assert_not_contains "$out" "ORPHANED" "live task's stack was classified as orphaned"

  # The boundary that matters. A normal run cleans by default, so a live task's
  # containers and its data must both come through untouched.
  [ ! -s "$dir/stopped.log" ] \
    || fail "a live task's stack was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed.log" ] \
    || fail "a live task's containers were removed: $(cat "$dir/removed.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a live task's volumes were removed: $(cat "$dir/removed-volumes.log")"

  # And still untouched when the captain also asks for unattributed volumes.
  run_sweep "$dir" --remove-dangling-volumes > /dev/null
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a live task's volumes were removed: $(cat "$dir/removed-volumes.log")"
  assert_no_prune "$dir" "a blanket prune ran while a live stack was present"
  pass "a live task's stack and its volumes are never touched"
}

test_live_stack_volumes_survive_when_docker_calls_them_dangling() {
  local dir
  dir=$(make_home live-dangling)
  add_live_task "$dir" busy-task "$dir/pool/busy"
  add_container "$dir" c-live-1 busy-stack "$dir/pool/busy"
  # Docker reports this volume under its dangling filter, but it belongs to a
  # live task's stack, so it is not an unattributed volume.
  add_volume "$dir" busy-stack_data busy-stack 900MB dangling

  run_sweep "$dir" --remove-dangling-volumes > /dev/null
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a live stack's volume was removed as dangling: $(cat "$dir/removed-volumes.log")"
  pass "a live stack's volumes survive even when docker lists them as dangling"
}

test_unattributable_stack_is_left_alone() {
  local dir out
  dir=$(make_home unknown)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-foreign-1 someone-elses-db /opt/unrelated
  add_volume "$dir" someone-elses-db_data someone-elses-db 4GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "unknown   someone-elses-db" "unattributable stack not reported as unknown"
  assert_contains "$out" "matches no task of this home" "unknown stack gave no reason"
  assert_not_contains "$out" "ORPHANED" "unattributable stack was classified as orphaned"
  [ ! -s "$dir/stopped.log" ] \
    || fail "an unattributable stack was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "an unattributable stack's volumes were removed: $(cat "$dir/removed-volumes.log")"
  pass "an unattributable stack is left alone"
}

test_dry_run_changes_nothing() {
  local dir out
  dir=$(make_home dry)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_db gone-stack 1GB

  out=$(run_sweep "$dir" --dry-run)
  assert_contains "$out" "Would clean 1 stack(s)" "dry run did not say what it would clean"
  [ ! -s "$dir/stopped.log" ] || fail "dry run stopped containers: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed.log" ] || fail "dry run removed containers: $(cat "$dir/removed.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "dry run removed volumes: $(cat "$dir/removed-volumes.log")"
  pass "--dry-run changes nothing"
}

test_clean_targets_only_the_attributed_stack() {
  local dir out removed
  dir=$(make_home targeting)
  add_live_task "$dir" busy-task "$dir/pool/busy"
  add_container "$dir" c-live-1 busy-stack "$dir/pool/busy"
  add_volume "$dir" busy-stack_db busy-stack 2GB
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_db gone-stack 1GB
  add_volume "$dir" gone-stack_cache gone-stack 500MB
  add_container "$dir" c-foreign-1 someone-elses-db /opt/unrelated
  add_volume "$dir" someone-elses-db_data someone-elses-db 4GB

  out=$(run_sweep "$dir")

  removed=$(sort "$dir/removed-volumes.log" | tr '\n' ' ')
  [ "$removed" = "gone-stack_cache gone-stack_db " ] \
    || fail "cleaning targeted volumes outside the orphaned stack: $removed"

  removed=$(sort "$dir/removed.log" | tr '\n' ' ')
  [ "$removed" = "c-orphan-1 " ] \
    || fail "cleaning removed containers outside the orphaned stack: $removed"

  assert_contains "$out" "Reclaimed 1.4GiB" "reclaimed disk total not reported"
  assert_no_prune "$dir" "a blanket prune was used instead of targeted removal"
  pass "cleaning targets only the attributed stack's containers and volumes"
}

test_unattributed_volumes_are_reported_but_kept() {
  local dir out
  dir=$(make_home dangling-report)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_volume "$dir" leftover_pgdata "" 3GB dangling

  out=$(run_sweep "$dir")
  assert_contains "$out" "Unattributed volumes" "unattributed volumes not reported"
  assert_contains "$out" "leftover_pgdata" "unattributed volume not named"
  assert_contains "$out" "2.8GiB" "unattributed volume not priced"
  assert_contains "$out" "--remove-dangling-volumes" "report did not name the opt-in flag"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "an unattributed volume was removed by default: $(cat "$dir/removed-volumes.log")"
  pass "unattributed volumes are reported with their size and kept"
}

test_orphan_stack_volume_is_not_also_counted_as_unattributed() {
  local dir out
  local removed
  dir=$(make_home dangling-overlap)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_container "$dir" c-orphan-1 gone-stack "$dir/pool/returned"
  # Docker lists this under its dangling filter too, but the orphaned stack it
  # belongs to is already scheduled to free it: it is attributed, not stray.
  add_volume "$dir" gone-stack_db gone-stack 1GB dangling

  out=$(run_sweep "$dir" --dry-run)
  assert_not_contains "$out" "Unattributed volumes" \
    "an orphaned stack's own volume was also listed as unattributed"

  out=$(run_sweep "$dir" --remove-dangling-volumes)
  removed=$(sort "$dir/removed-volumes.log" | tr '\n' ' ')
  [ "$removed" = "gone-stack_db " ] \
    || fail "the orphaned stack's volume was removed more than once: $removed"
  pass "an orphaned stack's own volume is freed once, not counted as unattributed"
}

test_unattributed_volumes_removed_only_on_request() {
  local dir out
  dir=$(make_home dangling-remove)
  add_live_task "$dir" live-task "$dir/pool/live"
  add_volume "$dir" leftover_pgdata "" 3GB dangling

  out=$(run_sweep "$dir" --remove-dangling-volumes)
  assert_grep leftover_pgdata "$dir/removed-volumes.log" "requested unattributed volume was not removed"
  assert_contains "$out" "Reclaimed" "reclaimed space not reported"
  assert_no_prune "$dir" "a blanket prune was used to remove unattributed volumes"
  pass "unattributed volumes are removed only when the captain asks"
}

test_no_go_path_stack_is_protected() {
  local dir out
  dir=$(make_home nogo)
  add_live_task "$dir" live-task "$dir/pool/live"
  printf '%s\n' "$dir/pool" > "$dir/home/config/no-go-paths"
  add_container "$dir" c-nogo-1 gone-stack "$dir/pool/returned"
  add_volume "$dir" gone-stack_db gone-stack 1GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "declared no-go path" "no-go stack gave no reason"
  assert_not_contains "$out" "ORPHANED" "a stack inside a no-go path was classified as orphaned"
  [ ! -s "$dir/stopped.log" ] \
    || fail "a stack inside a no-go path was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a no-go stack's volumes were removed: $(cat "$dir/removed-volumes.log")"
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
  assert_not_contains "$out" "Nothing to clean" "docker failure was reported as a clean sweep"
  pass "an unreadable docker is a blocker, not an empty sweep"
}

# --- reused worktree slots --------------------------------------------------
#
# A treehouse worktree slot is handed back and reissued, so the same directory,
# and the compose project name derived from it, appear in the records of every
# task that has held it. Attribution therefore names a SET of tasks, and a set
# containing one live task is a live stack however many finished records sit
# beside it. Getting this wrong stops the environment the captain is testing in.

test_reused_slot_with_a_live_occupant_is_live() {
  local dir out slot
  dir=$(make_home reuse-live)
  slot="$dir/pool/3/repo"
  # Same slot, two records: a finished task that has not been cleaned up yet,
  # and the session running in it now.
  add_finished_task "$dir" a-finished-task "$slot"
  add_live_task "$dir" z-live-session "$slot"
  record_written_at "$dir" a-finished-task 202401010900
  record_written_at "$dir" z-live-session 202401020900
  add_container "$dir" c-live-1 live-stack "$slot"
  add_container "$dir" c-live-2 live-stack "$slot"
  add_container "$dir" c-live-3 live-stack "$slot"
  add_volume "$dir" live-stack_db live-stack 2GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "live      live-stack" "a reused slot's live stack was not reported as live"
  assert_contains "$out" "z-live-session" "the live occupant was not the task the stack was reported under"
  assert_not_contains "$out" "ORPHANED" "a live session's stack was classified as orphaned by a stale record of the same slot"

  [ ! -s "$dir/stopped.log" ] \
    || fail "a live session's stack was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed.log" ] \
    || fail "a live session's containers were removed: $(cat "$dir/removed.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a live session's volumes were removed: $(cat "$dir/removed-volumes.log")"
  pass "a stale record of a reused slot cannot make its live stack orphaned"
}

test_reused_slot_with_an_unreadable_claimant_is_left_alone() {
  local dir out slot
  dir=$(make_home reuse-unreadable)
  slot="$dir/pool/4/repo"
  # Nothing here is live, but one claimant cannot be read at all, so the set
  # cannot be settled and the stack is reported rather than cleaned.
  add_finished_task "$dir" a-finished-task "$slot"
  add_finished_task "$dir" b-finished-task "$slot"
  add_unreadable_task "$dir" c-wedged-task "$slot"
  add_container "$dir" c-amb-1 amb-stack "$slot"
  add_volume "$dir" amb-stack_db amb-stack 2GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "left      amb-stack" "an unsettled stack was not reported as left alone"
  assert_contains "$out" "could not be read" "an unsettled stack gave no reason"
  assert_not_contains "$out" "ORPHANED" "an unreadable claimant resolved toward removal"

  [ ! -s "$dir/stopped.log" ] \
    || fail "an unsettled stack was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "an unsettled stack's volumes were removed: $(cat "$dir/removed-volumes.log")"
  pass "a claimant that cannot be read leaves the stack alone"
}

test_reused_slot_is_orphaned_only_when_every_claimant_is_gone() {
  local dir out slot
  dir=$(make_home reuse-gone)
  slot="$dir/pool/5/repo"
  add_finished_task "$dir" z-older-task "$slot"
  add_finished_task "$dir" a-newer-task "$slot"
  record_written_at "$dir" z-older-task 202401010900
  record_written_at "$dir" a-newer-task 202401020900
  add_container "$dir" c-gone-1 gone-stack "$slot"

  out=$(run_sweep "$dir" --dry-run)
  assert_contains "$out" "ORPHANED  gone-stack" "a slot whose every claimant is gone was not reported as orphaned"
  # Reported under the slot's last occupant, not a predecessor of it.
  assert_contains "$out" "task a-newer-task is recorded" "the orphaned stack was reported under an older occupant of the slot"
  assert_contains "$out" "2 tasks claiming this stack" "the report did not say the whole claiming set was gone"
  pass "a reused slot is orphaned only when every task claiming it is gone"
}

test_stack_composed_from_an_ancestor_of_the_pool_is_left_alone() {
  local dir out
  dir=$(make_home ancestor)
  # Reading containment upward stops at this home's task-worktree roots. A stack
  # composed from some broad ancestor of them claims no task at all, rather than
  # claiming every task recorded here and being cleaned once they are all gone.
  add_finished_task "$dir" a-finished-task "$dir/pool/3/repo"
  add_container "$dir" c-broad-1 broad-stack "$dir"
  add_volume "$dir" broad-stack_db broad-stack 2GB

  out=$(run_sweep "$dir")
  assert_not_contains "$out" "ORPHANED" "a stack composed from a broad ancestor was claimed by a finished task"
  [ ! -s "$dir/stopped.log" ] \
    || fail "a stack composed from a broad ancestor was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a broad ancestor stack's volumes were removed: $(cat "$dir/removed-volumes.log")"
  pass "reading containment upward stops at this home's task-worktree roots"
}

test_reused_project_name_with_a_live_occupant_is_live() {
  local dir out
  dir=$(make_home reuse-name)
  # Name attribution has the same blindness as path attribution: a reissued slot
  # hands the same basename, and so the same compose project name, to every task
  # that has held it. This stack was composed from somewhere else entirely, so
  # only the name can attribute it.
  add_finished_task "$dir" a-finished-task "$dir/pool/1/edm-obs"
  add_live_task "$dir" z-live-session "$dir/pool/2/edm-obs"
  add_container "$dir" c-name-1 edm-obs /opt/elsewhere
  add_volume "$dir" edm-obs_db edm-obs 2GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "live      edm-obs" "a stack named for a reused slot was not reported as live"
  assert_not_contains "$out" "ORPHANED" "a live session's stack was classified as orphaned by name"
  [ ! -s "$dir/stopped.log" ] \
    || fail "a live session's stack was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a live session's volumes were removed: $(cat "$dir/removed-volumes.log")"
  pass "a compose project name shared by a reused slot resolves to its live occupant"
}

test_stack_composed_from_a_directory_holding_a_live_worktree_is_live() {
  local dir out
  dir=$(make_home containing-dir)
  # An SDev workspace holds several repo worktrees, and the stack is composed
  # from the workspace directory itself. Containment runs the other way here,
  # but the task is no less live for it.
  add_live_task "$dir" busy-task "$dir/workspace/repo-a"
  add_container "$dir" c-ws-1 workspace-app "$dir/workspace"
  add_volume "$dir" workspace-app_db workspace-app 2GB

  out=$(run_sweep "$dir")
  assert_contains "$out" "live      workspace-app" "a stack composed from a directory holding a live worktree was not live"
  assert_not_contains "$out" "ORPHANED" "a stack holding a live task's worktree was classified as orphaned"
  [ ! -s "$dir/stopped.log" ] \
    || fail "a live workspace's stack was stopped: $(cat "$dir/stopped.log")"
  [ ! -s "$dir/removed-volumes.log" ] \
    || fail "a live workspace's volumes were removed: $(cat "$dir/removed-volumes.log")"
  pass "a stack composed from a directory holding a live worktree is live"
}

test_orphaned_stack_is_cleaned_by_default
test_retired_task_stack_is_identified
test_live_task_stack_is_never_touched
test_live_stack_volumes_survive_when_docker_calls_them_dangling
test_unattributable_stack_is_left_alone
test_dry_run_changes_nothing
test_clean_targets_only_the_attributed_stack
test_unattributed_volumes_are_reported_but_kept
test_orphan_stack_volume_is_not_also_counted_as_unattributed
test_unattributed_volumes_removed_only_on_request
test_no_go_path_stack_is_protected
test_unreadable_docker_is_a_blocker
test_reused_slot_with_a_live_occupant_is_live
test_reused_slot_with_an_unreadable_claimant_is_left_alone
test_reused_slot_is_orphaned_only_when_every_claimant_is_gone
test_reused_project_name_with_a_live_occupant_is_live
test_stack_composed_from_a_directory_holding_a_live_worktree_is_live
test_stack_composed_from_an_ancestor_of_the_pool_is_left_alone
