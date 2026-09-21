#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-trust.sh, the codex counterpart of
# bin/fm-claude-trust.sh: pre-registering per-directory codex workspace trust
# for a fresh SDev workspace so a codex spawn does not wedge on codex's own
# first-run "Do you trust the contents of this directory?" dialog.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-codex-trust)

TRUST="$ROOT/bin/fm-codex-trust.sh"

# make_case <name>: an isolated CODEX_HOME plus an SDev workspace holding one
# isolated per-repo git worktree, the structural evidence the scope test
# requires. Echoes "<case-dir>|<codex-home>|<workspace>|<repo-rel>".
make_case() {
  local name=$1 case_dir codex_home src ws
  case_dir="$TMP_ROOT/$name"
  codex_home="$case_dir/codex-home"
  src="$case_dir/src"
  ws="$case_dir/sdev/projects/proj/$name"
  mkdir -p "$codex_home"
  fm_git_init_commit "$src"
  mkdir -p "$ws"
  git -C "$src" worktree add --quiet -b "task-$name" "$ws/repo1" >/dev/null
  printf '%s|%s|%s|%s\n' "$case_dir" "$codex_home" "$ws" "repo1"
}

read_case() {
  IFS='|' read -r CASE_DIR CODEX_HOME WS REPO_REL <<EOF
$1
EOF
}

run_trust() {  # <codex-home> <workspace> [repo-rel ...]
  local codex_home=$1
  shift
  CODEX_HOME="$codex_home" HOME="$codex_home/../user-home" "$TRUST" "$@" 2>&1
}

store_body() {  # <store> <path> -> the non-blank body lines of that table, one per line
  # shellcheck disable=SC2016 # node, not the shell, expands the ${...} template literals below.
  node -e '
    const fs = require("node:fs");
    const [store, target] = process.argv.slice(1);
    const text = fs.existsSync(store) ? fs.readFileSync(store, "utf8") : "";
    const header = `[projects."${target.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"]`;
    const lines = text.split("\n");
    const i = lines.indexOf(header);
    if (i === -1) process.exit(0);
    let j = i + 1;
    while (j < lines.length && lines[j].charAt(0) !== "[") {
      if (lines[j].trim() !== "") console.log(lines[j]);
      j += 1;
    }
  ' "$1" "$2"
}

assert_trusted() {  # <store> <path> <msg>
  local body
  body=$(store_body "$1" "$2")
  [ "$body" = 'trust_level = "trusted"' ] || fail "$3 (body: ${body:-<absent>})"
}

