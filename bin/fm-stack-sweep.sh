#!/usr/bin/env bash
# fm-stack-sweep.sh - reclaim the machine from app stacks that outlived the task
# that started them.
#
# Cleanup returns a task's worktree and retires its records, but it never stops
# what the task's own code started. A task that brought a docker stack up leaves
# that stack running, and its disk allocated, after the work is merged and the
# task is gone. That accumulates silently across a working day until the box is
# out of memory and the captain's review surfaces start dying. Recovering by
# hand means re-deriving, every single time, which of the running stacks are
# still backing live work and which are debris - which is exactly the judgement
# this script exists to record once, so the captain can re-run it instead of
# re-reasoning it.
#
# Cleaning is the primary action, not an opt-in. For every stack this run
# positively attributes as orphaned, a normal invocation stops it, removes its
# containers, removes the volumes docker records as belonging to it, and reports
# the space reclaimed per stack and in total. Stopping alone would leave the
# disk allocated, which is most of what the captain needed back. Use --dry-run
# to look without acting.
#
# Attribution is deliberately one-directional. A stack is acted on only on
# positive evidence that it belongs to THIS home and that its task is gone;
# every stack that cannot be attributed that confidently is reported and left
# alone. Guessing wrong in the other direction means destroying the environment
# the captain is testing in, which is the failure that actually costs him work.
#
# Three boundaries do not move:
#
#   1. Nothing belonging to a live task is ever touched. A recorded task counts
#      as live unless its endpoint is authoritatively absent, so an ambiguous or
#      unreadable answer keeps the stack. Attribution routinely names more than
#      one recorded task, because a worktree slot is handed back and reissued:
#      a stack is debris only when EVERY task naming it is authoritatively gone.
#      One live claimant keeps it, and a claimant nobody can read leaves it
#      alone and reported. Ambiguity never resolves toward removal.
#   2. Removal is always targeted by name, one container or volume at a time,
#      derived from the stack it was attributed to. This script never runs a
#      blanket sweep - no `docker volume prune`, no `docker system prune`, no
#      `-a --volumes` - because a blanket prune can unrecoverably destroy the
#      data of unrelated projects that happen to share this machine.
#   3. Unattributable means untouched. Volumes that belong to no stack this run
#      classified are reported separately with their size and are removed only
#      under --remove-dangling-volumes, which the captain has to type.
#
# Usage:
#   fm-stack-sweep.sh              clean the orphaned stacks and report the space
#   fm-stack-sweep.sh --dry-run    report only; change nothing
#   fm-stack-sweep.sh --remove-dangling-volumes
#                                  also remove the reported unattributed volumes
#   fm-stack-sweep.sh --help       print this usage
#
# Exit status: 0 when the sweep completed, 1 when docker is unavailable, when
# the declared no-go paths could not be read, or when a removal failed. An
# unreadable boundary is never reported as an empty sweep.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-no-go-lib.sh
. "$SCRIPT_DIR/fm-no-go-lib.sh"

# Print the header comment block, which is this script's authoritative
# description. Reading to the first non-comment line keeps help correct when the
# header grows instead of drifting against a hard-coded range.
usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
    "$SCRIPT_DIR/fm-stack-sweep.sh"
}

die() {
  echo "error: $*" >&2
  exit 1
}

DRY_RUN=0
REMOVE_DANGLING=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --remove-dangling-volumes) REMOVE_DANGLING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stack-sweep.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

CONTAINERS="$TMP/containers"
STACKS="$TMP/stacks"
MEM="$TMP/mem"
VOLSIZES="$TMP/volsizes"

# --- units ------------------------------------------------------------------
#
# Docker reports SI units from `system df` (kB/MB/GB) and IEC units from `stats`
# (KiB/MiB/GiB). Both are parsed here so the two readings can be summed and
# reported in one consistent unit.

size_to_bytes() {  # <docker-size-string>
  awk -v s="$1" 'BEGIN {
    v = s
    sub(/ *\/.*$/, "", v)
    gsub(/ /, "", v)
    unit = v
    sub(/^[0-9.]+/, "", unit)
    sub(/[A-Za-z]+$/, "", v)
    if (v == "") { print 0; exit }
    mult = 1
    if (unit == "kB" || unit == "KB") mult = 1000
    else if (unit == "MB") mult = 1000000
    else if (unit == "GB") mult = 1000000000
    else if (unit == "TB") mult = 1000000000000
    else if (unit == "KiB") mult = 1024
    else if (unit == "MiB") mult = 1048576
    else if (unit == "GiB") mult = 1073741824
    else if (unit == "TiB") mult = 1099511627776
    printf "%d", v * mult
  }'
}

