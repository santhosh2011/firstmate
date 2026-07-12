#!/usr/bin/env bash
# Tests for bin/fm-landing-policy.sh: map (project, repo) to "<mode> <yolo>" from
# a firstmate-side overlay at config/landing-policy.json.
#
# Resolution: a per-repo override merges over the project default, and each axis
# (mode, yolo) falls back independently. When the overlay is absent, the project
# is unknown, or the file is unreadable, it resolves to the same fail-safe
# bin/fm-project-mode.sh uses today - "no-mistakes off" - so an unknown or broken
# overlay never silently drops the gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANDING="$ROOT/bin/fm-landing-policy.sh"
TMP_ROOT=$(fm_test_tmproot fm-landing-policy-tests)

assert_eq() {
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- expected ---"$'\n'"$2"$'\n'"--- actual ---"$'\n'"$1"
}

# The overlay shared by the resolution tests: scdi lands via PR by default, with
# a full per-repo override (common -> local-only on) and a partial one
# (ui -> yolo only, mode inherited); spnr is local-only with yolo on by default.
POLICY='{
  "projects": {
    "scdi": {
      "default": { "mode": "direct-PR", "yolo": false },
      "repos": {
        "common": { "mode": "local-only", "yolo": true },
        "ui": { "yolo": true }
      }
    },
    "spnr": {
      "default": { "mode": "local-only", "yolo": true },
      "repos": { "ui": { "yolo": false } }
    }
  }
}'

# make_config <case> [json]: build a config dir; when json is given, write it as
# landing-policy.json. Echo the config dir path.
make_config() {
  local dir="$TMP_ROOT/$1-config"
  mkdir -p "$dir"
  [ "$#" -lt 2 ] || printf '%s\n' "$2" > "$dir/landing-policy.json"
  printf '%s\n' "$dir"
}

run_landing() {
  local cfg=$1
  shift
  FM_CONFIG_OVERRIDE="$cfg" FM_ROOT_OVERRIDE="$ROOT" "$LANDING" "$@"
}

test_project_default() {
  local cfg out
  cfg=$(make_config default "$POLICY")
  out=$(run_landing "$cfg" scdi api)
  assert_eq "$out" "direct-PR off" "project default: a repo with no override takes the project default"
  pass "fm-landing-policy resolves a repo to its project default when there is no per-repo override"
}

test_per_repo_override() {
  local cfg out
  cfg=$(make_config override "$POLICY")
  out=$(run_landing "$cfg" scdi common)
  assert_eq "$out" "local-only on" "per-repo override: a full override wins over the project default"
  pass "fm-landing-policy applies a full per-repo override over the project default"
}

test_partial_override_merges_over_default() {
  local cfg out
  cfg=$(make_config partial "$POLICY")
  out=$(run_landing "$cfg" scdi ui)
  assert_eq "$out" "direct-PR on" "partial override: yolo overridden, mode inherited from the default"
  pass "fm-landing-policy merges each axis independently over the project default"
}

test_project_default_yolo_on() {
  local cfg out
  cfg=$(make_config spnr "$POLICY")
  out=$(run_landing "$cfg" spnr api)
  assert_eq "$out" "local-only on" "spnr: project default carries mode and yolo together"
  pass "fm-landing-policy carries a yolo-on project default"
}

test_per_repo_yolo_false_overrides_default_true() {
  local cfg out
  cfg=$(make_config yolofalse "$POLICY")
  out=$(run_landing "$cfg" spnr ui)
  assert_eq "$out" "local-only off" "yolo false override: an explicit per-repo yolo:false must beat a project default yolo:true"
  pass "fm-landing-policy lets a per-repo yolo:false override a project-default yolo:true"
}

test_unknown_repo_uses_project_default() {
  local cfg out
  cfg=$(make_config unknownrepo "$POLICY")
  out=$(run_landing "$cfg" scdi does-not-exist)
  assert_eq "$out" "direct-PR off" "unknown repo: a repo not listed falls back to the project default"
  pass "fm-landing-policy falls back to the project default for an unlisted repo"
}

test_no_overlay_file_fails_safe() {
  local cfg out
  cfg=$(make_config nofile)
  out=$(run_landing "$cfg" scdi api)
  assert_eq "$out" "no-mistakes off" "no overlay: absent file resolves to the gate-preserving default"
  pass "fm-landing-policy defaults to no-mistakes off when no overlay exists"
}

test_unknown_project_fails_safe() {
  local cfg out
  cfg=$(make_config unknownproj "$POLICY")
  out=$(run_landing "$cfg" ghost api)
  assert_eq "$out" "no-mistakes off" "unknown project: a project absent from the overlay stays gated"
  pass "fm-landing-policy defaults to no-mistakes off for a project not in the overlay"
}

test_unknown_mode_fails_safe() {
  local cfg out err
  cfg=$(make_config badmode '{"projects":{"bad":{"default":{"mode":"turbo"}}}}')
  err="$TMP_ROOT/badmode.err"
  out=$(run_landing "$cfg" bad api 2>"$err")
  assert_eq "$out" "no-mistakes off" "unknown mode: an invalid mode falls back rather than dropping the gate"
  assert_contains "$(cat "$err")" "unknown mode" "unknown mode: warns to stderr like fm-project-mode"
  pass "fm-landing-policy rejects an unknown mode and falls back to no-mistakes off"
}

test_malformed_json_fails_safe() {
  local cfg out err
  cfg=$(make_config malformed)
  printf '{ this is not valid json\n' > "$cfg/landing-policy.json"
  err="$TMP_ROOT/malformed.err"
  out=$(run_landing "$cfg" scdi api 2>"$err")
  assert_eq "$out" "no-mistakes off" "malformed json: a broken overlay never drops the gate"
  [ -s "$err" ] || fail "malformed json: a broken overlay should warn to stderr"
  pass "fm-landing-policy fails safe to no-mistakes off on a malformed overlay"
}

test_empty_projects_object_fails_safe() {
  local cfg out
  cfg=$(make_config empty '{"projects":{}}')
  out=$(run_landing "$cfg" scdi api)
  assert_eq "$out" "no-mistakes off" "empty overlay: no projects means every repo stays gated"
  pass "fm-landing-policy defaults to no-mistakes off when the overlay has no projects"
}

test_usage_error_without_repo() {
  local cfg err
  cfg=$(make_config usage "$POLICY")
  err="$TMP_ROOT/usage.err"
  run_landing "$cfg" scdi 2>"$err" >/dev/null
  expect_code 2 $? "usage: resolving requires both a project and a repo"
  [ -s "$err" ] || fail "usage: a missing repo argument should print guidance"
  pass "fm-landing-policy requires both project and repo arguments"
}

test_project_default
test_per_repo_override
test_partial_override_merges_over_default
test_project_default_yolo_on
test_per_repo_yolo_false_overrides_default_true
test_unknown_repo_uses_project_default
test_no_overlay_file_fails_safe
test_unknown_project_fails_safe
test_unknown_mode_fails_safe
test_malformed_json_fails_safe
test_empty_projects_object_fails_safe
test_usage_error_without_repo
