#!/usr/bin/env bash
# fm-stack-sweep.sh - find, and optionally stop, app stacks that outlived the
# task that started them.
#
# Cleanup returns a task's worktree and retires its records, but it never stops
# what the task's own code started. A task that brought a docker stack up leaves
# that stack running after the work is merged and the task is gone, so the
# containers accumulate silently across a working day until the box is out of
# memory and the captain's review surfaces start dying. Recovering by hand means
# re-deriving, every single time, which of the running stacks are still backing
# live work and which are debris - which is exactly the judgement this script
# exists to record once, so the captain can re-run it instead of re-reasoning it.
#
# Attribution is deliberately one-directional. A stack is acted on only on
# positive evidence that it belongs to THIS home and that its task is gone;
# every stack that cannot be attributed that confidently is reported and left
# alone. Guessing wrong in the other direction means killing the environment the
# captain is testing in, which is the failure that actually costs him work.
#
# Three escalating modes, each one the captain has to type for himself:
#
#   fm-stack-sweep.sh
#     Report only. Changes nothing at all. Lists every running stack, how it was
#     attributed, its memory, and the disk its volumes hold.
#
#   fm-stack-sweep.sh --stop
#     Stops the containers of the orphaned stacks, and only those. Removes
#     nothing, so every stack stopped here comes back with `docker start`.
#
#   fm-stack-sweep.sh --stop --remove-volumes
#     The one destructive path, and the only one that can lose data. It reclaims
#     the disk held by the orphaned stacks' volumes. Docker will not release a
#     volume while any container still references it, so this necessarily also
#     removes those same orphaned stacks' own containers - stopping them is not
#     enough. It is refused without --stop precisely so the destructive mode
#     cannot be reached by adding one flag to a habit.
#
# A volume is removed only when it carries the compose project label of a stack
# this run attributed as orphaned. Volumes belonging to a live, unknown or
# protected stack are excluded by that filter and then checked a second time
# against the live set before any removal, because "never destroy the captain's
# running environment" is worth paying for twice. Removal is never forced: a
# volume docker still considers in use is reported and left.
#
# Usage:
#   fm-stack-sweep.sh                       report; change nothing
#   fm-stack-sweep.sh --stop                stop the orphaned stacks
#   fm-stack-sweep.sh --stop --remove-volumes
#                                           also remove those stacks' containers
#                                           and volumes to reclaim their disk
#   fm-stack-sweep.sh --help                print this usage
#
# Exit status: 0 when the sweep completed, 1 when docker is unavailable, when
# the declared no-go paths could not be read, or when a requested stop or
# removal failed. An unreadable boundary is never reported as an empty sweep.
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

STOP=0
REMOVE_VOLUMES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stop) STOP=1; shift ;;
    --remove-volumes) REMOVE_VOLUMES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ "$REMOVE_VOLUMES" -eq 1 ] && [ "$STOP" -eq 0 ]; then
  die "--remove-volumes requires --stop; docker cannot release a volume while its stack is running, and the destructive mode is deliberately two typed flags"
fi

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

# --- this home's task records ----------------------------------------------
#
# Live tasks come from state/<id>.meta. Torn-down tasks leave no meta, so a
# stack named for a task that once existed here is attributed through the
# durable per-task data/<id>/ directory that survives cleanup.

live_meta_ids() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    basename "$meta" .meta
  done
}

