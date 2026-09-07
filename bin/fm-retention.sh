#!/usr/bin/env bash
# Preview or apply Firstmate's closed-task retention policy.
#
# Usage: fm-retention.sh [--apply] [--scheduled]
#
# Dry-run preview is the default and writes nothing.
# --apply removes only the exact listed candidates and appends a durable audit
# record under data/retention/runs/ plus data/retention/latest-summary.
# --scheduled additionally runs at most once per local calendar day; the native
# scheduler calls it hourly so a missed or session-blocked run gets another chance.
#
# The policy reads closure dates from canonical checked backlog rows in
# data/backlog.md and data/done-archive.md.
# Missing dates, duplicate ids, malformed ownership, unsafe paths, live endpoint
# metadata, and every failed landed-work proof are retained and reported.
# config/retention-days is one positive integer and defaults to 15 when absent.
# Large attachments are regular files of at least 10 MiB under a closed task's
# data directory, excluding brief.md and report.md.
# At most ten workspaces are removed per run; tests may narrow these fixed safety
# bounds with FM_RETENTION_ATTACHMENT_MIN_BYTES and FM_RETENTION_MAX_WORKSPACES.
#
# Workspace deletion uses bin/fm-landed-work-lib.sh, the same predicate sourced by
# fm-teardown.sh.
# Retention sets FM_LANDED_WORK_NO_FETCH=1, so ambiguity retains work instead of
# refreshing or changing repository refs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
APPLY=0
SCHEDULED=0
ATTACHMENT_MIN_BYTES=${FM_RETENTION_ATTACHMENT_MIN_BYTES:-10485760}
MAX_WORKSPACES=${FM_RETENTION_MAX_WORKSPACES:-10}
TODAY=${FM_RETENTION_TODAY:-$(date +%Y-%m-%d)}
TREEHOUSE_HOME=${TREEHOUSE_ROOT:-$HOME/.treehouse}

usage() {
  cat <<'EOF'
usage: fm-retention.sh [--apply] [--scheduled]

Preview is the default and writes nothing.
--apply deletes the exact eligible paths and writes a durable audit record.
--scheduled skips after one completed apply run on the current local date.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --scheduled) SCHEDULED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ "$SCHEDULED" -eq 0 ] || [ "$APPLY" -eq 1 ] || {
  echo "fm-retention: --scheduled requires --apply" >&2
  exit 2
}
case "$ATTACHMENT_MIN_BYTES" in ''|*[!0-9]*|0) echo "fm-retention: invalid attachment byte floor" >&2; exit 2 ;; esac
case "$MAX_WORKSPACES" in ''|*[!0-9]*|0) echo "fm-retention: invalid workspace bound" >&2; exit 2 ;; esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-landed-work-lib.sh
. "$SCRIPT_DIR/fm-landed-work-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-retention.XXXXXX")
RETENTION_LOCK="$STATE/.retention.lock"
CLAIM_LOCK="$STATE/.lock.acquire"
RETENTION_LOCK_HELD=0
CLAIM_LOCK_HELD=0
cleanup() {
  [ "$CLAIM_LOCK_HELD" -eq 0 ] || fm_lock_release "$CLAIM_LOCK"
  [ "$RETENTION_LOCK_HELD" -eq 0 ] || fm_lock_release "$RETENTION_LOCK"
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

PLAN="$TMP/plan.tsv"
ACTIVE="$TMP/active.ids"
CLOSED="$TMP/closed.tsv"
ALL_IDS="$TMP/all.ids"
WORKSPACE_BLOCKED="$TMP/workspace-blocked.ids"
WORKSPACE_PLANNED="$TMP/workspace-planned.ids"
RUNTIME_CACHE="$TMP/runtime"
mkdir -p "$RUNTIME_CACHE"
: > "$PLAN"
: > "$ACTIVE"
: > "$CLOSED"
: > "$ALL_IDS"
: > "$WORKSPACE_BLOCKED"
: > "$WORKSPACE_PLANNED"

date_valid() {
  local value=$1 rendered
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  rendered=$(date -j -f '%Y-%m-%d' "$value" '+%Y-%m-%d' 2>/dev/null \
    || date -d "$value" '+%Y-%m-%d' 2>/dev/null \
    || true)
  [ "$rendered" = "$value" ]
}

date_days_before() {
  local value=$1 days=$2
  date -j -v-"${days}"d -f '%Y-%m-%d' "$value" '+%Y-%m-%d' 2>/dev/null \
    || date -d "$value - $days days" '+%Y-%m-%d' 2>/dev/null
}

date_valid "$TODAY" || { echo "fm-retention: invalid current date $TODAY" >&2; exit 2; }
[ -d "$DATA" ] && [ ! -L "$DATA" ] || { echo "fm-retention: data directory is missing or unsafe" >&2; exit 1; }
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "fm-retention: state directory is unsafe" >&2; exit 1; }
fi
RETENTION_DAYS=15
if [ -e "$CONFIG/retention-days" ] || [ -L "$CONFIG/retention-days" ]; then
  [ -f "$CONFIG/retention-days" ] && [ ! -L "$CONFIG/retention-days" ] || {
    echo "fm-retention: config/retention-days is not a regular file" >&2
    exit 1
  }
  RETENTION_DAYS=$(awk '
    NR == 1 && $0 ~ /^[0-9]+$/ {value=$0; next}
    {invalid=1}
    END {if (NR == 1 && !invalid) print value}
  ' "$CONFIG/retention-days" 2>/dev/null || true)
fi
case "$RETENTION_DAYS" in ''|*[!0-9]*|0) echo "fm-retention: retention-days must be a positive integer" >&2; exit 2 ;; esac
CUTOFF=$(date_days_before "$TODAY" "$RETENTION_DAYS") || {
  echo "fm-retention: cannot calculate the retention cutoff" >&2
  exit 1
}

