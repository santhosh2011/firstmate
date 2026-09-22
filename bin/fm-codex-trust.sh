#!/usr/bin/env bash
# Pre-register Codex CLI's per-directory trust for the SDev multi-repo
# workspace a codex spawn is about to launch into, so the agent reaches its
# brief instead of wedging on the first-run "Do you trust the contents of
# this directory?" dialog.
#
# Usage: fm-codex-trust.sh <workspace> <repo-path> [<repo-path> ...]
#        fm-codex-trust.sh --prune
#   <workspace>   the SDev multi-repo workspace this codex spawn launches into
#   <repo-path>   one or more per-repo git worktree paths nested inside
#                 <workspace> (absolute, or relative to <workspace>); each
#                 must resolve to an isolated git worktree root, which is the
#                 structural proof that <workspace> is a genuine SDev
#                 workspace and not an arbitrary directory
#   --prune       remove every recorded [projects."<path>"] entry whose path
#                 no longer exists on disk; opt-in only, never run by a spawn
# Prints "trusted: <workspace>" (or "already trusted: <workspace>") on
# success; refuses loudly on anything else.
#
# WHY THIS EXISTS. `../../../bin/fm-spawn.sh`'s SDev workspace provider gives
# every ship or scout task a brand-new directory under
# $SDEV_HOME/projects/<project>/<slug>/ (see resolve_sdev_gate and
# spawn_sdev_workspace in fm-spawn.sh). Codex's own trust dialog persists its
# answer keyed to the EXACT directory path codex was launched in - verified
# against the installed CLI's own config schema below - so a Treehouse pool
# worktree is reused and stays trusted, but every fresh SDev workspace is a
# path codex has never seen and the worker wedges on the dialog before it
# ever reads its brief. `--dangerously-bypass-approvals-and-sandbox` (the flag
# every codex launch already carries) does not cover it, matching the
# equivalent finding for Claude's own trust dialog recorded in
# fm-claude-trust.sh. This script is the codex-side counterpart of that
# script: same problem shape, same "pre-register before launch or refuse the
# spawn" answer, different vendor store format.
#
# THE STORE FORMAT IS TOML, NOT JSON, AND THIS EDITOR IS DELIBERATELY NARROW.
# Inspecting the installed CLI's own config.toml (2026-09, codex-cli 0.154.0)
# shows every project entry as exactly:
#   [projects."<path>"]
#   trust_level = "trusted"
# with a single blank line separating each table from the next, and
# `strings` on the installed binary confirms the enum is `trusted | untrusted`
# (`TrustLeveltrusteduntrusted`). A general TOML parser is not worth writing
# for a two-line table shape, and hand-editing arbitrary TOML risks silently
# reformatting or misplacing content this script does not own (the same file
# also carries `[hooks.state.*]`, `[features]`, and other tables written by
# the vendor). So this never parses the whole document: it does a single
# targeted line scan for the exact `[projects."<path>"]` header, reads the
# lines up to the next `[`-prefixed header or EOF as that table's body, and
# REFUSES rather than guesses the moment that body is not exactly
# `trust_level = "trusted"` - an existing entry recording a human's explicit
# decision (including an explicit "untrusted") is never overridden, matching
# fm-claude-trust.sh's refusal to flip a recorded decline. A brand-new entry
# is appended at EOF; TOML tables are position-independent, so this never
# needs to locate an insertion point among the vendor's own tables.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, same as fm-claude-trust.sh, and it is
# STRUCTURAL rather than a path-prefix policy: SDEV_HOME is itself configurable
# (env var or config/sdev-home), so trusting "looks like it's under SDEV_HOME"
# would trust whatever a mutable value names. Instead, at least one of the
# caller-supplied repo paths must resolve to an isolated git worktree root
# nested inside <workspace> - exactly the shape fm-spawn.sh's own
# validate_spawn_sdev_workspace already requires of every repo in a freshly
# created SDev workspace (sdev_repo_is_isolated). This script never trusts the
# caller's word alone and re-verifies that structural fact itself.
#
# Only the launching user's own store is written: the single projects entry
# for <workspace> in ${CODEX_HOME:-$HOME/.codex}/config.toml, which must be a
# regular file this uid owns; every other table and entry is preserved
# byte-for-byte, via one atomic replacement.
set -u
# See fm-claude-trust.sh's header for why this whole class is cleared before
# any git or `cd` call runs below: CDPATH can redirect a relative `cd`
# operand, and an inherited GIT_DIR/GIT_WORK_TREE pair can make a directory's
# git answers lie about its own shape.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-codex-trust.sh <workspace> <repo-path> [<repo-path> ...]" >&2
  echo "       fm-codex-trust.sh --prune" >&2
  exit 2
}