human_bytes() {  # <bytes>
  local b=${1:-0}
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    awk -v b="$b" 'BEGIN { printf "%.1fGiB", b / 1073741824 }'
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    awk -v b="$b" 'BEGIN { printf "%.1fMiB", b / 1048576 }'
  else
    awk -v b="$b" 'BEGIN { printf "%.0fKiB", b / 1024 }'
  fi
}

# --- host pressure ----------------------------------------------------------
#
# The captain's question after a sweep is "was that worth running", so the
# report has to carry the number that made him run it. Both readings are
# best-effort: an unreadable host statistic degrades to a quieter report, never
# to a failed sweep.

# Echo "<free-bytes> <swap-used-bytes>", or nothing when the host cannot be read.
host_pressure() {
  local page free inactive speculative total swap used
  if [ -r /proc/meminfo ]; then
    total=$(awk '/^MemAvailable:/ { print $2 * 1024; exit }' /proc/meminfo 2>/dev/null || true)
    swap=$(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { print (t - f) * 1024 }' /proc/meminfo 2>/dev/null || true)
    [ -n "$total" ] || return 0
    printf '%s %s\n' "$total" "${swap:-0}"
    return 0
  fi
  command -v vm_stat >/dev/null 2>&1 || return 0
  page=$(vm_stat 2>/dev/null | awk -F'page size of ' '/page size of/ { split($2, a, " "); print a[1]; exit }') || true
  [ -n "${page:-}" ] || page=4096
  free=$(vm_stat 2>/dev/null | awk '/Pages free/ { gsub(/\./, "", $3); print $3; exit }') || true
  inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ { gsub(/\./, "", $3); print $3; exit }') || true
  speculative=$(vm_stat 2>/dev/null | awk '/Pages speculative/ { gsub(/\./, "", $3); print $3; exit }') || true
  [ -n "${free:-}" ] || return 0
  total=$(( (free + ${inactive:-0} + ${speculative:-0}) * page ))
  used=$(sysctl -n vm.swapusage 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i + 2); sub(/M$/, "", v); print int(v * 1048576); exit } }') || true
  printf '%s %s\n' "$total" "${used:-0}"
}

# --- docker inventory -------------------------------------------------------
#
# A docker that is absent, or a daemon that will not answer, is a blocker. It is
# reported as one rather than as a clean sweep, because "nothing to clean" and
# "could not look" lead the captain to opposite next actions.

command -v docker >/dev/null 2>&1 \
  || die "docker is not installed or not on PATH, so running stacks cannot be inspected"

if ! docker ps --no-trunc \
  --format '{{.ID}}	{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}	{{.Names}}' \
  > "$CONTAINERS" 2> "$TMP/docker.err"; then
  echo "error: docker is installed but the daemon did not answer, so running stacks cannot be inspected" >&2
  sed 's/^/  docker: /' "$TMP/docker.err" >&2
  exit 1
fi

# Per-container memory, keyed by container id. Wholly optional: a slow or
# refused stats read costs the report a column, not the sweep.
: > "$MEM"
docker stats --no-stream --no-trunc --format '{{.ID}}	{{.MemUsage}}' > "$MEM" 2>/dev/null || : > "$MEM"

# Per-volume disk usage, keyed by volume name. Also optional: without it the
# sweep still targets exactly the same volumes, it just cannot price them.
: > "$VOLSIZES"
docker system df -v --format '{{range .Volumes}}{{.Name}}	{{.Size}}
{{end}}' > "$VOLSIZES" 2>/dev/null || : > "$VOLSIZES"

lookup_bytes() {  # <key> <table>
  local raw
  raw=$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$2")
  [ -n "$raw" ] || { printf '0'; return 0; }
  size_to_bytes "$raw"
}

# The volumes docker labels as belonging to <stack>. This label is docker's own
# record of which compose project created the volume, so it is the targeting
# mechanism rather than any name-shape guess of ours.
stack_volumes() {  # <stack>
  docker volume ls --filter "label=com.docker.compose.project=$1" --format '{{.Name}}' 2>/dev/null || true
}

