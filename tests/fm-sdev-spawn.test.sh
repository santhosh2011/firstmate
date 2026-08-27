#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's SDev workspace provider (phase 2).
#
# When the target project is SDev-backed (fm-sdev-registry reports it under a set
# SDEV_HOME), fm-spawn creates a multi-repo SDev workspace with `sdev new <slug>`
# instead of a treehouse worktree, launches the crewmate in the workspace dir,
# asserts per-repo worktree isolation, and records sdev_home=/slug=/repos= in meta.
# When the project is NOT SDev-backed, the treehouse path is taken exactly as
# before - this file's control case guards that byte-for-byte contract.
#
# Fakes, like the other fm-spawn suites: a fake tmux captures the launch command
# and reports the pane cwd; a fake treehouse logs whether it was invoked; a fake
# sdev creates genuine per-repo git worktrees so the isolation assertion runs
# against real git state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
FIXTURES="$ROOT/tests/fixtures/sdev"
TMP_ROOT=$(fm_test_tmproot fm-sdev-spawn)

assert_eq() {
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- expected ---"$'\n'"$2"$'\n'"--- actual ---"$'\n'"$1"
}

# Fake sdev: `new` builds real per-repo worktrees from sources it reads out of the
# registry with yq; `cd` prints the workspace dir. Broken-isolation mode (a plain
# dir instead of a worktree) is triggered by FM_FAKE_SDEV_BREAK=<repo-path>.
make_sdev_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/sdev" <<'SH'
#!/usr/bin/env bash
set -u
proj=
while [ "${1:-}" = "-p" ]; do proj=$2; shift 2; done
cmd=${1:-}; slug=${2:-}
home=${SDEV_HOME:?}
reg="$home/core/projects.d/$proj.yml"
ws="$home/projects/$proj/$slug"
case "$cmd" in
  new)
    mkdir -p "$ws"
    # The two pieces of sdev-owned state outside the workspace dir, modelled so a
    # case can tell "left alone" from "force-removed": `destroy` takes the port
    # offset and the ledger entry with the worktrees, nothing else touches them.
    mkdir -p "$home/state/offsets" "$home/state/ledger"
    printf '4200\n' > "$home/state/offsets/$proj-$slug"
    printf 'alive %s\n' "$slug" > "$home/state/ledger/$proj-$slug"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ "${FM_FAKE_SDEV_BREAK:-}" = "$p" ]; then
        mkdir -p "$ws/$p"
      else
        git -C "$home/core/$proj/$p" worktree add -q -b "task/$slug" "$ws/$p" >/dev/null 2>&1
      fi
    done < <(yq -r '.repos | to_entries | .[] | .value.path' "$reg")
    ;;
  cd) printf '%s\n' "$ws" ;;
  up) : > "$ws/.fake-up" ;;
  destroy)
    # The removing verb: drop each per-repo worktree from its source repo and
    # take the workspace dir, the port offset, and the ledger entry with it.
    # `end` archives instead, and this fake keeps that distinction so a test can
    # tell the two apart by real state rather than by which command ran.
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      git -C "$home/core/$proj/$p" worktree remove --force "$ws/$p" >/dev/null 2>&1 || true
    done < <(yq -r '.repos | to_entries | .[] | .value.path' "$reg")
    rm -rf "$ws"
    rm -f "$home/state/offsets/$proj-$slug" "$home/state/ledger/$proj-$slug"
    ;;
  *) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/sdev"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  # The relaunch precondition reads the pane's foreground command to decide
  # whether the endpoint is positively agent-free. Default keeps the historic
  # answer; a case that needs an agent-free verdict sets a shell name.
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-firstmate}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  # A recorded window must appear in a successful inventory before tmux's
  # foreground read is trusted, so a relaunch case declares its window here.
  list-windows) printf '%s' "${FM_FAKE_WINDOWS:-}"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    [ -z "${FM_FAKE_SEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf 'called %s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# Build a case: an fm HOME, an SDEV_HOME with the registry fixture and one source
# repo per registry repo, a project clone dir, a brief, and the fake bin.
setup_case() {
  local name=$1 proj=$2 fixture=$3 case_dir home sdev fakebin id p
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  sdev="$case_dir/sdev"
  fakebin=$(make_sdev_fakebin "$case_dir/fake")
  mkdir -p "$home/data/task-$name" "$home/projects/$proj" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief\n' > "$home/data/task-$name/brief.md"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$sdev/core/projects.d"
  cp "$FIXTURES/$fixture" "$sdev/core/projects.d/$proj.yml"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    fm_git_init_commit "$sdev/core/$proj/$p"
  done < <(yq -r '.repos | to_entries | .[] | .value.path' "$sdev/core/projects.d/$proj.yml")
  printf '%s|%s|%s|%s\n' "$case_dir" "$home" "$sdev" "$fakebin"
}

# Ship spawns carry the explicit per-task delivery contract fm-spawn.sh requires.
# run_spawn_raw is the same call without it, for --relaunch, which reuses the
# task's recorded mode and refuses a flag that would override it.
run_spawn() {
  run_spawn_raw "$@" --mode no-mistakes --yolo off
}

run_spawn_raw() {
  local home=$1 sdev=$2 fakebin=$3
  shift 3
  PATH="$fakebin:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  SDEV_HOME="$sdev" \
  "$SPAWN" "$@"
}

meta_val() { grep "^$2=" "$1" | head -1 | cut -d= -f2-; }

test_sdev_backed_takes_sdev_path() {
  local parts case_dir home sdev fakebin id meta ws
  parts=$(setup_case backed scdi multi-repo.yml)
  IFS='|' read -r case_dir home sdev fakebin <<<"$parts"
  id=task-backed
  ws="$sdev/projects/scdi/$id"
  FM_FAKE_PANE_PATH="$ws" \
  FM_FAKE_SEND_LOG="$case_dir/send.log" \
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    run_spawn "$home" "$sdev" "$fakebin" "$id" projects/scdi >/dev/null 2>"$case_dir/err" \
    || { echo "spawn failed:"; cat "$case_dir/err"; fail "sdev-backed spawn should succeed"; }

  meta="$home/state/$id.meta"
  assert_present "$meta" "sdev-backed: meta written"
  assert_eq "$(meta_val "$meta" sdev_home)" "$sdev" "sdev-backed: sdev_home recorded"
  assert_eq "$(meta_val "$meta" slug)" "$id" "sdev-backed: slug recorded"
  assert_eq "$(meta_val "$meta" repos)" "api ui common" "sdev-backed: repos keys recorded in order"
  assert_eq "$(meta_val "$meta" worktree)" "$ws" "sdev-backed: worktree is the SDev workspace"
  assert_grep "$ws" "$case_dir/send.log" "sdev-backed: crewmate pane is cd'd into the workspace"
  assert_grep "$home/data/$id/brief.md" "$case_dir/launch.log" "sdev-backed: crewmate launch command is sent"
  assert_no_grep "treehouse get" "$case_dir/send.log" "sdev-backed: treehouse get must NOT be sent on the SDev path"
  pass "fm-spawn takes the SDev workspace path for an SDev-backed project"
}

test_sdev_workspace_repos_are_isolated_worktrees() {
  local parts case_dir home sdev fakebin id ws p
  parts=$(setup_case iso scdi multi-repo.yml)
  IFS='|' read -r case_dir home sdev fakebin <<<"$parts"
  id=task-iso
  ws="$sdev/projects/scdi/$id"
  FM_FAKE_PANE_PATH="$ws" run_spawn "$home" "$sdev" "$fakebin" "$id" projects/scdi \
    >/dev/null 2>"$case_dir/err" || { cat "$case_dir/err"; fail "iso spawn should succeed"; }
  for p in multi_api_src multi_ui_src common; do
    local d_real top_real
    d_real=$(cd "$ws/$p" && pwd -P)
    top_real=$(cd "$(git -C "$ws/$p" rev-parse --show-toplevel)" && pwd -P)
    assert_eq "$top_real" "$d_real" \
      "isolation: $p is its own worktree root, distinct from its source"
  done
  pass "fm-spawn's SDev workspace holds one isolated git worktree per repo"
}

test_sdev_isolation_failure_aborts() {
  local parts case_dir home sdev fakebin id meta
  parts=$(setup_case broken scdi multi-repo.yml)
  IFS='|' read -r case_dir home sdev fakebin <<<"$parts"
  id=task-broken
  set +e
  FM_FAKE_SDEV_BREAK=common \
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    run_spawn "$home" "$sdev" "$fakebin" "$id" projects/scdi >/dev/null 2>"$case_dir/err"
  local code=$?
  set -e
  [ "$code" -ne 0 ] || fail "broken isolation: spawn must abort when a repo dir is not a worktree"
  assert_grep "isolated git worktree" "$case_dir/err" "broken isolation: error names the isolation failure"
  [ ! -s "$case_dir/launch.log" ] || fail "broken isolation: no crewmate is launched"
  pass "fm-spawn aborts the SDev spawn when a repo dir is not an isolated worktree"
}

test_non_sdev_project_uses_treehouse_unchanged() {
  local parts case_dir home sdev fakebin id meta wt
  parts=$(setup_case control scdi multi-repo.yml)
  IFS='|' read -r case_dir home sdev fakebin <<<"$parts"
  id=task-control
  # A real worktree the fake pane will report, standing in for treehouse get.
  wt="$case_dir/wt"
  fm_git_worktree "$case_dir/proj" "$wt" wt-control
  # SDEV_HOME unset: the project is not SDev-backed, so the treehouse path runs.
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_SEND_LOG="$case_dir/send.log" \
    env -u SDEV_HOME "$SPAWN" "$id" projects/scdi --mode no-mistakes --yolo off >/dev/null 2>"$case_dir/err" \
    || { cat "$case_dir/err"; fail "control spawn should succeed"; }

  meta="$home/state/$id.meta"
  assert_grep "treehouse get" "$case_dir/send.log" "control: treehouse get IS sent for a non-SDev project"
  assert_no_grep "sdev_home=" "$meta" "control: no sdev_home in a treehouse task's meta"
  assert_no_grep "slug=" "$meta" "control: no slug in a treehouse task's meta"
  assert_no_grep "repos=" "$meta" "control: no repos in a treehouse task's meta"
  assert_eq "$(meta_val "$meta" worktree)" "$wt" "control: worktree is the treehouse worktree"
  pass "fm-spawn leaves the treehouse path unchanged for a non-SDev project"
}

# A no-go refusal on the SDev path must leave nothing inside the operator's
# off-limits directory, which for this provider means REMOVING the workspace, not
# archiving it: an archive under SDEV_HOME would still sit inside the declared
# prefix. Removal is asserted against real git state - the workspace dir is gone
# and each source repo no longer lists its per-repo worktree.
test_sdev_workspace_inside_a_no_go_path_is_refused_and_removed() {
  local parts case_dir home sdev fakebin id ws p code
  parts=$(setup_case nogo scdi multi-repo.yml)
  IFS='|' read -r case_dir home sdev fakebin <<<"$parts"
  id=task-nogo
  ws="$sdev/projects/scdi/$id"
  printf '%s\n' "$sdev/projects" > "$home/config/no-go-paths"
  set +e
  FM_FAKE_PANE_PATH="$ws" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    run_spawn "$home" "$sdev" "$fakebin" "$id" projects/scdi >/dev/null 2>"$case_dir/err"
  code=$?
  set -e
  rm -rf "/tmp/fm-$id"

  [ "$code" -ne 0 ] || fail "no-go: an SDev workspace inside a declared prefix must refuse"
  assert_grep "is inside the no-go path" "$case_dir/err" "no-go: the workspace was not checked"
  [ ! -d "$ws" ] || fail "no-go: the refusal left the SDev workspace inside the off-limits directory"
  [ ! -e "$sdev/state/offsets/scdi-$id" ] || fail "no-go: the refusal left the port offset behind"
  [ ! -e "$sdev/state/ledger/scdi-$id" ] || fail "no-go: the refusal left the ledger entry behind"
  for p in multi_api_src multi_ui_src common; do
    git -C "$sdev/core/scdi/$p" worktree list --porcelain 2>/dev/null | grep -Fq "$ws/$p" \
      && fail "no-go: $p's worktree is still registered after the refusal"
  done
  assert_present "$home/state" "no-go: the home state dir should still exist"
  [ ! -e "$home/state/$id.meta" ] || fail "no-go: a refused SDev spawn wrote task metadata"
  [ ! -s "$case_dir/launch.log" ] || fail "no-go: a refused SDev spawn launched a crewmate"
  pass "an SDev workspace inside a no-go path is refused and removed, not archived"
}

# The counterpart that pins the two abort paths apart. Force-removal belongs to
# the no-go refusal alone; an ORDINARY abort in the same armed span must leave
# the workspace, its port offset, and its ledger entry exactly as they were,
# which is what the spawn did before this teardown existed. The abort here is the
# real one: a pre-existing FILE at the per-task temp root makes `mkdir -p
# "$TASK_TMP/gotmp"` fail under set -e, just after the workspace is armed.
test_sdev_ordinary_abort_leaves_the_workspace_offset_and_ledger() {
  local parts case_dir home sdev fakebin id ws code
  parts=$(setup_case ordinary-abort scdi multi-repo.yml)
  IFS='|' read -r case_dir home sdev fakebin <<<"$parts"
  id=task-ordinary-abort
  ws="$sdev/projects/scdi/$id"
  # No config/no-go-paths at all, so nothing about this abort is a refusal.
  printf 'blocking file, not a directory\n' > "/tmp/fm-$id"
  set +e
  FM_FAKE_PANE_PATH="$ws" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    run_spawn "$home" "$sdev" "$fakebin" "$id" projects/scdi >/dev/null 2>"$case_dir/err"
  code=$?
  set -e
  rm -f "/tmp/fm-$id"

  [ "$code" -ne 0 ] || fail "ordinary abort: the fixture did not actually abort the spawn"
  assert_no_grep "is inside the no-go path" "$case_dir/err" \
    "ordinary abort: this case must not be a no-go refusal"
  [ -d "$ws" ] || fail "ordinary abort: a non-refusal abort removed the SDev workspace"
  assert_present "$sdev/state/offsets/scdi-$id" \
    "ordinary abort: a non-refusal abort freed the port offset"
  assert_present "$sdev/state/ledger/scdi-$id" \
    "ordinary abort: a non-refusal abort removed the ledger entry"
  assert_grep 4200 "$sdev/state/offsets/scdi-$id" "ordinary abort: the port offset was rewritten"
  [ ! -s "$case_dir/launch.log" ] || fail "ordinary abort: a crewmate was launched"
  pass "an ordinary abort leaves the SDev workspace, port offset, and ledger entry in place"
}

# M1 regression. Upstream's --relaunch adopts a task's RECORDED worktree and
# launches a replacement agent into it. For an SDev task that recorded worktree
# is the multi-repo workspace, which already exists, so the workspace provider
# must not run again: `sdev new <slug>` against a live slug is not idempotent.
# Detected through sdev's own out-of-workspace state, the same way this file
# tells "left alone" from "force-removed" - the fake rewrites the ledger entry on
# every `new`, so a sentinel that survives proves `new` did not run twice.
test_sdev_relaunch_reuses_the_recorded_workspace() {
  local parts case_dir home sdev fakebin id meta ws
  parts=$(setup_case relaunch scdi multi-repo.yml)
  IFS='|' read -r case_dir home sdev fakebin <<<"$parts"
  id=task-relaunch
  ws="$sdev/projects/scdi/$id"

  FM_FAKE_PANE_PATH="$ws" \
  FM_FAKE_SEND_LOG="$case_dir/send1.log" \
  FM_FAKE_LAUNCH_LOG="$case_dir/launch1.log" \
    run_spawn "$home" "$sdev" "$fakebin" "$id" projects/scdi >/dev/null 2>"$case_dir/err1" \
    || { echo "first spawn failed:"; cat "$case_dir/err1"; fail "relaunch: the initial SDev spawn should succeed"; }

  meta="$home/state/$id.meta"
  assert_eq "$(meta_val "$meta" worktree)" "$ws" "relaunch: the first spawn recorded the workspace"
  printf 'sentinel-not-rewritten\n' > "$sdev/state/ledger/scdi-$id"

  # A relaunch adopts a live endpoint, so the fake must present one: the recorded
  # window in the inventory, and a plain shell as its foreground command so the
  # endpoint reads as positively agent-free.
  FM_FAKE_PANE_PATH="$ws" \
  FM_FAKE_WINDOWS="$(meta_val "$meta" window | cut -d: -f2-)"$'\n' \
  FM_FAKE_PANE_COMMAND=bash \
  FM_FAKE_SEND_LOG="$case_dir/send2.log" \
  FM_FAKE_LAUNCH_LOG="$case_dir/launch2.log" \
    run_spawn_raw "$home" "$sdev" "$fakebin" "$id" --relaunch >/dev/null 2>"$case_dir/err2" \
    || { echo "relaunch failed:"; cat "$case_dir/err2"; fail "relaunch: an SDev task should relaunch into its recorded workspace"; }

  assert_grep sentinel-not-rewritten "$sdev/state/ledger/scdi-$id" \
    "relaunch: \`sdev new\` ran a second time and rewrote the ledger entry"
  assert_eq "$(meta_val "$meta" worktree)" "$ws" "relaunch: the recorded workspace is unchanged"
  assert_eq "$(meta_val "$meta" slug)" "$id" "relaunch: slug= survives the relaunch"
  assert_eq "$(meta_val "$meta" repos)" "api ui common" "relaunch: repos= survives the relaunch"
  assert_grep "$home/data/$id/brief.md" "$case_dir/launch2.log" "relaunch: a replacement agent is launched"
  assert_no_grep "treehouse get" "$case_dir/send2.log" "relaunch: the treehouse path must stay out of an SDev relaunch"
  pass "an SDev relaunch reuses the recorded workspace instead of creating a second one"
}

test_sdev_backed_takes_sdev_path
test_sdev_workspace_repos_are_isolated_worktrees
test_sdev_isolation_failure_aborts
test_sdev_workspace_inside_a_no_go_path_is_refused_and_removed
test_sdev_ordinary_abort_leaves_the_workspace_offset_and_ledger
test_non_sdev_project_uses_treehouse_unchanged
test_sdev_relaunch_reuses_the_recorded_workspace