refuse() { echo "error: refusing to pre-register codex trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# CODEX_HOME resolves the same way the launched codex process resolves it:
# the env var when set, else $HOME/.codex (observed default location; codex
# --help documents CODEX_HOME as the layering root for per-profile config,
# and `codex doctor` reports a "CODEX_HOME available" disk line for it).
# fm-spawn.sh does not forward CODEX_HOME onto the codex launch command, so
# both this registration and the eventual pane resolve it from the same
# ambient environment rather than needing an explicit hand-off.
resolve_codex_home() {
  if [ -n "${CODEX_HOME:-}" ]; then
    case "$CODEX_HOME" in
      /*) ;;
      *) refuse "CODEX_HOME '$CODEX_HOME' is a relative path, so the store a codex worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
    esac
    printf '%s\n' "$CODEX_HOME"
    return 0
  fi
  [ -n "${HOME:-}" ] || refuse "neither CODEX_HOME nor HOME is set, so the store cannot be located"
  printf '%s\n' "$HOME/.codex"
}

resolve_store() {
  local home home_real store store_real
  home=$(resolve_codex_home)
  home_real=$(real_dir "$home") || true
  if [ -z "$home_real" ]; then
    mkdir -p "$home" 2>/dev/null || true
    home_real=$(real_dir "$home") || true
  fi
  [ -n "$home_real" ] || refuse "codex home '$home' does not exist and could not be created"
  store="$home_real/config.toml"
  if [ -L "$store" ]; then
    store_real=$(real_file "$store") || true
    [ -n "$store_real" ] || refuse "'$store' is a symlink whose target cannot be resolved"
    store=$store_real
  fi
  if [ -e "$store" ]; then
    [ -f "$store" ] || refuse "'$store' is not a regular file"
    [ -O "$store" ] || refuse "'$store' is not owned by this user"
    [ -w "$store" ] || refuse "'$store' is not writable"
  fi
  printf '%s\n' "$store"
}

command -v node >/dev/null 2>&1 || refuse "node is required to record codex workspace trust and was not found on PATH"

if [ "${1:-}" = --prune ]; then
  [ "$#" -eq 1 ] || usage
  STORE=$(resolve_store)
  node - "$STORE" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store] = process.argv.slice(2);

const readStore = () => {
  try { return fs.readFileSync(store); } catch (err) { if (err.code === "ENOENT") return null; throw err; }
};
const fingerprint = (buf) => (buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex"));
const unescapeTomlBasicString = (s) => s.replace(/\\(.)/g, (_, c) => c);
const EXPECTED_BODY = 'trust_level = "trusted"';
const HEADER_RE = /^\[projects\."((?:[^"\\]|\\.)*)"\]$/;

const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  const text = original === null ? "" : original.toString("utf8");
  if (text.includes("\r")) {
    throw new Error(`${store} contains carriage returns; unrecognized shape for this narrow TOML editor, refusing to prune it`);
  }
  const lines = text === "" ? [] : text.split("\n");
  const pruned = [];
  const kept = [];
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const m = lines[i].match(HEADER_RE);
    if (!m) { out.push(lines[i]); i += 1; continue; }
    const target = unescapeTomlBasicString(m[1]);
    let j = i + 1;
    const body = [];
    while (j < lines.length && lines[j].charAt(0) !== "[") {
      if (lines[j].trim() !== "") body.push(lines[j]);
      j += 1;
    }
    const recognized = body.length === 1 && body[0] === EXPECTED_BODY;
    const stale = recognized && !fs.existsSync(target);
    if (stale) {
      pruned.push(target);
      // Drop this table AND one immediately-following blank separator line,
      // matching exactly what a prior append of this script (or the vendor)
      // leaves behind, so pruning is the exact inverse of registration.
      let k = j;
      if (k < lines.length && lines[k].trim() === "") k += 1;
      i = k;
      continue;
    }
    kept.push(target);
    for (let l = i; l < j; l += 1) out.push(lines[l]);
    i = j;
  }
  if (pruned.length === 0) return { result: "nothing-stale", pruned, kept };
  const finalText = out.join("\n");
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.config.toml.fm-trust.${unique}`);
  fs.writeFileSync(tmp, finalText, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return { result: "moved" };
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  return { result: "pruned", pruned, kept };
};
try {
  for (let i = 0; i < 3; i += 1) {
    const r = attempt();
    if (r.result === "nothing-stale") { console.log("pruned: none"); process.exit(0); }
    if (r.result === "pruned") {
      for (const p of r.pruned) console.log(`pruned: ${p}`);
      process.exit(0);
    }
    if (r.result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while pruning; refusing to overwrite it`);
      process.exit(1);
    }
  }
  console.error(`error: ${store} could not be pruned after 3 attempts`);
  process.exit(1);
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
NODE
  exit $?
fi

[ "$#" -ge 2 ] || usage

WORKSPACE_ARG=$1
shift
REPO_ARGS=("$@")

WORKSPACE_REAL=$(real_dir "$WORKSPACE_ARG") || true
[ -n "$WORKSPACE_REAL" ] || refuse "workspace '$WORKSPACE_ARG' is not an accessible directory"

STORE=$(resolve_store)
STORE_DIR=$(dirname -- "$STORE")
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true

[ "$WORKSPACE_REAL" != / ] || refuse "'/' is the filesystem root, not an SDev workspace"
[ -z "$STORE_DIR_REAL" ] || [ "$WORKSPACE_REAL" != "$STORE_DIR_REAL" ] \
  || refuse "'$WORKSPACE_REAL' is the codex config directory, not an SDev workspace"
if [ -n "${HOME:-}" ]; then
  HOME_REAL=$(real_dir "$HOME") || true
  [ "$WORKSPACE_REAL" != "${HOME_REAL:-}" ] || refuse "'$WORKSPACE_REAL' is the home directory, not an SDev workspace"
fi

# Structural proof that <workspace> is a genuine SDev multi-repo workspace:
# at least one caller-named repo path resolves to its OWN isolated git
# worktree root, nested inside <workspace> - never taken on the caller's word.
for repo in "${REPO_ARGS[@]}"; do
  case "$repo" in
    /*) candidate=$repo ;;
    *) candidate="$WORKSPACE_REAL/$repo" ;;
  esac
  candidate_real=$(real_dir "$candidate") || true
  [ -n "$candidate_real" ] || refuse "repo path '$repo' is not an accessible directory under workspace '$WORKSPACE_REAL'"
  case "$candidate_real" in
    "$WORKSPACE_REAL"/*) ;;
    *) refuse "repo path '$repo' resolves to '$candidate_real', outside workspace '$WORKSPACE_REAL'" ;;
  esac
  repo_top=$(git -C "$candidate_real" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$repo_top" ] || refuse "repo path '$repo' at '$candidate_real' is not inside a git repository; '$WORKSPACE_REAL' does not look like a genuine SDev multi-repo workspace"
  repo_top_real=$(real_dir "$repo_top") || true
  [ "$repo_top_real" = "$candidate_real" ] \
    || refuse "repo path '$repo' at '$candidate_real' is not an isolated git worktree root (its root is '${repo_top_real:-unresolvable}')"
done

MANUAL_CMD="cd $(shell_quote "$WORKSPACE_REAL") && codex"

# Stock macOS Bash 3.2 mis-parses a here-document nested lexically inside a
# command substitution's parentheses, so this heredoc is a plain statement in
# its own function rather than directly inside `OUT=$(...)` below.
record_trust() {
  node - "$STORE" "$WORKSPACE_REAL" "$MANUAL_CMD" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, target, manualCmd] = process.argv.slice(2);

if (/[\x00-\x1f\x7f]/.test(target)) {
  console.error(`error: workspace path '${target}' contains a control character, which this script's TOML writer does not support`);
  process.exit(1);
}
const escaped = target.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
const header = `[projects."${escaped}"]`;
const EXPECTED_BODY = 'trust_level = "trusted"';

const readStore = () => {
  try { return fs.readFileSync(store); } catch (err) { if (err.code === "ENOENT") return null; throw err; }
};
const fingerprint = (buf) => (buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex"));

const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  const text = original === null ? "" : original.toString("utf8");
  if (text.includes("\r")) {
    throw new Error(`${store} contains carriage returns; unrecognized shape for this narrow TOML editor, refusing to touch it. Accept the dialog by hand instead: ${manualCmd}`);
  }
  const lines = text === "" ? [] : text.split("\n");
  let headerIdx = -1;
  for (let i = 0; i < lines.length; i += 1) {
    if (lines[i] === header) {
      if (headerIdx !== -1) {
        throw new Error(`${store} has more than one ${header} table; unrecognized shape, refusing to touch it. Accept the dialog by hand instead: ${manualCmd}`);
      }
      headerIdx = i;
    }
  }
  if (headerIdx !== -1) {
    let j = headerIdx + 1;
    const body = [];
    while (j < lines.length && lines[j].charAt(0) !== "[") {
      if (lines[j].trim() !== "") body.push(lines[j]);
      j += 1;
    }
    if (body.length === 1 && body[0] === EXPECTED_BODY) return "already-trusted";
    throw new Error(`${store}'s ${header} table has an unrecognized shape (expected exactly '${EXPECTED_BODY}'); refusing to override a recorded decision. Accept the dialog by hand instead: ${manualCmd}`);
  }
  let prefix = text;
  if (prefix !== "" && !prefix.endsWith("\n")) prefix += "\n";
  if (prefix !== "" && !prefix.endsWith("\n\n")) prefix += "\n";
  const finalText = `${prefix}${header}\n${EXPECTED_BODY}\n\n`;
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.config.toml.fm-trust.${unique}`);
  fs.writeFileSync(tmp, finalText, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = fs.readFileSync(store, "utf8");
  const backLines = back.split("\n");
  const idx = backLines.indexOf(header);
  return idx !== -1 && backLines[idx + 1] === EXPECTED_BODY ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "already-trusted") { console.log("already-trusted"); process.exit(0); }
    if (result === "recorded") { console.log("recorded"); process.exit(0); }
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
  console.error(`error: ${store} did not retain trust for ${target} after 3 attempts`);
  process.exit(1);
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
NODE
}

if ! OUT=$(record_trust); then
  echo "$OUT" >&2
  refuse "could not record trust for '$WORKSPACE_REAL' in '$STORE'"
fi

case "$OUT" in
  already-trusted) echo "already trusted: $WORKSPACE_REAL" ;;
  *) echo "trusted: $WORKSPACE_REAL" ;;
esac
