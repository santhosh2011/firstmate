#!/usr/bin/env bash
# Tests for bin/fm-sdev-registry.sh: read an SDev project's repo composition from
# $SDEV_HOME/core/projects.d/<name>.yml and answer "is this project SDev-backed?".
#
# The reader is inert by default: with SDEV_HOME unset (and no config/sdev-home)
# or with no registry entry, it reports "not SDev-backed" via a non-zero exit and
# stays silent - no error spew - so firstmate's existing behavior is unchanged
# until a fleet opts in.
#
# Matrix:
#   repos    multi-repo (N>1) / monorepo (N=1) / local-only (remote-agnostic parse)
#   backed   existing entry -> 0; missing entry / unset / nonexistent home -> not-backed
#   home     resolved from SDEV_HOME env, then config/sdev-home file; env wins
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGISTRY="$ROOT/bin/fm-sdev-registry.sh"
FIXTURES="$ROOT/tests/fixtures/sdev"
TMP_ROOT=$(fm_test_tmproot fm-sdev-registry-tests)

# The exit code the reader uses for the inert "not SDev-backed" case.
NOT_BACKED=3

assert_eq() {
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- expected ---"$'\n'"$2"$'\n'"--- actual ---"$'\n'"$1"
}

line_count() { printf '%s' "$1" | grep -c '' ; }

# make_sdev_home <case> <project> <fixture>: build an SDEV_HOME containing one
# registry file <project>.yml copied from the named fixture, echo its path.
make_sdev_home() {
  local project=$2 fixture=$3 home="$TMP_ROOT/$1-home"
  mkdir -p "$home/core/projects.d"
  cp "$FIXTURES/$fixture" "$home/core/projects.d/$project.yml"
  printf '%s\n' "$home"
}