AUDIT_ROOT="$DATA/retention"
LAST_RUN="$AUDIT_ROOT/last-run-date"
if [ "$APPLY" -eq 1 ]; then
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$RETENTION_LOCK"; then
    echo "Retention skipped: another retention run is active."
    exit 0
  fi
  RETENTION_LOCK_HELD=1
  if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
    echo "Retention skipped: the session lock is changing."
    exit 0
  fi
  CLAIM_LOCK_HELD=1
  if [ -e "$STATE/.lock" ] || [ -L "$STATE/.lock" ]; then
    if [ ! -f "$STATE/.lock" ] || [ -L "$STATE/.lock" ]; then
      echo "Retention skipped: the session lock is unreadable."
      exit 0
    fi
    lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
    if fm_harness_pid_alive "$lock_pid"; then
      echo "Retention skipped: a live Firstmate session holds the lock."
      exit 0
    fi
  fi
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" >/dev/null 2>&1; then
    echo "Retention skipped: a live watcher still owns this home."
    exit 0
  fi
  if [ "$SCHEDULED" -eq 1 ] && [ -f "$LAST_RUN" ] && [ ! -L "$LAST_RUN" ] \
    && [ "$(sed -n '1p' "$LAST_RUN")" = "$TODAY" ]; then
    echo "Retention skipped: today's scheduled run already completed."
    exit 0
  fi
fi

