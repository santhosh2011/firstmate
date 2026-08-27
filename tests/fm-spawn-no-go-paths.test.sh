#!/usr/bin/env bash
# Behavior tests for the no-go path guard (bin/fm-no-go-lib.sh) as enforced by
# bin/fm-spawn.sh.
#
# Every case drives the real fm-spawn.sh. A refused spawn exits at the project or
# secondmate-home check, and an ALLOWED spawn falls through to the existing
# missing-brief error, so no case creates a window, a worktree, or task state.
# "not refused" is therefore asserted by contrast: the run must fail with the
# brief error and must NOT mention a no-go path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-no-go-paths)
export FM_BACKEND=tmux

REFUSAL='is inside the no-go path'

# A firstmate home with an empty config/, plus the no-go root and a project dir
# inside it. Echoes the PHYSICAL case dir (TMPDIR can carry a trailing slash and
# a /var -> /private/var symlink, and the assertions compare exact strings against
# paths fm-spawn itself resolved). Layout is <case>/home, <case>/nogo/proj,
# <case>/allowed.
new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/data" "$d/home/state" "$d/home/config" \
    "$d/nogo/proj" "$d/allowed"
  (CDPATH='' cd -- "$d" && pwd -P)
}

# Run fm-spawn with ambient firstmate overrides cleared so each case owns its
# environment, and with HOME pinned to the case dir so ~ expansion is testable
# without touching the real home.
run_spawn() {  # <case-dir> <args...>
  local d=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$d/home" \
    HOME="$d/home" \
    "$SPAWN" "$@" 2>&1
}

write_config() {  # <case-dir> <line...>
  local d=$1
  shift
  printf '%s\n' "$@" > "$d/home/config/no-go-paths"
}

# --- the prefix-matching matrix ---------------------------------------------
#
# One row per rule from the config contract. Each row writes a single-line (or
# multi-line, via the literal \n marker) config, then spawns against a project
# path and asserts refused or allowed. Rows use @D as the case-dir placeholder
# so the table stays readable.
#
#   <label>|<verdict>|<config lines>|<project path>
test_prefix_matching() {
  local label verdict config project d out status id n=0
  while IFS='|' read -r label verdict config project; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="nogo-m$n-q7"
    d=$(new_case "match-$n")
    mkdir -p "$d/nogo/proj" "$d/nogo-sibling" "$d/home/blocked/deep/deeper"
    # shellcheck disable=SC2059  # the table supplies the \n separators on purpose
    printf "${config//@D/$d}\n" > "$d/home/config/no-go-paths"
    out=$(run_spawn "$d" "$id" "${project//@D/$d}" codex --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: spawn should never succeed in this suite"
    case "$verdict" in
      refused)
        printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null \
          || fail "$label: expected a no-go refusal, got: $out"
        printf '%s\n' "$out" | grep -F "no brief at" >/dev/null \
          && fail "$label: refusal must precede the brief check"
        ;;
      allowed)
        printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null \
          && fail "$label: must not be refused, got: $out"
        printf '%s\n' "$out" | grep -F "no brief at" >/dev/null \
          || fail "$label: expected the normal missing-brief failure, got: $out"
        ;;
    esac
  done <<'ROWS'
exact match is refused|refused|@D/nogo|@D/nogo
nested path is refused|refused|@D/nogo|@D/nogo/proj
sibling prefix /a/bc is not refused|allowed|@D/nogo|@D/nogo-sibling
trailing slash is tolerated|refused|@D/nogo/|@D/nogo/proj
comments and blanks are ignored|refused|# a comment\n\n   \n@D/nogo|@D/nogo/proj
a comment-only file restricts nothing|allowed|# only a comment\n|@D/nogo/proj
bare ~ expands to HOME|refused|~|@D/home/blocked
~/ expands to HOME|refused|~/blocked|@D/home/blocked/deep/deeper
an unrelated prefix does not refuse|allowed|@D/nogo|@D/allowed
a later line still matches|refused|@D/never-used\n@D/nogo|@D/nogo/proj
ROWS
  pass "prefix matching: exact, nested, sibling boundary, trailing slash, comments, blanks, ~ expansion"
}

