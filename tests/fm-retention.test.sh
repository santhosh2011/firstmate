#!/usr/bin/env bash
# Behavioral coverage for closed-date retention, fail-closed workspace safety,
# protected records, attachment pruning, and the native scheduler definition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-retention)
RETENTION="$ROOT/bin/fm-retention.sh"
SCHEDULE="$ROOT/bin/fm-retention-schedule.sh"

write_backlog() {
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] active-task - still running (repo: demo) (kind: ship) (since 2026-01-01)

## Queued

## Blocked
- [ ] blocked-task - blocked current work (repo: demo) (kind: ship) (since 2026-01-01)

## Held
- [ ] held-task - captain-held current work (repo: demo) (kind: ship) (since 2026-01-01)

## Done
- [x] old-task - safely old (repo: demo) (kind: scout) (done 2026-08-22)
- [x] boundary-task - exactly fifteen days old (repo: demo) (kind: scout) (done 2026-08-23)
- [x] recent-task - recently closed but attachment-heavy (repo: demo) (kind: ship) (done 2026-09-06)
- [x] dirty-task - old but unlanded (repo: demo) (kind: ship) (done 2026-08-01)
- [x] duplicate-task - ambiguous first record (repo: demo) (kind: scout) (done 2026-08-01)
- [x] duplicate-task - ambiguous second record (repo: demo) (kind: scout) (done 2026-08-02)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-08
- [x] blocked-task - stale historical copy (repo: demo) (kind: ship) (done 2026-08-01)
- [x] held-task - stale historical copy (repo: demo) (kind: ship) (done 2026-08-01)
EOF
}

make_world() {
  local world=$1 home tree source worktree item
  home="$world/home"
  tree="$world/treehouse"
  source="$world/source"
  worktree="$tree/pool/1/repo"
  mkdir -p "$home/data" "$home/state" "$home/config" "$tree/pool/1"
  write_backlog "$home"
  for item in old-task boundary-task recent-task active-task blocked-task held-task dirty-task duplicate-task unresolved-task; do
    mkdir -p "$home/data/$item"
  done
  printf '%2048s' '' > "$home/data/old-task/brief.md"
  printf '%s\n' old-report > "$home/data/old-task/report.md"
  printf '%2048s' '' > "$home/data/old-task/capture.bin"
  printf '%s\n' boundary-report > "$home/data/boundary-task/report.md"
  printf '%2048s' '' > "$home/data/recent-task/mock-dataset.bin"
  printf '%2048s' '' > "$home/data/active-task/live-capture.bin"
  printf '%s\n' blocked-report > "$home/data/blocked-task/report.md"
  printf '%s\n' held-report > "$home/data/held-task/report.md"
  printf '%s\n' dirty-report > "$home/data/dirty-task/report.md"
  printf '%s\n' duplicate-report > "$home/data/duplicate-task/report.md"
  printf '%s\n' unresolved-report > "$home/data/unresolved-task/report.md"
  printf '%s\n' old-state > "$home/state/old-task.status"
  printf '%s\n' old-watcher-state > "$home/state/.hash-firstmate_fm-old-task"
  printf '%s\n' boundary-state > "$home/state/boundary-task.status"
  printf '%s\n' dirty-state > "$home/state/dirty-task.status"
  printf '%s\n' dirty-watcher-state > "$home/state/.count-firstmate_fm-dirty-task"
  printf '%s\n' active-state > "$home/state/active-task.status"
  printf '%s\n' orphan-state > "$home/state/orphan-task.status"
  for item in backlog.md captain.md captain-shared.md learnings.md projects.md secondmates.md; do
    printf '%2048s' '' > "$home/data/$item"
  done
  write_backlog "$home"
  fm_git_worktree "$source" "$worktree" fm/dirty-task
  printf '%s\n' unlanded > "$worktree/uncommitted.txt"
  printf '%s|%s\n' "$home" "$tree"
}

run_retention() {
  local home=$1 tree=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" SDEV_HOME='' TREEHOUSE_ROOT="$tree" \
    FM_RETENTION_TODAY=2026-09-07 FM_RETENTION_ATTACHMENT_MIN_BYTES=1024 \
    FM_RETENTION_MAX_WORKSPACES=10 "$RETENTION" "$@"
}