# make_config <case>: build an empty config dir (no sdev-home file), echo its path.
make_config() {
  local dir="$TMP_ROOT/$1-config"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

run_registry() {
  local home=$1 cfg=$2
  shift 2
  SDEV_HOME="$home" FM_CONFIG_OVERRIDE="$cfg" FM_ROOT_OVERRIDE="$ROOT" \
    "$REGISTRY" "$@"
}

test_multirepo_parse() {
  local home cfg out
  home=$(make_sdev_home multi scdi multi-repo.yml)
  cfg=$(make_config multi)
  out=$(run_registry "$home" "$cfg" repos scdi)

  assert_eq "$(line_count "$out")" 3 "multi-repo: expected 3 repo lines"
  assert_eq "$out" \
    "$(printf 'api\tmulti_api_src\tdevelop\tapi\nui\tmulti_ui_src\tdevelop\tui\ncommon\tcommon\tmain\tcommon')" \
    "multi-repo: repo list must be key<TAB>path<TAB>default_base<TAB>compose_role in document order"
  pass "fm-sdev-registry emits every repo of a multi-repo project as TSV"
}

test_monorepo_parse() {
  local home cfg out
  home=$(make_sdev_home mono chips-app monorepo.yml)
  cfg=$(make_config mono)
  out=$(run_registry "$home" "$cfg" repos chips-app)

  assert_eq "$(line_count "$out")" 1 "monorepo: expected exactly 1 repo line"
  assert_eq "$out" "$(printf 'chips\tedm-apps-mono-chips-ui\tdevelop\tapp')" \
    "monorepo: single repo where key, path, and compose_role all differ"
  pass "fm-sdev-registry handles a monorepo as the N=1 case"
}

test_localonly_parse() {
  local home cfg out
  home=$(make_sdev_home localonly spnr local-only.yml)
  cfg=$(make_config localonly)
  out=$(run_registry "$home" "$cfg" repos spnr)

  assert_eq "$(line_count "$out")" 2 "local-only: expected 2 repo lines"
  assert_eq "$out" \
    "$(printf 'api\tlocalonly-api\tdevelop\tapi\nui\tlocalonly-ui\tdevelop\tui')" \
    "local-only: reader is remote-agnostic and emits repos regardless of origin"
  pass "fm-sdev-registry parses a local-only project the same as any other"
}

test_backed_true() {
  local home cfg
  home=$(make_sdev_home backed scdi multi-repo.yml)
  cfg=$(make_config backed)
  run_registry "$home" "$cfg" backed scdi
  expect_code 0 $? "backed: an existing registry entry reports SDev-backed"
  pass "fm-sdev-registry backed exits 0 for a project with a registry entry"
}

test_not_backed_missing_entry() {
  local home cfg out err
  home=$(make_sdev_home missing scdi multi-repo.yml)
  cfg=$(make_config missing)
  err="$TMP_ROOT/missing.err"
  out=$(run_registry "$home" "$cfg" backed ghost 2>"$err")
  expect_code "$NOT_BACKED" $? "missing entry: project with no yml is not SDev-backed"
  assert_eq "$out" "" "missing entry: no stdout"
  [ ! -s "$err" ] || fail "missing entry: not-backed must not spew errors"$'\n'"$(cat "$err")"
  pass "fm-sdev-registry reports not-backed silently for a project with no entry"
}

test_not_backed_sdev_home_unset() {
  local cfg out err
  cfg=$(make_config unset)
  err="$TMP_ROOT/unset.err"
  out=$(env -u SDEV_HOME FM_CONFIG_OVERRIDE="$cfg" FM_ROOT_OVERRIDE="$ROOT" \
    "$REGISTRY" repos scdi 2>"$err")
  expect_code "$NOT_BACKED" $? "unset: no SDEV_HOME and no config file is not SDev-backed"
  assert_eq "$out" "" "unset: no stdout"
  [ ! -s "$err" ] || fail "unset: not-backed must be inert, no error spew"$'\n'"$(cat "$err")"
  pass "fm-sdev-registry is inert when SDEV_HOME is unset and no config points at one"
}

test_not_backed_nonexistent_home() {
  local cfg out err
  cfg=$(make_config nonexistent)
  err="$TMP_ROOT/nonexistent.err"
  out=$(SDEV_HOME="$TMP_ROOT/no-such-sdev-home" FM_CONFIG_OVERRIDE="$cfg" \
    FM_ROOT_OVERRIDE="$ROOT" "$REGISTRY" repos scdi 2>"$err")
  expect_code "$NOT_BACKED" $? "nonexistent: SDEV_HOME pointing nowhere is not SDev-backed"
  assert_eq "$out" "" "nonexistent: no stdout"
  [ ! -s "$err" ] || fail "nonexistent: not-backed must stay silent"$'\n'"$(cat "$err")"
  pass "fm-sdev-registry stays inert when SDEV_HOME points at a missing directory"
}

test_home_from_config_file() {
  local home cfg out
  home=$(make_sdev_home cfgfile scdi multi-repo.yml)
  cfg=$(make_config cfgfile)
  printf '# local sdev home\n%s\n' "$home" > "$cfg/sdev-home"
  out=$(env -u SDEV_HOME FM_CONFIG_OVERRIDE="$cfg" FM_ROOT_OVERRIDE="$ROOT" \
    "$REGISTRY" repos scdi)
  expect_code 0 $? "config file: SDEV_HOME resolved from config/sdev-home"
  assert_eq "$(line_count "$out")" 3 "config file: repos parsed via the config-resolved home"
  pass "fm-sdev-registry resolves SDEV_HOME from config/sdev-home when the env var is unset"
}

test_env_beats_config_file() {
  local real bogus cfg out
  real=$(make_sdev_home envwin scdi multi-repo.yml)
  bogus="$TMP_ROOT/envwin-bogus"
  mkdir -p "$bogus/core/projects.d"
  cfg=$(make_config envwin)
  printf '%s\n' "$bogus" > "$cfg/sdev-home"
  out=$(SDEV_HOME="$real" FM_CONFIG_OVERRIDE="$cfg" FM_ROOT_OVERRIDE="$ROOT" \
    "$REGISTRY" repos scdi)
  expect_code 0 $? "env wins: SDEV_HOME env takes precedence over config/sdev-home"
  assert_eq "$(line_count "$out")" 3 "env wins: repos read from the env-provided home"
  pass "fm-sdev-registry prefers SDEV_HOME env over config/sdev-home"
}

test_usage_error_without_subcommand() {
  local cfg err
  cfg=$(make_config usage)
  err="$TMP_ROOT/usage.err"
  run_registry "$TMP_ROOT" "$cfg" 2>"$err" >/dev/null
  expect_code 2 $? "usage: a missing subcommand is a usage error, not not-backed"
  [ -s "$err" ] || fail "usage: a real usage error should print guidance"
  pass "fm-sdev-registry rejects a call with no subcommand as a usage error"
}

test_multirepo_parse
test_monorepo_parse
test_localonly_parse
test_backed_true
test_not_backed_missing_entry
test_not_backed_sdev_home_unset
test_not_backed_nonexistent_home
test_home_from_config_file
test_env_beats_config_file
test_usage_error_without_subcommand