# Volumes no container references at all, captured before this run changes
# anything so the orphaned stacks' own volumes are not swept in here by the
# removals below. These are enumerated to be reported and removed BY NAME; the
# prune subcommand that would do this in one blanket call is deliberately never
# used, because it cannot distinguish this machine's unrelated projects.
docker volume ls --filter dangling=true --format '{{.Name}}' > "$TMP/dangling-raw" 2>/dev/null \
  || : > "$TMP/dangling-raw"

# --- this home's task records ----------------------------------------------
#
# Live tasks come from state/<id>.meta. Torn-down tasks leave no meta, so a
# stack named for a task that once existed here is attributed through the
# durable per-task data/<id>/ directory that survives cleanup.
#
# Records are always read most recently written first. A worktree slot is handed
# back and reissued, so several recorded tasks routinely name the same directory
# and the same derived compose project name; when they do, the slot's current
# occupant is the one whose record was written last, and an older occupant must
# never outvote it.

META_ORDER="$TMP/metas-by-recency"

# Modification time of <file>, or 0 when the host will not answer. Used only to
# order candidates for reporting and tie-breaking, never to decide whether one
# of them is live.
file_mtime() {  # <file>
  local m
  m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true)
  printf '%s' "${m:-0}"
}

# Every recorded meta, most recently written first. Built once so every
# attribution signal below walks the records in the same order.
build_meta_order() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    printf '%s\t%s\n' "$(file_mtime "$meta")" "$meta"
  done | sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f2- > "$META_ORDER"
}
build_meta_order