parse_backlog() {
  local path=$1 source=$2
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  awk -v source="$source" '
    BEGIN { section = "active" }
    function completion_date(text, rest, token, count, found) {
      rest = text
      count = 0
      found = ""
      while (match(rest, /\((done|reported|merged) [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)/)) {
        token = substr(rest, RSTART, RLENGTH)
        found = substr(token, length(token) - 10, 10)
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      return count == 1 ? found : ""
    }
    /^##[[:space:]]+/ {
      heading = $0
      sub(/^##[[:space:]]+/, "", heading)
      if (heading == "Done" || heading ~ /^Archived[[:space:]]/) section = "closed"
      else section = "active"
      next
    }
    /^[-*][[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+/ {
      line = $0
      id = line
      sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", id)
      sub(/[[:space:]]+-[[:space:]].*$/, "", id)
      checked = line ~ /^[-*][[:space:]]+\[[xX]\]/
      if (section == "active") print "active\t" id "\t\t" source
      else if (section == "closed" && checked) print "closed\t" id "\t" completion_date(line) "\t" source
    }
  ' "$path"
}

{
  parse_backlog "$DATA/backlog.md" backlog
  parse_backlog "$DATA/done-archive.md" archive
} > "$TMP/records.tsv"
awk -F '\t' '$1 == "active" {print $2}' "$TMP/records.tsv" | sort -u > "$ACTIVE"
awk -F '\t' '$1 == "closed" {print $2 "\t" $3 "\t" $4}' "$TMP/records.tsv" > "$CLOSED"
awk -F '\t' '{print $2}' "$TMP/records.tsv" | sort -u > "$ALL_IDS"

if [ ! -f "$DATA/backlog.md" ] || [ -L "$DATA/backlog.md" ]; then
  echo "fm-retention: data/backlog.md is missing or unsafe; refusing all retention" >&2
  exit 1
fi

RESOLVED_DATE=
RESOLVE_REASON=
resolve_closed_task() {
  local id=$1 count dates date
  RESOLVED_DATE=
  RESOLVE_REASON=
  case "$id" in ''|*[!A-Za-z0-9._-]*) RESOLVE_REASON="task id is path-unsafe"; return 1 ;; esac
  if grep -qxF "$id" "$ACTIVE"; then
    RESOLVE_REASON="task is not closed"
    return 1
  fi
  count=$(awk -F '\t' -v id="$id" '$1 == id {n++} END {print n + 0}' "$CLOSED")
  if [ "$count" -eq 0 ]; then
    RESOLVE_REASON="task cannot be resolved in the backlog"
    return 1
  fi
  if [ "$count" -ne 1 ]; then
    RESOLVE_REASON="task has ambiguous duplicate closed records"
    return 1
  fi
  dates=$(awk -F '\t' -v id="$id" '$1 == id {print $2}' "$CLOSED")
  date=$(printf '%s\n' "$dates" | head -1)
  if ! date_valid "$date"; then
    RESOLVE_REASON="task has no unambiguous closure date"
    return 1
  fi
  RESOLVED_DATE=$date
  return 0
}

task_is_old() {
  [[ "$RESOLVED_DATE" < "$CUTOFF" ]]
}

one_line() {
  tr '\n\t' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

path_safe_for_plan() {
  case "$1" in *$'\t'*|*$'\n'*) return 1 ;; *) return 0 ;; esac
}

path_bytes() {
  local blocks
  blocks=$(du -sk -- "$1" 2>/dev/null | awk 'NR == 1 {print $1}') || return 1
  case "$blocks" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((blocks * 1024))"
}

add_remove() {
  printf 'remove\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$PLAN"
}

add_skip() {
  local id=$2 path=$3 detail=$4
  [ -n "$id" ] || id=-
  case "$id" in *$'\t'*|*$'\n'*) id=- ;; esac
  case "$path" in *$'\t'*|*$'\n'*) path='<unsafe path omitted>' ;; esac
  detail=$(printf '%s' "$detail" | one_line)
  printf 'skip\t%s\t%s\t0\t%s\t%s\n' "$1" "$id" "$path" "$detail" >> "$PLAN"
}

task_runtime_safe() {
  local id=$1 meta="$STATE/$1.meta" cache="$RUNTIME_CACHE/$1" kind backend target reason
  if [ -f "$cache.safe" ]; then return 0; fi
  if [ -f "$cache.skip" ]; then RESOLVE_REASON=$(cat "$cache.skip"); return 1; fi
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    : > "$cache.safe"
    return 0
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    RESOLVE_REASON="runtime metadata is unreadable or unsafe"
    printf '%s\n' "$RESOLVE_REASON" > "$cache.skip"
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" = secondmate ]; then
    RESOLVE_REASON="persistent secondmate metadata is never retained by age"
    printf '%s\n' "$RESOLVE_REASON" > "$cache.skip"
    return 1
  fi
  if ! reason=$(fm_backend_validate_task_endpoint "$meta" "$id" 2>&1); then
    RESOLVE_REASON="runtime metadata is ambiguous: $(printf '%s' "$reason" | one_line)"
    printf '%s\n' "$RESOLVE_REASON" > "$cache.skip"
    return 1
  fi
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
    RESOLVE_REASON="recorded runtime endpoint still exists"
    printf '%s\n' "$RESOLVE_REASON" > "$cache.skip"
    return 1
  fi
  : > "$cache.safe"
  return 0
}

mark_workspace_blocked() {
  printf '%s\n' "$1" >> "$WORKSPACE_BLOCKED"
}