test_preview_uses_closure_age_and_refuses_unlanded_work() {
  local world rec home tree out
  world="$TMP_ROOT/preview"
  rec=$(make_world "$world")
  home=${rec%%|*}
  tree=${rec#*|}
  out=$(run_retention "$home" "$tree")
  assert_contains "$out" $'REMOVE\treport' "old report was not previewed"
  assert_contains "$out" 'boundary-task/report.md' "age-boundary report was not listed"
  assert_contains "$out" 'not more than 15 days ago' "exact age boundary was not retained"
  assert_contains "$out" 'dirty-task' "dirty workspace was not listed"
  assert_contains "$out" 'landed-work check refused' "dirty workspace did not use the shared refusal"
  assert_contains "$out" 'uncommitted changes' "dirty reason was not preserved"
  assert_contains "$out" 'ambiguous duplicate closed records' "duplicate backlog ownership was not retained"
  assert_contains "$out" 'task cannot be resolved in the backlog' "unresolved task was not retained"
  assert_contains "$out" 'orphan-task.status' "unresolved state path was not reported"
  assert_contains "$out" 'state ownership cannot be resolved in the backlog' "unresolved state reason was not reported"
  [ ! -e "$home/data/retention" ] || fail "dry run wrote an audit directory"
  [ -f "$home/data/old-task/report.md" ] || fail "dry run deleted the old report"
  pass "preview uses closure age, keeps the exact boundary, and reports every ambiguity and unlanded refusal"
}

test_apply_prunes_selected_records_but_preserves_briefs_and_protected_files() {
  local world rec home tree out item
  world="$TMP_ROOT/apply"
  rec=$(make_world "$world")
  home=${rec%%|*}
  tree=${rec#*|}
  out=$(run_retention "$home" "$tree" --apply)
  assert_contains "$out" 'Retention reclaimed' "apply did not print the plain captain summary"
  [ ! -e "$home/data/old-task/report.md" ] || fail "old report survived apply"
  [ ! -e "$home/data/old-task/capture.bin" ] || fail "old large attachment survived apply"
  [ ! -e "$home/data/recent-task/mock-dataset.bin" ] || fail "large attachment on a recently closed task survived"
  [ ! -e "$home/state/old-task.status" ] || fail "old volatile task record survived apply"
  [ ! -e "$home/state/.hash-firstmate_fm-old-task" ] || fail "old task-owned watcher record survived apply"
  [ -f "$home/data/old-task/brief.md" ] || fail "brief was deleted"
  [ -f "$home/data/boundary-task/report.md" ] || fail "exact age-boundary report was deleted"
  [ -f "$home/data/active-task/live-capture.bin" ] || fail "in-flight attachment was deleted"
  [ -f "$home/data/blocked-task/report.md" ] || fail "blocked task report was deleted"
  [ -f "$home/data/held-task/report.md" ] || fail "held task report was deleted"
  [ -f "$home/data/dirty-task/report.md" ] || fail "records were deleted while unlanded work remained"
  [ -f "$home/state/dirty-task.status" ] || fail "state was deleted while unlanded work remained"
  [ -f "$home/state/.count-firstmate_fm-dirty-task" ] || fail "watcher state was deleted while unlanded work remained"
  [ -f "$home/state/orphan-task.status" ] || fail "unresolved state record was deleted"
  [ -f "$home/data/duplicate-task/report.md" ] || fail "ambiguous report was deleted"
  [ -f "$home/data/unresolved-task/report.md" ] || fail "unresolved report was deleted"
  for item in backlog.md captain.md captain-shared.md learnings.md projects.md secondmates.md; do
    [ -f "$home/data/$item" ] || fail "protected file $item was deleted"
  done
  [ -f "$home/data/retention/latest-summary" ] || fail "durable summary was not written"
  find "$home/data/retention/runs" -type f -name '*.log' | grep -q . \
    || fail "durable detailed audit was not written"
  pass "apply removes selected reports, attachments, and state while preserving briefs, protected files, active work, and ambiguity"
}

test_scheduler_is_hourly_opportunity_with_once_daily_apply_gate() {
  local world home out
  world="$TMP_ROOT/schedule"
  home="$world/home"
  mkdir -p "$home"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCHEDULE" print-plist)
  assert_contains "$out" '<key>RunAtLoad</key>' "scheduler does not catch login opportunities"
  assert_contains "$out" '<key>StartInterval</key>' "scheduler has no retry cadence"
  assert_contains "$out" '<integer>3600</integer>' "scheduler retry cadence changed"
  assert_contains "$out" '<string>--apply</string>' "scheduler does not select deletion explicitly"
  assert_contains "$out" '<string>--scheduled</string>' "scheduler does not select the once-daily gate"
  [ ! -e "$home/data" ] || fail "print-plist mutated the operational home"
  pass "native scheduler provides first-opportunity retries while the command owns one completed run per day"
}

make_old_registry_repo() {
  local repo=$1 branch=$2
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s\n' main > "$repo/base.txt"
  git -C "$repo" add base.txt
  GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z \
    git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm main
  git -C "$repo" branch -M main
  git -C "$repo" checkout -qb develop
  printf '%s\n' develop > "$repo/develop.txt"
  git -C "$repo" add develop.txt
  GIT_AUTHOR_DATE=2020-01-02T00:00:00Z GIT_COMMITTER_DATE=2020-01-02T00:00:00Z \
    git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm develop
  git -C "$repo" checkout -qb "$branch"
  find "$repo" -type f -exec touch -t 202001020000 {} +
}

test_orphan_sdev_workspace_uses_registry_base_and_fallback_clock() {
  local world home sdev tree workspace unlanded stray out
  world="$TMP_ROOT/orphan-sdev"
  home="$world/home"
  sdev="$world/sdev"
  tree="$world/treehouse"
  workspace="$sdev/projects/pdmt/orphan-registry-a1"
  unlanded="$sdev/projects/pdmt/orphan-unlanded-b2"
  stray="$sdev/projects/pdmt/aiworkshop"
  mkdir -p "$home/data" "$home/state" "$home/config" "$sdev/core/projects.d" "$workspace" "$unlanded" "$stray" "$tree"
  write_backlog "$home"
  cat > "$sdev/core/projects.d/pdmt.yml" <<'EOF'
repos:
  chips:
    path: chips
    default_base: develop
EOF
  make_old_registry_repo "$workspace/chips" task/orphan-registry-a1
  make_old_registry_repo "$unlanded/chips" task/orphan-unlanded-b2
  printf '%s\n' unlanded > "$unlanded/chips/unlanded.txt"
  git -C "$unlanded/chips" add unlanded.txt
  GIT_AUTHOR_DATE=2020-01-03T00:00:00Z GIT_COMMITTER_DATE=2020-01-03T00:00:00Z \
    git -C "$unlanded/chips" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unlanded
  find "$unlanded/chips" -type f -exec touch -t 202001030000 {} +
  make_old_registry_repo "$stray/chips" task/aiworkshop
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" SDEV_HOME="$sdev" TREEHOUSE_ROOT="$tree" \
    FM_RETENTION_TODAY=2026-09-07 "$RETENTION")
  assert_contains "$out" $'REMOVE\tsdev-workspace' "orphan SDev workspace was not previewed"
  assert_contains "$out" 'orphan-registry-a1' "orphan SDev task identity was lost"
  assert_contains "$out" 'project=pdmt; clock=' "SDev preview omitted the project and fallback clock"
  assert_contains "$out" 'fallback' "SDev orphan did not disclose its fallback clock"
  assert_contains "$out" 'orphan-unlanded-b2' "unlanded orphan workspace was not reported"
  assert_contains "$out" 'landed-work check refused' "unlanded orphan workspace was not retained"
  assert_contains "$out" $'SKIP\tnon-task\taiworkshop' "non-task SDev directory was not classified explicitly"
  pass "orphan SDev workspaces use registry bases and disclosed evidence clocks while non-task directories remain"
}

test_orphan_treehouse_worktree_uses_its_own_evidence() {
  local world rec home tree source worktree stray out
  world="$TMP_ROOT/orphan-treehouse"
  rec=$(make_world "$world")
  home=${rec%%|*}
  tree=${rec#*|}
  source="$world/orphan-source"
  worktree="$tree/pool/2/repo"
  stray="$tree/pool/3/repo"
  mkdir -p "$tree/pool/2" "$tree/pool/3"
  fm_git_worktree "$source" "$worktree" fm/orphan-tree-a1
  git -C "$source" worktree add --quiet -b fm/aiworkshop "$stray"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" SDEV_HOME='' TREEHOUSE_ROOT="$tree" \
    FM_RETENTION_TODAY=2030-09-07 FM_RETENTION_ATTACHMENT_MIN_BYTES=1024 \
    FM_RETENTION_MAX_WORKSPACES=10 "$RETENTION")
  assert_contains "$out" $'REMOVE\ttreehouse-worktree' "orphan treehouse worktree was not previewed"
  assert_contains "$out" 'orphan-tree-a1' "orphan treehouse task identity was lost"
  assert_contains "$out" 'base=' "treehouse preview omitted its resolved base"
  assert_contains "$out" 'fallback' "treehouse orphan did not disclose its fallback clock"
  assert_contains "$out" $'SKIP\tnon-task\taiworkshop' "non-task treehouse worktree was not classified explicitly"
  pass "orphan treehouse worktrees use clean, landed, inactive, aged evidence and disclose their clock"
}

test_preview_uses_closure_age_and_refuses_unlanded_work
test_apply_prunes_selected_records_but_preserves_briefs_and_protected_files
test_scheduler_is_hourly_opportunity_with_once_daily_apply_gate
test_orphan_sdev_workspace_uses_registry_base_and_fallback_clock
test_orphan_treehouse_worktree_uses_its_own_evidence