# --- the absent file must change nothing ------------------------------------

test_absent_file_is_unrestricted() {
  local d out status
  d=$(new_case absent)
  [ ! -e "$d/home/config/no-go-paths" ] || fail "fixture wrote a config file"
  out=$(run_spawn "$d" nogo-absent-q7 "$d/nogo/proj" codex --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with a missing brief should still fail"
  printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null \
    && fail "an absent config file must not restrict anything"
  printf '%s\n' "$out" | grep -F "no brief at $d/home/data/nogo-absent-q7/brief.md" >/dev/null \
    || fail "absent config changed the existing failure path: $out"
  pass "an absent config/no-go-paths leaves dispatch behavior unchanged"
}

# --- the refusal message names both paths -----------------------------------

test_refusal_names_path_and_prefix() {
  local d out
  d=$(new_case message)
  write_config "$d" "$d/nogo"
  out=$(run_spawn "$d" nogo-msg-q7 "$d/nogo/proj" codex --mode no-mistakes --yolo off)
  printf '%s\n' "$out" | grep -F "$d/nogo/proj" >/dev/null \
    || fail "refusal did not name the offending path: $out"
  printf '%s\n' "$out" | grep -F "'$d/nogo'" >/dev/null \
    || fail "refusal did not name the matching prefix: $out"
  printf '%s\n' "$out" | grep -F 'config/no-go-paths' >/dev/null \
    || fail "refusal did not name the config file: $out"
  pass "a refusal names the offending path, the matching prefix, and the config file"
}

# --- a refused spawn leaves nothing behind ----------------------------------

test_refusal_leaves_no_state() {
  local d id out leftovers
  d=$(new_case leftovers)
  id=nogo-clean-q7
  write_config "$d" "$d/nogo"
  out=$(run_spawn "$d" "$id" "$d/nogo/proj" codex --mode no-mistakes --yolo off)
  printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null || fail "fixture did not refuse: $out"
  [ ! -e "$d/home/state/$id.meta" ] || fail "a refused spawn wrote task metadata"
  [ ! -e "$d/home/state/$id.status" ] || fail "a refused spawn wrote a task status file"
  leftovers=$(find "$d/home/state" -name "*$id*" 2>/dev/null || true)
  [ -z "$leftovers" ] || fail "a refused spawn left task state behind: $leftovers"
  [ ! -e "/tmp/fm-$id" ] || fail "a refused spawn created the per-task temp root"
  pass "a refused spawn leaves no task state, metadata, lock, or temp root behind"
}

# --- batch dispatch keeps its contract --------------------------------------

test_batch_refuses_only_the_offending_pair() {
  local d out status
  d=$(new_case batch)
  write_config "$d" "$d/nogo"
  # --harness pins the adapter for both pairs: an unpinned spawn resolves the
  # harness (and aborts on one with no launch template) before it reaches the
  # no-go check, so ambient detection - claude under an agent, unknown on a CI
  # runner - would decide this case instead of the guard.
  out=$(run_spawn "$d" --harness codex \
    "nogo-batch-a-q7=$d/nogo/proj" "nogo-batch-b-q8=$d/allowed" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a batch containing a refused pair must exit non-zero"
  printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null \
    || fail "the no-go pair was not refused: $out"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nogo-batch-a-q7' >/dev/null \
    || fail "the refused pair was not reported by the batch loop: $out"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nogo-batch-b-q8' >/dev/null \
    || fail "a refused pair stopped the rest of the batch: $out"
  printf '%s\n' "$out" | grep -F "no brief at $d/home/data/nogo-batch-b-q8/brief.md" >/dev/null \
    || fail "the allowed pair was not dispatched past the no-go check: $out"
  pass "a refused pair is reported and skipped while the rest of the batch still dispatches"
}

# --- a secondmate home gets the same check ----------------------------------

# A seeded secondmate home is the minimum validate_firstmate_home_for_spawn
# accepts: the seed marker naming the id, AGENTS.md, and bin/. The charter is
# deliberately omitted so an ALLOWED home still stops at the missing-brief error
# instead of reaching a backend and launching a real agent - this suite must
# never create a window.
seed_secondmate_home() {  # <home> <id>
  mkdir -p "$1/bin" "$1/data"
  printf '# Firstmate\n' > "$1/AGENTS.md"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
}

test_secondmate_home_is_checked_before_mutation() {
  local d id out status
  d=$(new_case secondmate)
  id=nogo-sm-q7
  seed_secondmate_home "$d/nogo/home" "$id"
  write_config "$d" "$d/nogo"
  out=$(run_spawn "$d" "$id" "$d/nogo/home" --harness codex --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate launch into a no-go path must fail"
  printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null \
    || fail "the secondmate home was not checked: $out"
  printf '%s\n' "$out" | grep -F 'secondmate home' >/dev/null \
    || fail "the refusal did not label the path as a secondmate home: $out"
  [ ! -e "$d/nogo/home/state" ] \
    || fail "the refusal ran after the secondmate state directory was created"
  [ ! -e "$d/nogo/home/config" ] \
    || fail "the refusal ran after inheritance propagation"
  [ ! -e "$d/home/state/$id.meta" ] || fail "a refused secondmate launch wrote task metadata"
  pass "a secondmate home inside a no-go path is refused before the home is mutated"
}

# An allowed secondmate home must still be checked and still proceed, so the
# guard cannot be passing simply by refusing every secondmate launch. Proceeding
# is proven by the home's own state directory, which fm-spawn creates only after
# the no-go check clears; the run then stops at the missing charter/brief, well
# before any backend call.
test_allowed_secondmate_home_proceeds() {
  local d id out status
  d=$(new_case secondmate-ok)
  id=nogo-smok-q7
  seed_secondmate_home "$d/allowed/home" "$id"
  write_config "$d" "$d/nogo"
  out=$(run_spawn "$d" "$id" "$d/allowed/home" --harness codex --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "the fixture omits the charter, so this run must still fail"
  printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null \
    && fail "a secondmate home outside every no-go path must not be refused: $out"
  [ -e "$d/allowed/home/state" ] \
    || fail "an allowed secondmate launch did not proceed past the no-go check: $out"
  printf '%s\n' "$out" | grep -F 'no brief at' >/dev/null \
    || fail "the allowed run did not stop at the brief check as expected: $out"
  [ ! -e "/tmp/fm-$id" ] || fail "the allowed run reached backend setup and made a temp root"
  pass "a secondmate home outside every declared prefix passes the check and proceeds"
}

# --- malformed configuration is an error, not a skipped line ----------------

test_malformed_line_refuses() {
  local label config d out status n=0
  while IFS='|' read -r label config; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    d=$(new_case "malformed-$n")
    # shellcheck disable=SC2059  # the table supplies the \n separators on purpose
    printf "${config//@D/$d}\n" > "$d/home/config/no-go-paths"
    out=$(run_spawn "$d" "nogo-bad$n-q7" "$d/allowed" codex --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: malformed config must not spawn"
    printf '%s\n' "$out" | grep -F 'is not an absolute path prefix' >/dev/null \
      || fail "$label: expected a malformed-config error, got: $out"
    printf '%s\n' "$out" | grep -F 'no-go-paths line' >/dev/null \
      || fail "$label: the error did not name the offending line number: $out"
  done <<'ROWS'
a relative line is rejected|relative/path
a bare word is rejected|nogo
a relative line after a valid one is rejected|@D/nogo\nstill-relative
ROWS
  pass "a malformed line refuses the spawn and names its line number"
}

# --- the final worktree gets the same check ---------------------------------
#
# The worktree check is the one refusal point that cannot run before the backend
# window exists, so reaching it needs a full spawn. A fake tmux plus a fake
# treehouse (the harness tests/fm-spawn-worktree-settle.test.sh established)
# drives it against a real git worktree without touching a real terminal: the
# fake pane reports FM_FAKE_PANE_PATH as the settled worktree.

# The tmux stub records every invocation when FM_FAKE_TMUX_LOG is set, so a case
# can assert which window fm-spawn asked the backend to close.
#
# The treehouse stub models the real tool's two verbs FAITHFULLY, because the
# difference between them is exactly what these cases are testing. `return` is a
# POOL RETURN: the real command hands the slot back and the directory stays
# exactly where it is, so the fake leaves it in place and drops a marker. Only
# `destroy` removes. A fake that removed on `return` would let an assertion pass
# against production behavior that never happens.
make_worktree_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
verb=${1:-}
shift || true
target=
for arg in "$@"; do
  case "$arg" in
    --*) ;;
    *) [ -n "$target" ] || target=$arg ;;
  esac
done
case "$verb" in
  return)
    [ -n "$target" ] && [ -d "$target" ] || exit 1
    : > "$target/.fake-returned-to-pool"
    ;;
  destroy)
    [ -n "$target" ] || exit 1
    git worktree remove --force "$target" >/dev/null 2>&1 || exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# A case whose PROJECT sits outside every declared prefix while its WORKTREE
# lands inside one - the pool-root-inside-a-no-go-path shape. Echoes
# "<home>|<project>|<worktree>|<fakebin>".
make_worktree_case() {  # <name> <id>
  local d home proj wt fakebin
  d=$(new_case "$1")
  home="$d/home"
  proj="$d/allowed/project"
  wt="$d/nogo/pool/wt-$2"
  fakebin=$(make_worktree_fakebin "$d/fake")
  mkdir -p "$home/projects" "$home/data/$2" "$d/nogo/pool"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$2" > "$home/data/$2/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$2"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_worktree_spawn() {  # <home> <project> <worktree> <fakebin> <id> [tmux-log]
  FM_ROOT_OVERRIDE='' FM_HOME="$1" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="${6:-}" \
    FM_FAKE_PANE_PATH="$3" PATH="$4:$PATH" \
    "$SPAWN" "$5" "$2" --mode no-mistakes --yolo off 2>&1
}

test_worktree_inside_a_no_go_path_is_refused() {
  local id home proj wt fakebin out status
  id=nogo-wt-q7
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_worktree_case worktree-refused "$id")
EOF
  printf '%s\n' "$(dirname "$wt")" > "$home/config/no-go-paths"
  out=$(run_worktree_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  rm -rf "/tmp/fm-$id"
  [ "$status" -ne 0 ] || fail "a worktree inside a no-go path must refuse: $out"
  assert_contains "$out" "$REFUSAL" "the resolved worktree was not checked"
  assert_contains "$out" "task worktree" "the refusal did not label the path as the task worktree"
  assert_absent "$home/state/$id.meta" "the worktree refusal ran after metadata was written"
  pass "a task worktree inside a no-go path is refused before metadata is written"
}

# The control: identical fixture, no config file. The spawn must complete and
# record that same worktree, proving the refusal above comes from the guard and
# not from the fixture. It doubles as the disarm control for the teardown below -
# a completed spawn owns its worktree and window, so the EXIT trap must leave
# both alone.
test_worktree_outside_a_no_go_path_completes() {
  local id home proj wt fakebin out status log
  id=nogo-wtok-q8
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_worktree_case worktree-allowed "$id")
EOF
  log="$home/tmux.log"
  out=$(run_worktree_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log")
  status=$?
  rm -rf "/tmp/fm-$id"
  expect_code 0 "$status" "an unrestricted spawn must still complete"
  assert_not_contains "$out" "$REFUSAL" "an absent config file refused a worktree"
  assert_grep "worktree=$wt" "$home/state/$id.meta" "the completed spawn did not record its worktree"
  [ -d "$wt" ] || fail "a completed spawn removed its own worktree: $out"
  grep -F 'kill-window' "$log" >/dev/null \
    && fail "a completed spawn closed its own window"
  pass "with no config file the same worktree spawns, is recorded, and is left in place"
}

# The refusal must not stop at "do not launch": the worktree it refuses sits
# INSIDE the operator's off-limits directory, so the invocation has to unwind the
# worktree and the window it opened. Returning it to the pool would not do -
# the pool is inside that prefix too - so this asserts the directory is GONE,
# which only `treehouse destroy` produces in the faithful fake above.
test_worktree_refusal_unwinds_the_worktree_and_window() {
  local id home proj wt fakebin out status log kill_line
  id=nogo-wtclean-q9
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_worktree_case worktree-unwound "$id")
EOF
  log="$home/tmux.log"
  [ -d "$wt" ] || fail "fixture did not create the worktree"
  printf '%s\n' "$(dirname "$wt")" > "$home/config/no-go-paths"
  out=$(run_worktree_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log")
  status=$?
  rm -rf "/tmp/fm-$id"
  [ "$status" -ne 0 ] || fail "a worktree inside a no-go path must refuse: $out"
  assert_contains "$out" "$REFUSAL" "the resolved worktree was not checked"
  assert_absent "$wt" "the refusal left its worktree inside the no-go path"
  assert_absent "$wt/.fake-returned-to-pool" \
    "the refusal recycled the worktree into the pool instead of destroying it"
  kill_line=$(grep -F 'kill-window' "$log" || true)
  [ -n "$kill_line" ] || fail "the refusal did not close the window it opened"
  printf '%s\n' "$kill_line" | grep -F "fm-$id" >/dev/null \
    || fail "the refusal closed a window other than its own: $kill_line"
  assert_absent "$home/state/$id.meta" "the worktree refusal wrote metadata"
  pass "a worktree refusal removes the worktree and closes the window it created"
}

# The other half of that unwind, and the one that matters most: the refusal must
# NOT remove a worktree whose safety it cannot establish. An untracked file makes
# `git status` report content, so cleanliness is disproved and the abort has to
# warn and leave the directory - including the file - exactly where it is.
test_refusal_leaves_an_unproven_worktree_in_place() {
  local id home proj wt fakebin out status
  id=nogo-wtdirty-q9
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_worktree_case worktree-dirty "$id")
EOF
  printf 'work in progress\n' > "$wt/uncommitted.txt"
  printf '%s\n' "$(dirname "$wt")" > "$home/config/no-go-paths"
  out=$(run_worktree_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  rm -rf "/tmp/fm-$id"
  [ "$status" -ne 0 ] || fail "a worktree inside a no-go path must refuse: $out"
  assert_contains "$out" "$REFUSAL" "the resolved worktree was not checked"
  [ -d "$wt" ] || fail "the refusal removed a worktree it could not prove was clean: $out"
  [ -f "$wt/uncommitted.txt" ] || fail "the refusal discarded uncommitted work: $out"
  assert_contains "$out" "leaving worktree $wt in place" \
    "the refusal did not warn that it left the worktree behind"
  assert_contains "$out" "uncommitted or untracked changes" \
    "the warning did not name why the worktree could not be removed"
  pass "a refusal warns and leaves a worktree whose cleanliness it cannot establish"
}

# The same conservative branch reached through the OTHER unprovable input, and
# the one that actually regressed: a worktree whose `git status` cannot run.
# A corrupt index leaves `rev-parse` answering normally while `status` exits
# non-zero with EMPTY stdout - the exact shape that a bare emptiness test reads
# as "clean" and hands to a forced, hard-resetting return.
test_refusal_leaves_a_worktree_whose_status_cannot_be_read() {
  local id home proj wt fakebin out status gitdir
  id=nogo-wtunread-q9
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_worktree_case worktree-unreadable "$id")
EOF
  printf '%s\n' "$(dirname "$wt")" > "$home/config/no-go-paths"
  gitdir=$(git -C "$wt" rev-parse --absolute-git-dir) || fail "fixture worktree has no git dir"
  printf 'not a git index\n' > "$gitdir/index"
  git -C "$wt" status --porcelain >/dev/null 2>&1 \
    && fail "fixture did not actually break git status"
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] \
    || fail "fixture's broken git status still prints to stdout, so it proves nothing"

  out=$(run_worktree_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  rm -rf "/tmp/fm-$id"
  [ "$status" -ne 0 ] || fail "a worktree inside a no-go path must refuse: $out"
  assert_contains "$out" "$REFUSAL" "the resolved worktree was not checked"
  [ -d "$wt" ] || fail "the refusal removed a worktree whose status it never read: $out"
  assert_contains "$out" "leaving worktree $wt in place" \
    "the refusal did not warn that it left the worktree behind"
  assert_contains "$out" "cleanliness was never established" \
    "the warning did not name the unreadable status as the reason"
  pass "a refusal warns and leaves a worktree whose git status could not be read"
}

