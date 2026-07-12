#!/usr/bin/env bash
# Tests for bin/fm-ship-multi.sh: all-or-nothing multi-repo SDev ship.
#
# A multi-repo SDev task lands as one atomic unit. Every CHANGED repo must reach
# a ready landing candidate first (a remote PR green+approved, or a local-only
# branch that fast-forwards) before ANY repo lands. If one changed repo is not
# ready, NOTHING lands (atomic-or-nothing). Ready repos land together in
# dependency order (from the overlay's order array, default common-first).
#
# Fakes, like the other SDev suites: a fake gh-axi answers PR readiness and logs
# merges; the local-only repo lands by a real git fast-forward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SHIP="$ROOT/bin/fm-ship-multi.sh"
TMP_ROOT=$(fm_test_tmproot fm-ship-multi)
SLUG=task-ship-x1

assert_eq() {
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- expected ---"$'\n'"$2"$'\n'"--- actual ---"$'\n'"$1"
}

# A fake gh-axi: `pr view` reports OPEN + APPROVED; `pr checks` fails only for a
# repo listed in FM_FAKE_UNGREEN; `pr merge` logs to FM_FAKE_MERGE_LOG.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
url_repo() { local u=${1%/pull/*}; printf '%s' "${u##*/}"; }
case "${1:-} ${2:-}" in
  "pr view")
    qval=""; prev=""
    for a in "$@"; do [ "$prev" = "-q" ] && qval=$a; prev=$a; done
    case "$qval" in
      .state) printf 'OPEN\n' ;;
      .reviewDecision) printf 'APPROVED\n' ;;
      *) printf '\n' ;;
    esac
    ;;
  "pr checks")
    repo=$(url_repo "$3")
    case " ${FM_FAKE_UNGREEN:-} " in *" $repo "*) exit 1 ;; esac
    exit 0
    ;;
  "pr merge")
    [ -z "${FM_FAKE_MERGE_LOG:-}" ] || printf 'merge %s\n' "$*" >> "$FM_FAKE_MERGE_LOG"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

# A remote repo: origin bare, base branch pushed, a task/<slug> worktree with a
# commit, and a recorded pr_<key>= in meta.
make_remote_repo() {
  local work=$1 ws=$2 path=$3 base=$4 src origin
  src="$work/src-$path"; origin="$work/origin-$path.git"
  git init -q "$src"; printf 'base\n' > "$src/f.txt"
  git -C "$src" add f.txt; git -C "$src" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$src" branch -M "$base"
  git clone -q --bare "$src" "$origin"
  git -C "$src" remote add origin "file://$origin"; git -C "$src" push -q origin "$base"
  git -C "$src" worktree add -q -b "task/$SLUG" "$ws/$path" "$base"
  printf '%s change\n' "$path" > "$ws/$path/f.txt"
  git -C "$ws/$path" add f.txt; git -C "$ws/$path" -c user.email=t@t -c user.name=t commit -qm "$path change"
}

# A local-only repo: no origin, base branch, a task/<slug> worktree ahead of base.
make_local_repo() {
  local work=$1 ws=$2 path=$3 base=$4 src
  src="$work/src-$path"
  git init -q "$src"; printf 'base\n' > "$src/f.txt"
  git -C "$src" add f.txt; git -C "$src" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$src" branch -M "$base"
  git -C "$src" worktree add -q -b "task/$SLUG" "$ws/$path" "$base"
  printf '%s change\n' "$path" > "$ws/$path/f.txt"
  git -C "$ws/$path" add f.txt; git -C "$ws/$path" -c user.email=t@t -c user.name=t commit -qm "$path change"
}

# 3-repo SDev task: api + ui remote (no-mistakes / direct-PR), common local-only.
# Overlay pins per-repo modes and order common-first.
setup_task() {
  local case_dir=$1 home ws sdev cfg
  home="$case_dir/home"; ws="$case_dir/ws"; sdev="$case_dir/sdev"; cfg="$home/config"
  mkdir -p "$home/state" "$ws" "$sdev/core/projects.d" "$cfg"
  make_remote_repo "$case_dir" "$ws" api_src develop
  make_remote_repo "$case_dir" "$ws" ui_src develop
  make_local_repo "$case_dir" "$ws" common_src develop
  cat > "$sdev/core/projects.d/scdi.yml" <<'YML'
repos:
  api: { path: api_src, default_base: develop, compose_role: api }
  ui: { path: ui_src, default_base: develop, compose_role: ui }
  common: { path: common_src, default_base: develop, compose_role: common }
YML
  cat > "$cfg/landing-policy.json" <<'JSON'
{ "projects": { "scdi": {
  "order": ["common", "api", "ui"],
  "default": { "mode": "no-mistakes" },
  "repos": { "ui": { "mode": "direct-PR" }, "common": { "mode": "local-only" } } } } }
JSON
  fm_write_meta "$home/state/$SLUG.meta" \
    "window=fm-$SLUG" "worktree=$ws" "project=$home/projects/scdi" \
    "harness=claude" "kind=ship" "sdev_home=$sdev" "slug=$SLUG" \
    "repos=api ui common" \
    "pr_api=https://github.com/o/api/pull/1" \
    "pr_ui=https://github.com/o/ui/pull/2"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

run_ship() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SHIP" "$@"
}

