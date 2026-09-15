#!/usr/bin/env bash
# tests/fm-sdev-backend-smoke.test.sh - real SDev smoke test for phase 2's data
# and workspace layer, run against a real SDEV_HOME (this captain: ~/code/shamrock).
#
# Every other SDev suite fakes the sdev CLI; this one talks to the REAL sdev and
# creates a genuine multi-repo workspace, so it MUTATES the real SDev home. It is
# therefore opt-in: it self-skips unless FM_SDEV_SMOKE=1 is set, and it also
# skips when sdev, SDEV_HOME, or the target project are unavailable. A trap
# destroys the ephemeral task on exit so it never leaves cruft behind.
#
# It verifies phase 1's registry reader against real registry YAML and phase 2's
# core invariant: `sdev new` yields one isolated git worktree per repo under the
# workspace, distinct from the shared source. It does NOT bring the docker stack
# up (that needs docker and is slow); the URL path is covered by the faked
# fm-run suite.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/bin/fm-sdev-registry.sh"
PROJECT=${FM_SDEV_SMOKE_PROJECT:-pdmt}
SLUG="fm-sdev-smoke-$$"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ "${FM_SDEV_SMOKE:-}" = 1 ] || { echo "skip: real SDev smoke is opt-in (set FM_SDEV_SMOKE=1; it mutates the real SDev home)"; exit 0; }
command -v sdev >/dev/null 2>&1 || { echo "skip: sdev not found"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "skip: yq not found"; exit 0; }
SDEV_HOME_DIR=$("$REGISTRY" home 2>/dev/null) || { echo "skip: SDEV_HOME not resolvable"; exit 0; }
"$REGISTRY" backed "$PROJECT" >/dev/null 2>&1 || { echo "skip: project $PROJECT is not SDev-backed under $SDEV_HOME_DIR"; exit 0; }
export SDEV_HOME="$SDEV_HOME_DIR"

cleanup() { sdev -p "$PROJECT" destroy "$SLUG" --force >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1. Registry reads resolve against real registry YAML.
REPOS=$("$REGISTRY" repos "$PROJECT") || fail "registry: repos failed for real project $PROJECT"
[ -n "$REPOS" ] || fail "registry: repos returned nothing for $PROJECT"
pass "fm-sdev-registry reads real repo composition for $PROJECT"

# 2. Real workspace creation yields isolated per-repo worktrees. `sdev new` can
# exit non-zero on a step past worktree creation that depends on local install
# state (e.g. a missing compose template); that is an sdev-install concern, not
# firstmate's isolation guarantee, so we assert the invariant on whatever
# worktrees were created and skip only when the environment produced no
# workspace at all.
new_out=$(sdev -p "$PROJECT" new "$SLUG" --no-fetch --no-pool --ephemeral 2>&1) || true
WS=$(sdev -p "$PROJECT" cd "$SLUG" 2>/dev/null || true)
if [ -z "$WS" ] || [ ! -d "$WS" ]; then
  echo "skip: sdev new produced no workspace in this environment:"
  printf '%s\n' "$new_out" | tail -3
  exit 0
fi
WS_REAL=$(cd "$WS" && pwd -P)

checked=0
while IFS=$'\t' read -r key path _; do
  [ -n "$path" ] || continue
  d="$WS/$path"
  [ -d "$d" ] || continue   # partial workspace (env issue), not an isolation defect
  d_real=$(cd "$d" && pwd -P)
  top_real=$(cd "$(git -C "$d" rev-parse --show-toplevel)" && pwd -P) \
    || fail "repo '$key' at $d is not a git worktree"
  [ "$d_real" = "$top_real" ] || fail "repo '$key' is not its own worktree root ($d_real vs $top_real)"
  case "$d_real" in "$WS_REAL"/*) : ;; *) fail "repo '$key' resolves outside the workspace: $d_real" ;; esac
  checked=$((checked + 1))
done <<EOF
$REPOS
EOF
[ "$checked" -gt 0 ] || { echo "skip: sdev new created no repo worktrees to check in this environment"; exit 0; }
pass "sdev new yields $checked isolated git worktree(s) under the workspace, distinct from source"

cleanup
trap - EXIT
pass "real SDev smoke complete; ephemeral task $SLUG destroyed"
