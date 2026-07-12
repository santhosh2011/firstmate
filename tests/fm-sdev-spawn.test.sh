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
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
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

run_spawn() {
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
    env -u SDEV_HOME "$SPAWN" "$id" projects/scdi >/dev/null 2>"$case_dir/err" \
    || { cat "$case_dir/err"; fail "control spawn should succeed"; }

  meta="$home/state/$id.meta"
  assert_grep "treehouse get" "$case_dir/send.log" "control: treehouse get IS sent for a non-SDev project"
  assert_no_grep "sdev_home=" "$meta" "control: no sdev_home in a treehouse task's meta"
  assert_no_grep "slug=" "$meta" "control: no slug in a treehouse task's meta"
  assert_no_grep "repos=" "$meta" "control: no repos in a treehouse task's meta"
  assert_eq "$(meta_val "$meta" worktree)" "$wt" "control: worktree is the treehouse worktree"
  pass "fm-spawn leaves the treehouse path unchanged for a non-SDev project"
}

test_sdev_backed_takes_sdev_path
test_sdev_workspace_repos_are_isolated_worktrees
test_sdev_isolation_failure_aborts
test_non_sdev_project_uses_treehouse_unchanged