test_fresh_registration() {
  local rec out store
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$CODEX_HOME" "$WS" "$REPO_REL")
  expect_code 0 $? "a fresh SDev workspace must be trusted: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  store="$CODEX_HOME/config.toml"
  assert_trusted "$store" "$WS" "the workspace was not recorded as trusted"
  [ -z "$(find "$CODEX_HOME" -maxdepth 1 -name '.config.toml.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the codex home"
  pass "fm-codex-trust.sh: a fresh SDev workspace is trusted"
}

test_idempotent_rerun() {
  local rec out store count
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$CODEX_HOME" "$WS" "$REPO_REL" >/dev/null
  out=$(run_trust "$CODEX_HOME" "$WS" "$REPO_REL")
  expect_code 0 $? "a repeat registration must succeed: $out"
  assert_contains "$out" "already trusted:" "a repeat registration did not report the entry was already trusted"
  store="$CODEX_HOME/config.toml"
  count=$(grep -Fxc "[projects.\"$WS\"]" "$store")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the table ($count)"
  pass "fm-codex-trust.sh: repeat registration is idempotent"
}

test_unrecognized_shape_is_refused() {
  local rec store before out after
  rec=$(make_case unrecognized)
  read_case "$rec"
  store="$CODEX_HOME/config.toml"
  cat > "$store" <<EOF
[projects."$WS"]
trust_level = "untrusted"

EOF
  before=$(cat "$store")
  out=$(run_trust "$CODEX_HOME" "$WS" "$REPO_REL")
  expect_code 1 $? "an existing entry with an unrecognized shape must be refused: $out"
  assert_contains "$out" "unrecognized shape" "the refusal did not name the unrecognized shape"
  assert_contains "$out" "cd " "the refusal did not print a manual fix command"
  after=$(cat "$store")
  [ "$before" = "$after" ] || fail "the store was modified despite the refusal"
  pass "fm-codex-trust.sh: refuses an existing entry with an unrecognized shape and leaves it untouched"
}

test_multi_key_entry_is_refused() {
  local rec store out
  rec=$(make_case multikey)
  read_case "$rec"
  store="$CODEX_HOME/config.toml"
  cat > "$store" <<EOF
[projects."$WS"]
trust_level = "trusted"
extra_key = "unexpected"

EOF
  out=$(run_trust "$CODEX_HOME" "$WS" "$REPO_REL")
  expect_code 1 $? "an entry carrying an extra key must be refused rather than trusted through: $out"
  assert_contains "$out" "unrecognized shape" "the refusal did not name the unrecognized shape"
  pass "fm-codex-trust.sh: refuses an entry carrying an unexpected extra key"
}

test_unrelated_store_content_is_preserved() {
  local rec store
  rec=$(make_case preserve)
  read_case "$rec"
  store="$CODEX_HOME/config.toml"
  cat > "$store" <<EOF
model = "gpt-6-astra"

[projects."/other/path"]
trust_level = "trusted"

[features]
foo = true
EOF
  run_trust "$CODEX_HOME" "$WS" "$REPO_REL" >/dev/null || fail "registration failed against an existing store"
  assert_trusted "$store" "$WS" "the workspace was not recorded in an existing store"
  assert_grep 'model = "gpt-6-astra"' "$store" "an unrelated top-level key was lost"
  assert_trusted "$store" "/other/path" "another project's trust entry was disturbed"
  assert_grep '[features]' "$store" "an unrelated table was lost"
  assert_grep 'foo = true' "$store" "an unrelated table's content was lost"
  pass "fm-codex-trust.sh: preserves unrelated store content"
}

test_non_isolated_repo_path_is_refused() {
  local rec out plain
  rec=$(make_case notiso)
  read_case "$rec"
  plain="$WS/plain"
  mkdir -p "$plain"
  out=$(run_trust "$CODEX_HOME" "$WS" plain)
  expect_code 1 $? "a repo path that is not a git worktree must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  [ ! -f "$CODEX_HOME/config.toml" ] || assert_no_grep "$WS" "$CODEX_HOME/config.toml" \
    "the workspace was trusted despite a failed isolation check"
  pass "fm-codex-trust.sh: refuses a workspace whose named repo path is not an isolated git worktree"
}

test_missing_workspace_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$CODEX_HOME" "$CASE_DIR/nope" "$REPO_REL")
  expect_code 1 $? "a nonexistent workspace must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the inaccessible path"
  pass "fm-codex-trust.sh: refuses a workspace path that does not exist"
}

test_missing_repo_arg_is_a_usage_error() {
  local rec out
  rec=$(make_case usage)
  read_case "$rec"
  out=$(run_trust "$CODEX_HOME" "$WS")
  expect_code 2 $? "no repo path at all must be a usage error: $out"
  pass "fm-codex-trust.sh: refuses to run with no repo path named"
}

test_prune_removes_only_missing_paths() {
  local rec store out
  rec=$(make_case prune)
  read_case "$rec"
  run_trust "$CODEX_HOME" "$WS" "$REPO_REL" >/dev/null
  store="$CODEX_HOME/config.toml"
  cat >> "$store" <<EOF

[projects."$CASE_DIR/gone"]
trust_level = "trusted"
EOF
  out=$(CODEX_HOME="$CODEX_HOME" "$TRUST" --prune 2>&1)
  expect_code 0 $? "prune must succeed: $out"
  assert_contains "$out" "$CASE_DIR/gone" "prune did not report the stale entry it removed"
  assert_trusted "$store" "$WS" "prune removed a still-existing workspace's trust"
  [ -z "$(store_body "$store" "$CASE_DIR/gone")" ] || fail "the stale entry was not actually removed from the store"
  pass "fm-codex-trust.sh: --prune removes only entries whose path no longer exists"
}

test_fresh_registration
test_idempotent_rerun
test_unrecognized_shape_is_refused
test_multi_key_entry_is_refused
test_unrelated_store_content_is_preserved
test_non_isolated_repo_path_is_refused
test_missing_workspace_is_refused
test_missing_repo_arg_is_a_usage_error
test_prune_removes_only_missing_paths