local_base_head() { git -C "$1" rev-parse --verify --quiet develop; }

test_nothing_lands_when_one_repo_not_green() {
  local case_dir home fakebin merge_log common_before code
  case_dir="$TMP_ROOT/blocked"
  home=$(setup_task "$case_dir")
  fakebin=$(make_fakebin "$case_dir/fake")
  merge_log="$case_dir/merge.log"; : > "$merge_log"
  common_before=$(local_base_head "$case_dir/src-common_src")
  set +e
  FM_FAKE_UNGREEN=ui FM_FAKE_MERGE_LOG="$merge_log" \
    run_ship "$home" "$fakebin" "$SLUG" --merge >/dev/null 2>"$case_dir/err"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "blocked: --merge must refuse when a changed repo is not green"
  assert_grep "ui" "$case_dir/err" "blocked: the blocking repo (ui) is named"
  [ ! -s "$merge_log" ] || fail "blocked: NO remote PR may be merged when the batch is blocked"$'\n'"$(cat "$merge_log")"
  assert_eq "$(local_base_head "$case_dir/src-common_src")" "$common_before" \
    "blocked: the local-only repo must NOT be merged when the batch is blocked"
  pass "fm-ship-multi lands nothing when any changed repo is not ready"
}

test_all_land_in_order_when_ready() {
  local case_dir home fakebin merge_log out meta common_before common_after
  case_dir="$TMP_ROOT/ready"
  home=$(setup_task "$case_dir")
  fakebin=$(make_fakebin "$case_dir/fake")
  merge_log="$case_dir/merge.log"; : > "$merge_log"
  common_before=$(local_base_head "$case_dir/src-common_src")
  out=$(FM_FAKE_MERGE_LOG="$merge_log" run_ship "$home" "$fakebin" "$SLUG" --merge 2>"$case_dir/err") \
    || { cat "$case_dir/err"; fail "ready: --merge should land all repos"; }

  # Landing order: common first (local), then api, then ui.
  assert_eq "$(printf '%s\n' "$out" | grep '^landed:' | sed 's/^landed: //')" \
    "$(printf 'common\napi\nui')" "ready: repos land in dependency order (common first)"
  # Both remote PRs merged.
  assert_grep "o/api" "$merge_log" "ready: api PR merged"
  assert_grep "o/ui" "$merge_log" "ready: ui PR merged"
  # Local-only repo fast-forwarded.
  common_after=$(local_base_head "$case_dir/src-common_src")
  [ "$common_after" != "$common_before" ] || fail "ready: local-only repo must be fast-forward merged"
  # Landed markers recorded per repo.
  meta="$home/state/$SLUG.meta"
  assert_grep "landed_api=https://github.com/o/api/pull/1" "$meta" "ready: api landed marker recorded"
  assert_grep "landed_ui=https://github.com/o/ui/pull/2" "$meta" "ready: ui landed marker recorded"
  assert_grep "landed_common=local" "$meta" "ready: common landed marker recorded"
  pass "fm-ship-multi lands every changed repo atomically in dependency order"
}

test_status_reports_blocked_without_merging() {
  local case_dir home fakebin merge_log code
  case_dir="$TMP_ROOT/status"
  home=$(setup_task "$case_dir")
  fakebin=$(make_fakebin "$case_dir/fake")
  merge_log="$case_dir/merge.log"; : > "$merge_log"
  set +e
  FM_FAKE_UNGREEN=api FM_FAKE_MERGE_LOG="$merge_log" \
    run_ship "$home" "$fakebin" "$SLUG" >/dev/null 2>"$case_dir/err"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "status: a blocked batch reports non-zero"
  [ ! -s "$merge_log" ] || fail "status: status mode must never merge"
  pass "fm-ship-multi status reports a blocked batch without merging anything"
}

test_nothing_lands_when_one_repo_not_green
test_all_land_in_order_when_ready
test_status_reports_blocked_without_merging