# --- a present but unusable config file fails closed -------------------------
#
# Absence is the ONLY unrestricted state. A config/no-go-paths that exists in any
# other form is a boundary the operator declared and fm-spawn cannot read, so it
# refuses instead of reading it as "no restriction". Every case dispatches at
# @D/allowed, which no prefix could match, so the refusal can only come from the
# unreadable file itself.
test_unreadable_config_refuses() {
  local d out status n=0 label
  for label in directory dangling-symlink symlink-to-directory unreadable-file; do
    n=$((n + 1))
    d=$(new_case "unreadable-$n")
    case "$label" in
      directory) mkdir -p "$d/home/config/no-go-paths" ;;
      dangling-symlink) ln -s "$d/gone/no-go-paths" "$d/home/config/no-go-paths" ;;
      symlink-to-directory) ln -s "$d/nogo" "$d/home/config/no-go-paths" ;;
      unreadable-file)
        [ "$(id -u)" != 0 ] || continue
        printf '%s\n' "$d/nogo" > "$d/home/config/no-go-paths"
        chmod 000 "$d/home/config/no-go-paths"
        ;;
    esac
    out=$(run_spawn "$d" "nogo-unread$n-q7" "$d/allowed" codex --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: an unreadable config must not spawn"
    printf '%s\n' "$out" | grep -F 'the declared no-go paths cannot be read' >/dev/null \
      || fail "$label: expected an unreadable-config refusal, got: $out"
    printf '%s\n' "$out" | grep -F "$d/home/config/no-go-paths" >/dev/null \
      || fail "$label: the refusal did not name the config path: $out"
    printf '%s\n' "$out" | grep -F 'no brief at' >/dev/null \
      && fail "$label: the refusal must precede the brief check"
  done
  pass "a config/no-go-paths that exists but is not a readable regular file refuses"
}