workspace_count=0
plan_sdev_workspaces() {
  local sdev_home registry project root workspace id size reason meta
  if [ -n "${SDEV_HOME:-}" ]; then
    sdev_home=$SDEV_HOME
  elif [ -e "$CONFIG/sdev-home" ] || [ -L "$CONFIG/sdev-home" ]; then
    if [ ! -f "$CONFIG/sdev-home" ] || [ -L "$CONFIG/sdev-home" ]; then
      add_skip sdev-workspace "" "$CONFIG/sdev-home" "SDev home configuration is unsafe"
      return 0
    fi
    sdev_home=$(sed -n '1p' "$CONFIG/sdev-home")
  else
    return 0
  fi
  [ -d "$sdev_home/core/projects.d" ] && [ ! -L "$sdev_home/core/projects.d" ] || {
    add_skip sdev-workspace "" "$sdev_home" "SDev registry is missing or unsafe"
    return 0
  }
  for registry in "$sdev_home"/core/projects.d/*.yml; do
    [ -f "$registry" ] && [ ! -L "$registry" ] || continue
    project=$(basename "$registry" .yml)
    root="$sdev_home/projects/$project"
    [ -d "$root" ] && [ ! -L "$root" ] || continue
    find "$root" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print | sort > "$TMP/sdev-workspaces"
    while IFS= read -r workspace; do
      id=$(basename "$workspace")
      if [ -L "$workspace" ]; then
        add_skip sdev-workspace "$id" "$workspace" "workspace is symlinked"
        mark_workspace_blocked "$id"
        continue
      fi
      if ! path_safe_for_plan "$workspace"; then
        add_skip sdev-workspace "$id" "$root" "workspace path contains a tab or newline"
        mark_workspace_blocked "$id"
        continue
      fi
      if ! resolve_closed_task "$id"; then
        add_skip sdev-workspace "$id" "$workspace" "$RESOLVE_REASON"
        mark_workspace_blocked "$id"
        continue
      fi
      if ! task_is_old; then
        add_skip sdev-workspace "$id" "$workspace" "closed $RESOLVED_DATE, not more than $RETENTION_DAYS days ago"
        mark_workspace_blocked "$id"
        continue
      fi
      if ! task_runtime_safe "$id"; then
        add_skip sdev-workspace "$id" "$workspace" "$RESOLVE_REASON"
        mark_workspace_blocked "$id"
        continue
      fi
      META="$STATE/$id.meta"
      ID=$id
      WT=$workspace
      PROJ=$workspace
      KIND=ship
      MODE=no-mistakes
      PR_URL=
      FORCE=
      SDEV_HOME_DIR=$sdev_home
      SDEV_PROJ=$project
      SDEV_WS=$workspace
      SDEV_BRANCH="task/$id"
      FM_LANDED_WORK_NO_FETCH=1
      FM_LANDED_WORK_REQUIRE_TASK_BRANCH=1
      if ! reason=$(validate_sdev_teardown_safety 2>&1); then
        add_skip sdev-workspace "$id" "$workspace" "landed-work check refused: $(printf '%s' "$reason" | one_line)"
        mark_workspace_blocked "$id"
        continue
      fi
      size=$(path_bytes "$workspace" || true)
      if [ -z "$size" ]; then
        add_skip sdev-workspace "$id" "$workspace" "workspace size is unreadable"
        mark_workspace_blocked "$id"
        continue
      fi
      workspace_count=$((workspace_count + 1))
      if [ "$workspace_count" -gt "$MAX_WORKSPACES" ]; then
        add_skip sdev-workspace "$id" "$workspace" "per-run workspace limit $MAX_WORKSPACES reached"
        mark_workspace_blocked "$id"
        continue
      fi
      add_remove sdev-workspace "$id" "$size" "$workspace" "$project"
      printf '%s\n' "$id" >> "$WORKSPACE_PLANNED"
    done < "$TMP/sdev-workspaces"
  done
}

plan_treehouse_workspaces() {
  local workspace top branch id size reason meta mode pr_url
  if [ ! -d "$TREEHOUSE_HOME" ] || [ -L "$TREEHOUSE_HOME" ]; then
    [ ! -e "$TREEHOUSE_HOME" ] && [ ! -L "$TREEHOUSE_HOME" ] \
      || add_skip treehouse-worktree "" "$TREEHOUSE_HOME" "treehouse root is unsafe"
    return 0
  fi
  find "$TREEHOUSE_HOME" -mindepth 3 -maxdepth 3 \( -type d -o -type l \) -print | sort > "$TMP/treehouse-workspaces"
  while IFS= read -r workspace; do
    if [ -L "$workspace" ]; then
      add_skip treehouse-worktree "" "$workspace" "treehouse path is symlinked"
      continue
    fi
    workspace=$(cd "$workspace" 2>/dev/null && pwd -P) || continue
    top=$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null || true)
    [ "$top" = "$workspace" ] || continue
    branch=$(git -C "$workspace" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    case "$branch" in fm/*) id=${branch#fm/} ;; task/*) id=${branch#task/} ;; *) continue ;; esac
    if ! path_safe_for_plan "$workspace"; then
      add_skip treehouse-worktree "$id" "$TREEHOUSE_HOME" "worktree path contains a tab or newline"
      mark_workspace_blocked "$id"
      continue
    fi
    if ! resolve_closed_task "$id"; then
      add_skip treehouse-worktree "$id" "$workspace" "$RESOLVE_REASON"
      mark_workspace_blocked "$id"
      continue
    fi
    if ! task_is_old; then
      add_skip treehouse-worktree "$id" "$workspace" "closed $RESOLVED_DATE, not more than $RETENTION_DAYS days ago"
      mark_workspace_blocked "$id"
      continue
    fi
    if ! task_runtime_safe "$id"; then
      add_skip treehouse-worktree "$id" "$workspace" "$RESOLVE_REASON"
      mark_workspace_blocked "$id"
      continue
    fi
    meta="$STATE/$id.meta"
    mode=no-mistakes
    pr_url=
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      mode=$(fm_meta_get "$meta" mode)
      [ -n "$mode" ] || mode=no-mistakes
      pr_url=$(fm_meta_get "$meta" pr)
    fi
    META=$meta
    ID=$id
    WT=$workspace
    PROJ=$workspace
    KIND=ship
    MODE=$mode
    PR_URL=$pr_url
    FORCE=
    FM_LANDED_WORK_NO_FETCH=1
    if ! reason=$(validate_worktree_teardown_safety 2>&1); then
      add_skip treehouse-worktree "$id" "$workspace" "landed-work check refused: $(printf '%s' "$reason" | one_line)"
      mark_workspace_blocked "$id"
      continue
    fi
    size=$(path_bytes "$workspace" || true)
    if [ -z "$size" ]; then
      add_skip treehouse-worktree "$id" "$workspace" "worktree size is unreadable"
      mark_workspace_blocked "$id"
      continue
    fi
    workspace_count=$((workspace_count + 1))
    if [ "$workspace_count" -gt "$MAX_WORKSPACES" ]; then
      add_skip treehouse-worktree "$id" "$workspace" "per-run workspace limit $MAX_WORKSPACES reached"
      mark_workspace_blocked "$id"
      continue
    fi
    add_remove treehouse-worktree "$id" "$size" "$workspace" ""
    printf '%s\n' "$id" >> "$WORKSPACE_PLANNED"
  done < "$TMP/treehouse-workspaces"
}

task_records_may_be_removed() {
  local id=$1
  ! grep -qxF "$id" "$WORKSPACE_BLOCKED"
}

stat_bytes() {
  stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null
}

plan_reports_and_attachments() {
  local task_dir id path size
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 0
  find "$DATA" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print | sort | while IFS= read -r task_dir; do
    id=$(basename "$task_dir")
    case "$id" in retention) continue ;; esac
    if [ -L "$task_dir" ]; then
      add_skip data-task "$id" "$task_dir" "task data directory is symlinked"
      continue
    fi
    if [ -e "$task_dir/report.md" ] || [ -L "$task_dir/report.md" ]; then
      path="$task_dir/report.md"
      if ! path_safe_for_plan "$path"; then
        add_skip report "$id" "$task_dir" "report path contains a tab or newline"
      elif ! resolve_closed_task "$id"; then
        add_skip report "$id" "$path" "$RESOLVE_REASON"
      elif ! task_is_old; then
        add_skip report "$id" "$path" "closed $RESOLVED_DATE, not more than $RETENTION_DAYS days ago"
      elif ! task_runtime_safe "$id"; then
        add_skip report "$id" "$path" "$RESOLVE_REASON"
      elif ! task_records_may_be_removed "$id"; then
        add_skip report "$id" "$path" "workspace was retained in this run"
      elif [ ! -f "$path" ] || [ -L "$path" ]; then
        add_skip report "$id" "$path" "report is not a regular file"
      else
        size=$(path_bytes "$path" || true)
        if [ -n "$size" ]; then add_remove report "$id" "$size" "$path" ""; else add_skip report "$id" "$path" "report size is unreadable"; fi
      fi
    fi
    find "$task_dir" -type d -name .git -prune -o -type f -print | sort | while IFS= read -r path; do
      [ "$path" != "$task_dir/brief.md" ] || continue
      [ "$path" != "$task_dir/report.md" ] || continue
      size=$(stat_bytes "$path" || true)
      case "$size" in ''|*[!0-9]*) add_skip attachment "$id" "$path" "attachment size is unreadable"; continue ;; esac
      [ "$size" -ge "$ATTACHMENT_MIN_BYTES" ] || continue
      if ! path_safe_for_plan "$path"; then
        add_skip attachment "$id" "$task_dir" "attachment path contains a tab or newline"
      elif ! resolve_closed_task "$id"; then
        add_skip attachment "$id" "$path" "$RESOLVE_REASON"
      elif ! task_runtime_safe "$id"; then
        add_skip attachment "$id" "$path" "$RESOLVE_REASON"
      else
        size=$(path_bytes "$path" || true)
        if [ -n "$size" ]; then add_remove attachment "$id" "$size" "$path" ""; else add_skip attachment "$id" "$path" "attachment allocation is unreadable"; fi
      fi
    done
  done
}

plan_state() {
  local path base match_count id candidate size
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  find "$STATE" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print | sort | while IFS= read -r path; do
    base=$(basename "$path")
    if ! path_safe_for_plan "$path"; then
      add_skip state "" "$STATE" "state path contains a tab or newline"
      continue
    fi
    match_count=0
    id=
    while IFS= read -r candidate; do
      case "$base" in
        "$candidate".*|.hash-*_fm-"$candidate"|.count-*_fm-"$candidate"|\
        .stale-*_fm-"$candidate"|.paused-*_fm-"$candidate"|\
        .seen-"$candidate"_*|.hb-surfaced-"$candidate"|\
        .stale-since-"$candidate"|.wedge-escalations-"$candidate"|.last-"$candidate")
          match_count=$((match_count + 1))
          id=$candidate
          ;;
      esac
    done < "$ALL_IDS"
    if [ "$match_count" -eq 0 ]; then
      add_skip state "" "$path" "state ownership cannot be resolved in the backlog"
      continue
    fi
    if [ "$match_count" -ne 1 ]; then
      add_skip state "$id" "$path" "state ownership is ambiguous"
      continue
    fi
    if ! resolve_closed_task "$id"; then
      add_skip state "$id" "$path" "$RESOLVE_REASON"
    elif ! task_is_old; then
      add_skip state "$id" "$path" "closed $RESOLVED_DATE, not more than $RETENTION_DAYS days ago"
    elif ! task_runtime_safe "$id"; then
      add_skip state "$id" "$path" "$RESOLVE_REASON"
    elif ! task_records_may_be_removed "$id"; then
      add_skip state "$id" "$path" "workspace was retained in this run"
    elif [ ! -f "$path" ] || [ -L "$path" ]; then
      add_skip state "$id" "$path" "state record is not a regular file"
    else
      size=$(path_bytes "$path" || true)
      if [ -n "$size" ]; then add_remove state "$id" "$size" "$path" ""; else add_skip state "$id" "$path" "state record size is unreadable"; fi
    fi
  done
}

plan_sdev_workspaces
plan_treehouse_workspaces
sort -u "$WORKSPACE_BLOCKED" -o "$WORKSPACE_BLOCKED"
sort -u "$WORKSPACE_PLANNED" -o "$WORKSPACE_PLANNED"
plan_reports_and_attachments
plan_state

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    value = bytes + 0
    idx = 1
    while (value >= 1024 && idx < 5) { value /= 1024; idx++ }
    if (idx == 1) printf "%d %s", value, unit[idx]
    else printf "%.1f %s", value, unit[idx]
  }'
}

render_plan() {
  local verb=$1 total removes skips headline decision category id bytes path detail display
  total=$(awk -F '\t' '$1 == "remove" {sum += $4} END {printf "%.0f", sum + 0}' "$PLAN")
  removes=$(awk -F '\t' '$1 == "remove" {n++} END {print n + 0}' "$PLAN")
  skips=$(awk -F '\t' '$1 == "skip" {n++} END {print n + 0}' "$PLAN")
  headline="Retention $verb: $(human_bytes "$total") across $removes item(s); $skips item(s) skipped."
  printf '%s\n' "$headline"
  awk -F '\t' '
    {key=$2; if ($1 == "remove") {removed[key]++; bytes[key]+=$4} else skipped[key]++}
    END {for (key in removed) seen[key]=1; for (key in skipped) seen[key]=1;
      for (key in seen) printf "%s\t%d\t%.0f\t%d\n", key, removed[key]+0, bytes[key]+0, skipped[key]+0}
  ' "$PLAN" | sort | while IFS=$'\t' read -r category removes bytes skips; do
    printf 'CATEGORY\t%s\tremove=%s\tbytes=%s\tskip=%s\n' "$category" "$removes" "$bytes" "$skips"
  done
  while IFS=$'\t' read -r decision category id bytes path detail; do
    [ -n "$category" ] || continue
    if [ "$decision" = remove ]; then
      display=$(human_bytes "$bytes")
      printf 'REMOVE\t%s\t%s\t%s\t%s\n' "$category" "$display" "$id" "$path"
    else
      printf 'SKIP\t%s\t%s\t%s\t%s\n' "$category" "$id" "$path" "$detail"
    fi
  done < "$PLAN"
}

if [ "$APPLY" -eq 0 ]; then
  render_plan preview
  exit 0
fi

if [ -e "$AUDIT_ROOT" ] || [ -L "$AUDIT_ROOT" ]; then
  [ -d "$AUDIT_ROOT" ] && [ ! -L "$AUDIT_ROOT" ] || {
    echo "fm-retention: audit directory is unsafe; refusing before deletion" >&2
    exit 1
  }
fi
if [ -e "$AUDIT_ROOT/runs" ] || [ -L "$AUDIT_ROOT/runs" ]; then
  [ -d "$AUDIT_ROOT/runs" ] && [ ! -L "$AUDIT_ROOT/runs" ] || {
    echo "fm-retention: audit runs directory is unsafe; refusing before deletion" >&2
    exit 1
  }
fi
for marker in "$LAST_RUN" "$AUDIT_ROOT/latest-summary"; do
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || {
      echo "fm-retention: audit marker is unsafe: $marker; refusing before deletion" >&2
      exit 1
    }
  fi
done
mkdir -p "$AUDIT_ROOT/runs"
run_stamp=$(date -u +%Y%m%dT%H%M%SZ)
AUDIT="$AUDIT_ROOT/runs/$run_stamp-$$.log"
PENDING="$AUDIT.pending"
{
  printf 'Retention apply in progress; inspect the outcomes below before retrying.\n'
  printf 'run_utc=%s\n' "$run_stamp"
  printf 'retention_days=%s\n' "$RETENTION_DAYS"
  printf 'cutoff=%s\n' "$CUTOFF"
} > "$PENDING"
[ -f "$PENDING" ] && [ ! -L "$PENDING" ] || {
  echo "fm-retention: cannot publish the pending audit; refusing before deletion" >&2
  exit 1
}

RESULT="$TMP/result.tsv"
FAILED_WORKSPACES="$TMP/failed-workspaces.ids"
: > "$RESULT"
: > "$FAILED_WORKSPACES"
record_result() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$RESULT"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$PENDING"
}
recheck_sdev_workspace() {
  local id=$1 path=$2 project=$3 sdev_home reason
  sdev_home=$(dirname "$(dirname "$(dirname "$path")")")
  META="$STATE/$id.meta"
  ID=$id
  WT=$path
  PROJ=$path
  KIND=ship
  MODE=no-mistakes
  PR_URL=
  FORCE=
  SDEV_HOME_DIR=$sdev_home
  SDEV_PROJ=$project
  SDEV_WS=$path
  SDEV_BRANCH="task/$id"
  FM_LANDED_WORK_NO_FETCH=1
  FM_LANDED_WORK_REQUIRE_TASK_BRANCH=1
  reason=$(validate_sdev_teardown_safety 2>&1) || {
    RESOLVE_REASON=$(printf '%s' "$reason" | one_line)
    return 1
  }
}

recheck_treehouse_worktree() {
  local id=$1 path=$2 meta="$STATE/$1.meta" reason branch
  META=$meta
  ID=$id
  WT=$path
  PROJ=$path
  KIND=ship
  MODE=no-mistakes
  PR_URL=
  FORCE=
  branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  case "$branch" in
    "fm/$id"|"task/$id") ;;
    *) RESOLVE_REASON="worktree ownership changed before deletion"; return 1 ;;
  esac
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    MODE=$(fm_meta_get "$meta" mode)
    [ -n "$MODE" ] || MODE=no-mistakes
    PR_URL=$(fm_meta_get "$meta" pr)
  fi
  FM_LANDED_WORK_NO_FETCH=1
  reason=$(validate_worktree_teardown_safety 2>&1) || {
    RESOLVE_REASON=$(printf '%s' "$reason" | one_line)
    return 1
  }
}

while IFS=$'\t' read -r decision category id bytes path detail; do
  if [ "$decision" = skip ]; then
    record_result "$decision" "$category" "$id" "$bytes" "$path" "$detail"
    continue
  fi
  case "$category" in
    sdev-workspace)
      if [ ! -d "$path" ] || [ -L "$path" ]; then
        record_result skip "$category" "$id" 0 "$path" "workspace changed before deletion"
        printf '%s\n' "$id" >> "$FAILED_WORKSPACES"
      elif ! recheck_sdev_workspace "$id" "$path" "$detail"; then
        record_result skip "$category" "$id" 0 "$path" "landed-work recheck refused: $RESOLVE_REASON"
        printf '%s\n' "$id" >> "$FAILED_WORKSPACES"
      elif SDEV_HOME=${SDEV_HOME:-$(dirname "$(dirname "$(dirname "$path")")")} sdev -p "$detail" end "$id" --keep-branch >/dev/null 2>&1; then
        record_result removed "$category" "$id" "$bytes" "$path" -
      else
        record_result skip "$category" "$id" 0 "$path" "sdev end failed; workspace retained"
        printf '%s\n' "$id" >> "$FAILED_WORKSPACES"
      fi
      ;;
    treehouse-worktree)
      if [ ! -d "$path" ] || [ -L "$path" ]; then
        record_result skip "$category" "$id" 0 "$path" "worktree changed before deletion"
        printf '%s\n' "$id" >> "$FAILED_WORKSPACES"
      elif ! recheck_treehouse_worktree "$id" "$path"; then
        record_result skip "$category" "$id" 0 "$path" "landed-work recheck refused: $RESOLVE_REASON"
        printf '%s\n' "$id" >> "$FAILED_WORKSPACES"
      elif treehouse destroy "$path" --yes >/dev/null 2>&1; then
        record_result removed "$category" "$id" "$bytes" "$path" -
      else
        record_result skip "$category" "$id" 0 "$path" "treehouse destroy failed; worktree retained"
        printf '%s\n' "$id" >> "$FAILED_WORKSPACES"
      fi
      ;;
    report|attachment|state)
      if grep -qxF "$id" "$FAILED_WORKSPACES"; then
        record_result skip "$category" "$id" 0 "$path" "workspace deletion failed in this run"
      elif [ ! -f "$path" ] || [ -L "$path" ]; then
        record_result skip "$category" "$id" 0 "$path" "file changed before deletion"
      elif rm -f -- "$path"; then
        record_result removed "$category" "$id" "$bytes" "$path" -
      else
        record_result skip "$category" "$id" 0 "$path" "file removal failed"
      fi
      ;;
  esac
done < "$PLAN"

removed_bytes=$(awk -F '\t' '$1 == "removed" {sum += $4} END {printf "%.0f", sum + 0}' "$RESULT")
removed_count=$(awk -F '\t' '$1 == "removed" {n++} END {print n + 0}' "$RESULT")
skip_count=$(awk -F '\t' '$1 == "skip" {n++} END {print n + 0}' "$RESULT")
summary="Retention reclaimed $(human_bytes "$removed_bytes") across $removed_count item(s); $skip_count item(s) skipped."
{
  printf '%s\n' "$summary"
  printf 'run_utc=%s\n' "$run_stamp"
  printf 'retention_days=%s\n' "$RETENTION_DAYS"
  printf 'cutoff=%s\n' "$CUTOFF"
  while IFS=$'\t' read -r decision category id bytes path detail; do
    if [ "$decision" = removed ]; then
      printf 'REMOVED\t%s\t%s\t%s\t%s\n' "$category" "$(human_bytes "$bytes")" "$id" "$path"
    else
      printf 'SKIP\t%s\t%s\t%s\t%s\n' "$category" "$id" "$path" "$detail"
    fi
  done < "$RESULT"
} > "$TMP/audit"
mv "$TMP/audit" "$AUDIT"
rm -f "$PENDING"
printf '%s\n' "$summary" > "$TMP/latest-summary"
mv "$TMP/latest-summary" "$AUDIT_ROOT/latest-summary"
printf '%s\n' "$TODAY" > "$TMP/last-run-date"
mv "$TMP/last-run-date" "$LAST_RUN"
printf '%s\n' "$summary"
