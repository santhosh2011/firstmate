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
    out=$(run_spawn "$d" "$id" "${project//@D/$d}" codex)
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
  out=$(run_spawn "$d" nogo-absent-q7 "$d/nogo/proj" codex)
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
  out=$(run_spawn "$d" nogo-msg-q7 "$d/nogo/proj" codex)
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
  out=$(run_spawn "$d" "$id" "$d/nogo/proj" codex)
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
  out=$(run_spawn "$d" "nogo-batch-a-q7=$d/nogo/proj" "nogo-batch-b-q8=$d/allowed")
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
  out=$(run_spawn "$d" "$id" "$d/nogo/home" --secondmate)
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
  out=$(run_spawn "$d" "$id" "$d/allowed/home" --secondmate)
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
    out=$(run_spawn "$d" "nogo-bad$n-q7" "$d/allowed" codex)
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

make_worktree_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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

run_worktree_spawn() {  # <home> <project> <worktree> <fakebin> <id>
  FM_ROOT_OVERRIDE='' FM_HOME="$1" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$3" PATH="$4:$PATH" \
    "$SPAWN" "$5" "$2" 2>&1
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
# not from the fixture.
test_worktree_outside_a_no_go_path_completes() {
  local id home proj wt fakebin out status
  id=nogo-wtok-q8
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_worktree_case worktree-allowed "$id")
EOF
  out=$(run_worktree_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  rm -rf "/tmp/fm-$id"
  expect_code 0 "$status" "an unrestricted spawn must still complete"
  assert_not_contains "$out" "$REFUSAL" "an absent config file refused a worktree"
  assert_grep "worktree=$wt" "$home/state/$id.meta" "the completed spawn did not record its worktree"
  pass "with no config file the same worktree spawns and is recorded as before"
}

test_prefix_matching
test_worktree_inside_a_no_go_path_is_refused
test_worktree_outside_a_no_go_path_completes
test_absent_file_is_unrestricted
test_refusal_names_path_and_prefix
test_refusal_leaves_no_state
test_batch_refuses_only_the_offending_pair
test_secondmate_home_is_checked_before_mutation
test_allowed_secondmate_home_proceeds
test_malformed_line_refuses