# A symlink INTO a readable regular file is the working dotfiles case and must
# keep restricting normally - the fail-closed rule above is about unusable files,
# not about symlinks.
test_symlinked_config_still_restricts() {
  local d out status
  d=$(new_case symlinked)
  printf '%s\n' "$d/nogo" > "$d/dotfiles-no-go-paths"
  ln -s "$d/dotfiles-no-go-paths" "$d/home/config/no-go-paths"
  out=$(run_spawn "$d" nogo-symlink-q7 "$d/nogo/proj" codex --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a symlinked config must still refuse a matching path"
  printf '%s\n' "$out" | grep -F "$REFUSAL" >/dev/null \
    || fail "a config symlinked to a readable regular file stopped restricting: $out"
  pass "a config symlinked to a readable regular file restricts exactly as a plain file does"
}

# --- fm_no_go_assert's three-way status contract ----------------------------
#
# fm_no_go_match reports three distinct states (inside a prefix, allowed,
# unusable config) and fm_no_go_assert collapses them to the two its callers act
# on. Drive the library directly so all three inputs are covered, including the
# unusable-config state that must NOT be mistaken for "allowed".
test_assert_status_contract() {
  local d err status
  d=$(new_case assert-contract)
  err="$d/assert.err"
  # shellcheck source=bin/fm-no-go-lib.sh
  . "$ROOT/bin/fm-no-go-lib.sh"

  status=0
  fm_no_go_assert "project directory" "$d/allowed" "$d/home/config" 2>"$err" || status=$?
  expect_code 0 "$status" "an absent config must allow"
  [ ! -s "$err" ] || fail "an allowed path wrote to stderr: $(cat "$err")"

  printf '%s\n' "$d/nogo" > "$d/home/config/no-go-paths"
  status=0
  fm_no_go_assert "project directory" "$d/allowed" "$d/home/config" 2>"$err" || status=$?
  expect_code 0 "$status" "a path outside every prefix must allow"
  [ ! -s "$err" ] || fail "an allowed path wrote to stderr: $(cat "$err")"

  status=0
  fm_no_go_assert "project directory" "$d/nogo/proj" "$d/home/config" 2>"$err" || status=$?
  expect_code 1 "$status" "a path inside a prefix must refuse"
  assert_contains "$(cat "$err")" "project directory" "the refusal dropped the label"
  assert_contains "$(cat "$err")" "$d/nogo/proj" "the refusal dropped the offending path"
  assert_contains "$(cat "$err")" "'$d/nogo'" "the refusal dropped the matching prefix"
  assert_contains "$(cat "$err")" "config/no-go-paths" "the refusal dropped the config file"

  printf 'not-absolute\n' > "$d/home/config/no-go-paths"
  status=0
  fm_no_go_assert "project directory" "$d/allowed" "$d/home/config" 2>"$err" || status=$?
  expect_code 1 "$status" "a malformed config must refuse an otherwise allowed path"

  rm -f "$d/home/config/no-go-paths"
  mkdir -p "$d/home/config/no-go-paths"
  status=0
  fm_no_go_assert "project directory" "$d/allowed" "$d/home/config" 2>"$err" || status=$?
  expect_code 1 "$status" "an unusable config must refuse an otherwise allowed path"
  pass "fm_no_go_assert allows only a genuinely allowed path and refuses both refusal states"
}

# --- absence must be provable, not merely unobserved -------------------------
#
# The shell's existence tests answer "no" both when an entry is not there and
# when it could not be looked up. Reading the second as the first is what turns
# an unsearchable config/ into "no restriction declared". The dispatch below
# targets @D/allowed, which no prefix could match, so a refusal can only come
# from the undeterminable config state itself.
test_unsearchable_config_dir_refuses() {
  local d out status
  if [ "$(id -u)" = 0 ]; then
    pass "config-dir searchability (skipped: root searches every directory)"
    return 0
  fi
  d=$(new_case unsearchable-config)
  printf '%s\n' "$d/nogo" > "$d/home/config/no-go-paths"
  chmod 000 "$d/home/config"
  out=$(run_spawn "$d" nogo-unsearch-q7 "$d/allowed" codex --mode no-mistakes --yolo off)
  status=$?
  chmod 700 "$d/home/config"
  [ "$status" -ne 0 ] || fail "an unsearchable config dir must not silently allow a dispatch: $out"
  printf '%s\n' "$out" | grep -F 'could not be classified' >/dev/null \
    || fail "the refusal did not report an undeterminable config state: $out"
  printf '%s\n' "$out" | grep -F 'is not searchable' >/dev/null \
    || fail "the refusal did not name the unsearchable directory as the reason: $out"
  printf '%s\n' "$out" | grep -F 'no brief at' >/dev/null \
    && fail "the refusal must precede the brief check"
  pass "a config/ directory that cannot be searched refuses instead of reading as unrestricted"
}

# --- the shared tri-state classifier ----------------------------------------
#
# One owner for the EXISTS / PROVABLY ABSENT / UNDETERMINABLE question, driven
# against real filesystem states.
test_path_state_contract() {
  local d state
  d=$(new_case path-state)
  # shellcheck source=bin/fm-path-state-lib.sh
  . "$ROOT/bin/fm-path-state-lib.sh"

  state=0; fm_path_state "$d/allowed" || state=$?
  expect_code "$FM_PATH_STATE_EXISTS" "$state" "an existing directory must classify as EXISTS"

  printf 'x\n' > "$d/allowed/file"
  state=0; fm_path_state "$d/allowed/file" || state=$?
  expect_code "$FM_PATH_STATE_EXISTS" "$state" "an existing file must classify as EXISTS"

  ln -s "$d/gone" "$d/allowed/dangling"
  state=0; fm_path_state "$d/allowed/dangling" || state=$?
  expect_code "$FM_PATH_STATE_EXISTS" "$state" "a dangling symlink is present, not absent"

  state=0; fm_path_state "$d/allowed/missing" || state=$?
  expect_code "$FM_PATH_STATE_ABSENT" "$state" "a missing entry under a searchable dir must be PROVABLY ABSENT"
  [ -z "$FM_PATH_STATE_REASON" ] || fail "a provable absence must not carry a reason"

  state=0; fm_path_state "$d/no/such/chain/entry" || state=$?
  expect_code "$FM_PATH_STATE_ABSENT" "$state" "a genuinely missing ancestor chain is still PROVABLY ABSENT"

  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$d/allowed"
    state=0; fm_path_state "$d/allowed/file" || state=$?
    chmod 700 "$d/allowed"
    expect_code "$FM_PATH_STATE_UNDETERMINABLE" "$state" \
      "an entry under an unsearchable dir must be UNDETERMINABLE, never absent"

    chmod 000 "$d/allowed"
    state=0; fm_path_state "$d/allowed/missing" || state=$?
    chmod 700 "$d/allowed"
    expect_code "$FM_PATH_STATE_UNDETERMINABLE" "$state" \
      "a lookup that could not happen must be UNDETERMINABLE, never absent"

    chmod 000 "$d/allowed"
    state=0; fm_path_state "$d/allowed/deeper/entry" || state=$?
    chmod 700 "$d/allowed"
    expect_code "$FM_PATH_STATE_UNDETERMINABLE" "$state" \
      "an unsearchable ancestor must make the whole chain UNDETERMINABLE"
  fi

  state=0; fm_path_state "" || state=$?
  expect_code "$FM_PATH_STATE_UNDETERMINABLE" "$state" "an empty path must be UNDETERMINABLE"
  pass "fm_path_state separates EXISTS, provable absence, and an undeterminable lookup"
}

test_prefix_matching
test_path_state_contract
test_unsearchable_config_dir_refuses
test_worktree_inside_a_no_go_path_is_refused
test_worktree_refusal_unwinds_the_worktree_and_window
test_refusal_leaves_an_unproven_worktree_in_place
test_refusal_leaves_a_worktree_whose_status_cannot_be_read
test_worktree_outside_a_no_go_path_completes
test_unreadable_config_refuses
test_symlinked_config_still_restricts
test_assert_status_contract
test_absent_file_is_unrestricted
test_refusal_names_path_and_prefix
test_refusal_leaves_no_state
test_batch_refuses_only_the_offending_pair
test_secondmate_home_is_checked_before_mutation
test_allowed_secondmate_home_proceeds
test_malformed_line_refuses