# Task ids this home has a durable data/<id>/ directory for but no record of
# under state/ - what a task leaves behind after cleanup, and the only shape
# that makes a stack named for it debris by name alone.
retired_task_ids() {
  local dir id
  for dir in "$DATA"/*/; do
    [ -d "$dir" ] || continue
    id=$(basename "$dir")
    [ -f "$STATE/$id.meta" ] && continue
    printf '%s\n' "$id"
  done
}

# Docker lowercases a compose project name and drops everything outside
# [a-z0-9_-], so a task id has to be put through the same normalisation before
# it can be compared with one.
compose_normalize() {  # <name>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# 0 when <path> is <prefix> itself or sits beneath it on a component boundary.
path_under() {  # <path> <prefix>
  local path=$1 prefix=$2
  [ -n "$path" ] && [ -n "$prefix" ] || return 1
  [ "$path" != "$prefix" ] || return 0
  case "$path" in
    "$prefix"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Every task id whose recorded worktree meets <working-dir>, most recent first.
# This is the strongest attribution available: it ties a running stack to a task
# through the directory the stack was actually composed from.
#
# Containment is tested both ways on purpose. A stack composed from a directory
# that HOLDS a recorded worktree is that task's environment just as much as one
# composed from inside it - the shape an SDev workspace takes, where several
# repo worktrees sit under the one directory the stack is composed from. That
# upward reach stops at this home's own task-worktree roots, so a stack composed
# from some broad ancestor such as the home directory does not thereby claim
# every task on the machine.
#
# Every match is returned rather than the first, because a reissued worktree
# slot is recorded by every task that has held it.
tasks_owning_path() {  # <working-dir>
  local dir=$1 meta wt holds=0
  [ -n "$dir" ] || return 0
  path_under_task_root "$dir" && holds=1
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue
    if path_under "$dir" "$wt" || { [ "$holds" -eq 1 ] && path_under "$wt" "$dir"; }; then
      basename "$meta" .meta
    fi
  done < "$META_ORDER"
}

# Every task id a compose project name can refer to, most recent first. Falls
# back to the task's SDev slug and to its worktree basename, because those are
# the two names a generated compose project is built from - and a reissued
# worktree slot hands the same basename, so the same project name, to every task
# that has held it.
tasks_owning_name() {  # <stack>
  local stack=$1 meta id norm want
  norm=$(compose_normalize "$stack")
  [ -n "$norm" ] || return 0
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    id=$(basename "$meta" .meta)
    for want in "$id" "$(fm_meta_get "$meta" slug)" "$(basename "$(fm_meta_get "$meta" worktree)" 2>/dev/null || true)"; do
      [ -n "$want" ] || continue
      if [ "$(compose_normalize "$want")" = "$norm" ]; then
        printf '%s\n' "$id"
        break
      fi
    done
  done < "$META_ORDER"
}

# 0 when <stack> names a task this home once ran but no longer has a record of
# under state/. A stack named for a retired task is debris by definition.
stack_names_retired_task() {  # <stack>
  local stack=$1 norm id
  norm=$(compose_normalize "$stack")
  [ -n "$norm" ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(compose_normalize "$id")" = "$norm" ] && return 0
  done < <(retired_task_ids)
  return 1
}

# The task-worktree roots this home demonstrably uses, derived from the parent
# directory of every worktree currently recorded. A stack composed from a
# sibling directory under one of those roots came from a task of this home whose
# worktree has since been returned.
task_worktree_roots() {
  local meta wt
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue
    dirname "$wt"
  done < "$META_ORDER" | sort -u
}

path_under_task_root() {  # <working-dir>
  local dir=$1 root
  [ -n "$dir" ] || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    path_under "$dir" "$root" && return 0
  done < <(task_worktree_roots)
  return 1
}

# What this home can say about one recorded task's endpoint: `live`, `gone`, or
# `unresolved`. `dead` and `missing` are the only two states the fleet's recovery
# contract treats as conclusive (bin/fm-backend.sh's fm_backend_agent_state);
# `alive` is the only conclusive answer in the other direction. Everything else,
# including an unreadable one and a record carrying no endpoint at all, is
# unresolved and never resolves toward removal.
task_endpoint_state() {  # <task-id>
  local id=$1 meta backend target state
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { printf 'gone'; return 0; }
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || { printf 'unresolved'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
  case "$state" in
    dead|missing) printf 'gone' ;;
    alive) printf 'live' ;;
    *) printf 'unresolved' ;;
  esac
}

# Resolve the tasks that claim one stack into a single verdict, in
# OWNER_VERDICT (`live`, `orphaned`, `unresolved`, or empty when nothing claims
# it), OWNER_ID (the task to report it under) and OWNER_TOTAL.
#
# Ambiguity never resolves to orphaned. One live claimant makes the stack live
# however many dead records sit beside it, and a claimant whose endpoint cannot
# be read leaves the stack alone. Only a set every member of which is
# authoritatively gone is debris. Candidates arrive most recent first, so the
# stack is reported under the slot's current occupant rather than a predecessor.
resolve_owners() {  # <task-id>...
  local id state live_id='' gone_id='' unresolved_id=''
  OWNER_VERDICT=
  OWNER_ID=
  OWNER_TOTAL=0
  for id in "$@"; do
    [ -n "$id" ] || continue
    OWNER_TOTAL=$((OWNER_TOTAL + 1))
    state=$(task_endpoint_state "$id")
    case "$state" in
      live) [ -n "$live_id" ] || live_id=$id ;;
      gone) [ -n "$gone_id" ] || gone_id=$id ;;
      *) [ -n "$unresolved_id" ] || unresolved_id=$id ;;
    esac
  done
  [ "$OWNER_TOTAL" -gt 0 ] || return 0
  if [ -n "$live_id" ]; then
    OWNER_VERDICT=live
    OWNER_ID=$live_id
  elif [ -n "$unresolved_id" ]; then
    OWNER_VERDICT=unresolved
    OWNER_ID=$unresolved_id
  else
    OWNER_VERDICT=orphaned
    OWNER_ID=$gone_id
  fi
}

# --- no-go boundary ---------------------------------------------------------
#
# The operator's declared no-go prefixes are a boundary on what agent work may
# touch, and acting on a stack composed from inside one is touching it. A
# malformed declaration refuses the whole sweep rather than sweeping past a
# protection the operator believed was in force.

if ! fm_no_go_prefixes "$CONFIG" >/dev/null; then
  die "the declared no-go paths could not be read, so no stack can be attributed safely"
fi

path_is_no_go() {  # <working-dir>
  local dir=$1
  [ -n "$dir" ] || return 1
  fm_no_go_match "$dir" "$CONFIG" >/dev/null 2>&1
}

# --- classify ---------------------------------------------------------------

awk -F'\t' '$2 != "" { print $2 }' "$CONTAINERS" | awk '!seen[$0]++' > "$STACKS"

TOTAL_CONTAINERS=$(awk 'END { print NR + 0 }' "$CONTAINERS")
LOOSE_CONTAINERS=$(awk -F'\t' '$2 == "" { n++ } END { print n + 0 }' "$CONTAINERS")

ORPHAN_STACKS=0
ORPHAN_CONTAINERS=0
ORPHAN_MEM=0
ORPHAN_VOLUMES=0
ORPHAN_VOL_BYTES=0
LIVE_STACKS=0
UNKNOWN_STACKS=0
: > "$TMP/orphan-plan"
: > "$TMP/kept-volumes"
: > "$TMP/planned-volumes"

printf 'Running stacks (home: %s)\n\n' "$FM_HOME"

while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  ids=$(awk -F'\t' -v s="$stack" '$2 == s { print $1 }' "$CONTAINERS")
  count=$(printf '%s\n' "$ids" | grep -c . || true)
  workdir=$(awk -F'\t' -v s="$stack" '$2 == s && $3 != "" { print $3; exit }' "$CONTAINERS")

  mem=0
  for cid in $ids; do
    part=$(lookup_bytes "$cid" "$MEM")
    mem=$((mem + part))
  done

  volumes=$(stack_volumes "$stack")
  vol_count=$(printf '%s\n' "$volumes" | grep -c . || true)
  vol_bytes=0
  for vol in $volumes; do
    part=$(lookup_bytes "$vol" "$VOLSIZES")
    vol_bytes=$((vol_bytes + part))
  done

  verdict=unknown
  detail=
  # Every task that claims this stack, not the first one found: a reissued
  # worktree slot, and the compose project name derived from it, are recorded by
  # every task that has held them.
  owners=$(tasks_owning_path "$workdir")
  [ -n "$owners" ] || owners=$(tasks_owning_name "$stack")

  if path_is_no_go "$workdir"; then
    verdict=protected
    detail="composed from inside the declared no-go path $FM_NO_GO_MATCH"
  elif [ -n "$owners" ]; then
    # shellcheck disable=SC2086  # task ids are single words; the split is the list
    resolve_owners $owners
    case "$OWNER_VERDICT" in
      live)
        verdict=live
        detail="task $OWNER_ID is still running"
        [ "$OWNER_TOTAL" -le 1 ] || detail="$detail, alongside $((OWNER_TOTAL - 1)) older record(s) of the same directory"
        ;;
      unresolved)
        verdict=unresolved
        detail="task $OWNER_ID claims this stack and its endpoint could not be read"
        [ "$OWNER_TOTAL" -le 1 ] || detail="$detail, so the $OWNER_TOTAL tasks claiming it cannot be told apart"
        ;;
      *)
        verdict=orphaned
        detail="task $OWNER_ID is recorded but its endpoint is gone"
        [ "$OWNER_TOTAL" -le 1 ] || detail="$detail, as is every one of the $OWNER_TOTAL tasks claiming this stack"
        ;;
    esac
  elif stack_names_retired_task "$stack"; then
    verdict=orphaned
    detail="named for task ${stack}, which this home no longer has a record of"
  elif [ -n "$workdir" ] && path_under_task_root "$workdir"; then
    if [ -d "$workdir" ]; then
      detail="composed from $workdir, a task directory no live task claims"
    else
      detail="composed from $workdir, which no longer exists"
    fi
    verdict=orphaned
  else
    if [ -n "$workdir" ]; then
      detail="composed from $workdir, which matches no task of this home"
    else
      detail="no compose working directory recorded"
    fi
  fi

  vol_note=
  [ "$vol_count" -eq 0 ] || vol_note=$(printf ' %d volume(s) %s' "$vol_count" "$(human_bytes "$vol_bytes")")

  case "$verdict" in
    orphaned)
      ORPHAN_STACKS=$((ORPHAN_STACKS + 1))
      ORPHAN_CONTAINERS=$((ORPHAN_CONTAINERS + count))
      ORPHAN_MEM=$((ORPHAN_MEM + mem))
      ORPHAN_VOLUMES=$((ORPHAN_VOLUMES + vol_count))
      ORPHAN_VOL_BYTES=$((ORPHAN_VOL_BYTES + vol_bytes))
      # One planned stack per line: name, then its containers and volumes as
      # space-separated fields, so the acting pass below removes exactly the set
      # that was attributed and reported here.
      printf '%s\t%s\t%s\n' "$stack" \
        "$(printf '%s' "$ids" | tr '\n' ' ')" \
        "$(printf '%s' "$volumes" | tr '\n' ' ')" >> "$TMP/orphan-plan"
      printf '%s\n' "$volumes" | grep . >> "$TMP/planned-volumes" || true
      printf '  ORPHANED  %-28s %2d container(s)  %8s%s  %s\n' \
        "$stack" "$count" "$(human_bytes "$mem")" "$vol_note" "$detail"
      ;;
    live)
      LIVE_STACKS=$((LIVE_STACKS + 1))
      printf '%s\n' "$volumes" | grep . >> "$TMP/kept-volumes" || true
      printf '  live      %-28s %2d container(s)  %8s%s  %s\n' \
        "$stack" "$count" "$(human_bytes "$mem")" "$vol_note" "$detail"
      ;;
    protected|unresolved)
      UNKNOWN_STACKS=$((UNKNOWN_STACKS + 1))
      printf '%s\n' "$volumes" | grep . >> "$TMP/kept-volumes" || true
      printf '  left      %-28s %2d container(s)  %8s%s  %s\n' \
        "$stack" "$count" "$(human_bytes "$mem")" "$vol_note" "$detail"
      ;;
    *)
      UNKNOWN_STACKS=$((UNKNOWN_STACKS + 1))
      printf '%s\n' "$volumes" | grep . >> "$TMP/kept-volumes" || true
      printf '  unknown   %-28s %2d container(s)  %8s%s  %s\n' \
        "$stack" "$count" "$(human_bytes "$mem")" "$vol_note" "$detail"
      ;;
  esac
done < "$STACKS"

if [ "$TOTAL_CONTAINERS" -eq 0 ]; then
  printf '  (no running containers)\n'
fi

# --- unattributed dangling volumes -----------------------------------------
#
# A dangling volume that any classified stack claims is not unattributed - not
# the ones an orphaned stack is already scheduled to free, which would otherwise
# be counted and attempted twice, and not the ones a kept stack owns. A volume
# whose own compose label resolves to a live task is never a candidate however
# unreferenced docker thinks it is, and a label several recorded tasks answer to
# has to clear the same whole-set test the stacks above did.

: > "$TMP/dangling"
DANGLING_COUNT=0
DANGLING_BYTES=0
while IFS= read -r vol; do
  [ -n "$vol" ] || continue
  grep -Fqx "$vol" "$TMP/kept-volumes" 2>/dev/null && continue
  grep -Fqx "$vol" "$TMP/planned-volumes" 2>/dev/null && continue
  project=$(docker volume inspect "$vol" \
    --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null || true)
  case "$project" in
    ''|'<no value>') ;;
    *)
      owners=$(tasks_owning_name "$project")
      if [ -n "$owners" ]; then
        # shellcheck disable=SC2086  # task ids are single words; the split is the list
        resolve_owners $owners
        [ "$OWNER_VERDICT" = orphaned ] || continue
      fi
      ;;
  esac
  printf '%s\n' "$vol" >> "$TMP/dangling"
  DANGLING_COUNT=$((DANGLING_COUNT + 1))
  DANGLING_BYTES=$((DANGLING_BYTES + $(lookup_bytes "$vol" "$VOLSIZES")))
done < "$TMP/dangling-raw"

if [ "$DANGLING_COUNT" -gt 0 ]; then
  printf '\nUnattributed volumes (belong to no stack running now):\n'
  while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    printf '  %-52s %8s\n' "$vol" "$(human_bytes "$(lookup_bytes "$vol" "$VOLSIZES")")"
  done < "$TMP/dangling"
  printf '  %d volume(s) holding %s.\n' "$DANGLING_COUNT" "$(human_bytes "$DANGLING_BYTES")"
  [ "$REMOVE_DANGLING" -eq 1 ] \
    || printf '  Left alone. Pass --remove-dangling-volumes to reclaim them.\n'
fi

printf '\n%d container(s) running in %d stack(s)' \
  "$TOTAL_CONTAINERS" "$(awk 'END { print NR + 0 }' "$STACKS")"
[ "$LOOSE_CONTAINERS" -eq 0 ] || printf ', plus %d outside any stack' "$LOOSE_CONTAINERS"
printf '.\n'
printf '%d orphaned, %d live, %d left alone.\n' \
  "$ORPHAN_STACKS" "$LIVE_STACKS" "$UNKNOWN_STACKS"

pressure=$(host_pressure)
if [ -n "$pressure" ]; then
  printf 'Host memory available %s, swap in use %s.\n' \
    "$(human_bytes "${pressure%% *}")" "$(human_bytes "${pressure##* }")"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$ORPHAN_STACKS" -eq 0 ]; then
    printf 'Nothing to clean.\n'
  else
    printf 'Would clean %d stack(s): stop and remove %d container(s) holding %s, and remove %d volume(s) holding %s.\n' \
      "$ORPHAN_STACKS" "$ORPHAN_CONTAINERS" "$(human_bytes "$ORPHAN_MEM")" \
      "$ORPHAN_VOLUMES" "$(human_bytes "$ORPHAN_VOL_BYTES")"
  fi
  [ "$DANGLING_COUNT" -eq 0 ] || [ "$REMOVE_DANGLING" -eq 0 ] \
    || printf 'Would also remove %d unattributed volume(s) holding %s.\n' \
      "$DANGLING_COUNT" "$(human_bytes "$DANGLING_BYTES")"
  exit 0
fi

if [ "$ORPHAN_STACKS" -eq 0 ] && { [ "$DANGLING_COUNT" -eq 0 ] || [ "$REMOVE_DANGLING" -eq 0 ]; }; then
  printf 'Nothing to clean.\n'
  exit 0
fi

# --- clean ------------------------------------------------------------------
#
# Every removal below names one exact container or volume taken from the plan
# printed above. Nothing is inferred here, and no prune subcommand is used.

FAILED=0
RECLAIMED_DISK=0

remove_volume() {  # <volume> <label>
  local vol=$1 label=$2 bytes
  # Second, independent check: a volume any non-orphaned stack claims is never
  # removed, whatever the earlier filter returned.
  if grep -Fqx "$vol" "$TMP/kept-volumes" 2>/dev/null; then
    printf '    kept    %s (claimed by a stack that is not orphaned)\n' "$vol"
    return 0
  fi
  bytes=$(lookup_bytes "$vol" "$VOLSIZES")
  if docker volume rm "$vol" >/dev/null 2>"$TMP/err"; then
    RECLAIMED_DISK=$((RECLAIMED_DISK + bytes))
    printf '    removed volume %-40s %8s\n' "$vol" "$(human_bytes "$bytes")"
  else
    FAILED=$((FAILED + 1))
    printf '    FAILED  %s volume %s: %s\n' "$label" "$vol" "$(tr '\n' ' ' < "$TMP/err")" >&2
  fi
}

if [ "$ORPHAN_STACKS" -gt 0 ]; then
  printf '\nCleaning %d orphaned stack(s)...\n' "$ORPHAN_STACKS"
  while IFS=$'\t' read -r stack ids volumes; do
    [ -n "$stack" ] || continue
    printf '  %s\n' "$stack"
    stack_disk_before=$RECLAIMED_DISK
    for cid in $ids; do
      docker stop "$cid" >/dev/null 2>"$TMP/err" || {
        FAILED=$((FAILED + 1))
        printf '    FAILED  stop %s: %s\n' "${cid:0:12}" "$(tr '\n' ' ' < "$TMP/err")" >&2
        continue
      }
      # Removing the container is what actually releases its volumes; docker
      # refuses to remove a volume any container still references.
      if docker rm "$cid" >/dev/null 2>"$TMP/err"; then
        printf '    removed container %s\n' "${cid:0:12}"
      else
        FAILED=$((FAILED + 1))
        printf '    FAILED  remove %s: %s\n' "${cid:0:12}" "$(tr '\n' ' ' < "$TMP/err")" >&2
      fi
    done
    for vol in $volumes; do
      remove_volume "$vol" "$stack"
    done
    printf '    reclaimed %s\n' "$(human_bytes "$((RECLAIMED_DISK - stack_disk_before))")"
  done < "$TMP/orphan-plan"
fi

if [ "$REMOVE_DANGLING" -eq 1 ] && [ "$DANGLING_COUNT" -gt 0 ]; then
  printf '\nRemoving %d unattributed volume(s)...\n' "$DANGLING_COUNT"
  while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    remove_volume "$vol" unattributed
  done < "$TMP/dangling"
fi

printf '\nReclaimed %s on disk and %s of memory across %d stack(s).\n' \
  "$(human_bytes "$RECLAIMED_DISK")" "$(human_bytes "$ORPHAN_MEM")" "$ORPHAN_STACKS"

if [ "$FAILED" -gt 0 ]; then
  printf '%d removal(s) failed; nothing was forced.\n' "$FAILED" >&2
  exit 1
fi