known_task_ids() {
  local dir
  live_meta_ids
  for dir in "$DATA"/*/; do
    [ -d "$dir" ] || continue
    basename "$dir"
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

# The task id whose recorded worktree contains <path>, or nothing. This is the
# strongest attribution available: it ties a running stack to a task through the
# directory the stack was actually composed from.
task_owning_path() {  # <working-dir>
  local dir=$1 meta id wt
  [ -n "$dir" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue
    if path_under "$dir" "$wt"; then
      id=$(basename "$meta" .meta)
      printf '%s\n' "$id"
      return 0
    fi
  done
}

# The task id a compose project name refers to, or nothing. Falls back to the
# task's SDev slug and to its worktree basename, because those are the two names
# a generated compose project is built from.
task_owning_name() {  # <stack>
  local stack=$1 meta id norm want
  norm=$(compose_normalize "$stack")
  [ -n "$norm" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    for want in "$id" "$(fm_meta_get "$meta" slug)" "$(basename "$(fm_meta_get "$meta" worktree)" 2>/dev/null || true)"; do
      [ -n "$want" ] || continue
      if [ "$(compose_normalize "$want")" = "$norm" ]; then
        printf '%s\n' "$id"
        return 0
      fi
    done
  done
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
  done < <(known_task_ids)
  return 1
}

# The task-worktree roots this home demonstrably uses, derived from the parent
# directory of every worktree currently recorded. A stack composed from a
# sibling directory under one of those roots came from a task of this home whose
# worktree has since been returned.
task_worktree_roots() {
  local meta wt
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue
    dirname "$wt"
  done | sort -u
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

# A recorded task counts as live unless its endpoint is authoritatively gone.
# `dead` and `missing` are the only two states the fleet's recovery contract
# treats as conclusive (bin/fm-backend.sh's fm_backend_agent_state); every other
# answer, including an unreadable one, keeps the stack.
task_endpoint_absent() {  # <task-id>
  local id=$1 meta backend target state
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
  case "$state" in
    dead|missing) return 0 ;;
    *) return 1 ;;
  esac
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
: > "$TMP/orphan-ids"
: > "$TMP/orphan-volumes"
: > "$TMP/kept-volumes"

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
  owner=$(task_owning_path "$workdir")
  [ -n "$owner" ] || owner=$(task_owning_name "$stack")

  if path_is_no_go "$workdir"; then
    verdict=protected
    detail="composed from inside the declared no-go path $FM_NO_GO_MATCH"
  elif [ -n "$owner" ]; then
    if task_endpoint_absent "$owner"; then
      verdict=orphaned
      detail="task $owner is recorded but its endpoint is gone"
    else
      verdict=live
      detail="task $owner is still running"
    fi
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
      printf '%s\n' "$ids" | grep . >> "$TMP/orphan-ids" || true
      printf '%s\n' "$volumes" | grep . >> "$TMP/orphan-volumes" || true
      printf '  ORPHANED  %-28s %2d container(s)  %8s%s  %s\n' \
        "$stack" "$count" "$(human_bytes "$mem")" "$vol_note" "$detail"
      ;;
    live)
      LIVE_STACKS=$((LIVE_STACKS + 1))
      printf '%s\n' "$volumes" | grep . >> "$TMP/kept-volumes" || true
      printf '  live      %-28s %2d container(s)  %8s%s  %s\n' \
        "$stack" "$count" "$(human_bytes "$mem")" "$vol_note" "$detail"
      ;;
    protected)
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

if [ "$ORPHAN_STACKS" -eq 0 ]; then
  printf 'Nothing to stop.\n'
  exit 0
fi

if [ "$STOP" -eq 0 ]; then
  printf 'Would stop %d container(s) holding %s.\n' \
    "$ORPHAN_CONTAINERS" "$(human_bytes "$ORPHAN_MEM")"
  if [ "$ORPHAN_VOLUMES" -gt 0 ]; then
    printf 'Their %d volume(s) hold %s on disk, which --stop alone does NOT reclaim.\n' \
      "$ORPHAN_VOLUMES" "$(human_bytes "$ORPHAN_VOL_BYTES")"
    printf 'Re-run with --stop, or --stop --remove-volumes to also reclaim that disk.\n'
  else
    printf 'Re-run with --stop to do it.\n'
  fi
  exit 0
fi

# Stop exactly the containers listed above, by id, and nothing else.
printf '\nStopping %d container(s)...\n' "$ORPHAN_CONTAINERS"
STOP_FAILED=0
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  if docker stop "$cid" >/dev/null 2>"$TMP/stop.err"; then
    printf '  stopped %s\n' "${cid:0:12}"
  else
    STOP_FAILED=$((STOP_FAILED + 1))
    printf '  FAILED  %s: %s\n' "${cid:0:12}" "$(tr '\n' ' ' < "$TMP/stop.err")" >&2
  fi
done < "$TMP/orphan-ids"

if [ "$REMOVE_VOLUMES" -eq 0 ]; then
  if [ "$STOP_FAILED" -gt 0 ]; then
    printf 'Stopped %d of %d container(s); %d could not be stopped.\n' \
      "$((ORPHAN_CONTAINERS - STOP_FAILED))" "$ORPHAN_CONTAINERS" "$STOP_FAILED"
    exit 1
  fi
  printf 'Stopped %d container(s), releasing %s.\n' \
    "$ORPHAN_CONTAINERS" "$(human_bytes "$ORPHAN_MEM")"
  if [ "$ORPHAN_VOLUMES" -gt 0 ]; then
    printf 'Left %d volume(s) holding %s; --stop --remove-volumes reclaims that disk.\n' \
      "$ORPHAN_VOLUMES" "$(human_bytes "$ORPHAN_VOL_BYTES")"
  fi
  exit 0
fi

# --- destructive path -------------------------------------------------------
#
# Only reachable with both flags typed. The containers removed here are the
# exact ids stopped above; the volumes are the exact names the report listed,
# re-checked against every volume belonging to a stack this run did NOT
# attribute as orphaned.

printf '\nRemoving %d orphaned container(s) so their volumes can be released...\n' \
  "$ORPHAN_CONTAINERS"
RM_FAILED=0
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  docker rm "$cid" >/dev/null 2>"$TMP/rm.err" || {
    RM_FAILED=$((RM_FAILED + 1))
    printf '  FAILED  %s: %s\n' "${cid:0:12}" "$(tr '\n' ' ' < "$TMP/rm.err")" >&2
  }
done < "$TMP/orphan-ids"

printf 'Removing %d volume(s) holding %s...\n' \
  "$ORPHAN_VOLUMES" "$(human_bytes "$ORPHAN_VOL_BYTES")"
RECLAIMED=0
VOL_FAILED=0
while IFS= read -r vol; do
  [ -n "$vol" ] || continue
  # Second, independent check: a volume that any non-orphaned stack claims is
  # never removed, whatever the label filter returned.
  if grep -Fqx "$vol" "$TMP/kept-volumes" 2>/dev/null; then
    printf '  kept    %s (claimed by a stack that is not orphaned)\n' "$vol"
    continue
  fi
  bytes=$(lookup_bytes "$vol" "$VOLSIZES")
  if docker volume rm "$vol" >/dev/null 2>"$TMP/vol.err"; then
    RECLAIMED=$((RECLAIMED + bytes))
    printf '  removed %-44s %8s\n' "$vol" "$(human_bytes "$bytes")"
  else
    VOL_FAILED=$((VOL_FAILED + 1))
    printf '  FAILED  %s: %s\n' "$vol" "$(tr '\n' ' ' < "$TMP/vol.err")" >&2
  fi
done < "$TMP/orphan-volumes"

printf 'Reclaimed %s on disk and %s of memory across %d stack(s).\n' \
  "$(human_bytes "$RECLAIMED")" "$(human_bytes "$ORPHAN_MEM")" "$ORPHAN_STACKS"

if [ "$STOP_FAILED" -gt 0 ] || [ "$RM_FAILED" -gt 0 ] || [ "$VOL_FAILED" -gt 0 ]; then
  printf '%d container(s) could not be stopped, %d could not be removed, %d volume(s) could not be removed.\n' \
    "$STOP_FAILED" "$RM_FAILED" "$VOL_FAILED" >&2
  exit 1
fi
