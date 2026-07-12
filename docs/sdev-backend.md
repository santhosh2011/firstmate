# SDev workspace backend

SDev lets firstmate manage a multi-repo feature as one task.
A project marked SDev-backed points at a `SDEV_HOME` (this captain: `/Users/santhosh/code/shamrock`); its tasks become multi-repo SDev workspaces instead of single treehouse worktrees.
Treehouse stays the default, so a project that is not SDev-backed behaves exactly as before, and a firstmate with no `SDEV_HOME` sees no change at all.
SDev owns the workspace (the multi-repo worktrees, the generated docker stack, ports, run/test); firstmate owns dispatch, supervision, review, shipping, and teardown safety.
Firstmate calls the `sdev` CLI; it does not reimplement it.

## Sources and workspaces (`core/` vs `projects/`)

`$SDEV_HOME/core/` holds each repo's shared source checkout and the registry at `core/projects.d/*.yml`; it is the source of truth for repo composition and is READ-ONLY to firstmate and crewmates, exactly like `projects/<name>` clones are today.
`$SDEV_HOME/projects/<project>/<slug>/` is a per-task workspace holding one git worktree per repo; that workspace is the only place a crewmate writes.
The AGENTS.md never-write-to-a-project rule therefore extends from `projects/<name>` to `$SDEV_HOME/core/`.
Per-repo worktree isolation is asserted at spawn so no workspace repo resolves back onto its `core/` source.

## Task lifecycle

A multi-repo task runs the same firstmate lifecycle as a single-repo task, with each step spanning the workspace's repos:

1. Start - `bin/fm-spawn.sh` creates the workspace with `sdev new <slug>` and launches one crewmate across all its repos (Workspace provider, below).
2. Run and test - `bin/fm-run.sh <id> up|url|open` brings the stack up and surfaces a live URL so the captain exercises the feature before review (Run layer, below).
3. Combined review - `bin/fm-review-diff.sh <id>` shows one diff across every changed repo (Combined review, below).
4. All-or-nothing ship - `bin/fm-ship-multi.sh <id> --merge` lands every changed repo atomically in dependency order, or nothing (All-or-nothing ship, below).
5. Teardown - `bin/fm-teardown.sh <id>` refuses until every repo has landed, then archives the workspace with `sdev end` (Teardown and recovery, below).

A monorepo is the N=1 case of this same lifecycle.

## Configuration

SDEV_HOME resolves from the `SDEV_HOME` env var first, then the first non-empty, non-comment line of a local, gitignored `config/sdev-home` file.
When neither resolves to an existing directory, no project is SDev-backed and every path stays treehouse - the feature is inert by default.
A project is SDev-backed when `$SDEV_HOME/core/projects.d/<name>.yml` exists.
Landing policy (delivery mode plus yolo) is not in SDev's registry YAML; it lives in firstmate's `config/landing-policy.json` overlay (see `bin/fm-landing-policy.sh` and `docs/examples/landing-policy.json`).

## Registry read - `bin/fm-sdev-registry.sh`

The reader parses `$SDEV_HOME/core/projects.d/<name>.yml` with mikefarah `yq` v4 (which SDev already requires).

- `fm-sdev-registry.sh backed <project>` exits 0 when the project is SDev-backed, exit 3 (silent) otherwise.
- `fm-sdev-registry.sh repos <project>` prints one TAB-separated line per repo: `<key>\t<path>\t<default_base>\t<compose_role>`, in registry document order.
- `fm-sdev-registry.sh home` prints the resolved SDEV_HOME, or exit 3 (silent) when it cannot be resolved.

The `path` field is the repo's worktree directory name inside a task workspace.
A monorepo is the N=1 case of the same shape.

## Workspace provider - `bin/fm-spawn.sh`

For a ship or scout task whose project is SDev-backed, fm-spawn takes the SDev path instead of `treehouse get`.
It creates the workspace with `sdev -p <project> new <slug>` (slug is the task id), resolves the workspace directory with `sdev -p <project> cd <slug>`, and places the crewmate there.
The workspace is `$SDEV_HOME/projects/<project>/<slug>/`, holding one git worktree per repo at `<workspace>/<repo path>`, each on branch `task/<slug>`.
Before launch, fm-spawn asserts per-repo isolation: each repo directory must be its own git worktree root nested inside the workspace, so no repo resolves onto its shared source.
Orca is excluded (it owns its own worktree) and secondmate spawns never take this path.
The meta records `sdev_home=`, `slug=`, and `repos=` (the repo keys) in addition to the usual fields; `project=` and `worktree=` stay, so anything that reads a treehouse task's meta is unaffected.
Downstream steps resolve per-repo detail from the registry via `sdev_home` plus `slug`, rather than duplicating it into meta.

Current limitation: the caller still passes an existing `projects/<name>` directory (the pane starts there and cd's into the workspace); retiring the duplicate flat clones is future work.

## Run layer - `bin/fm-run.sh`

`fm-run.sh <id> up` brings the task stack up with `sdev up <slug>`.
`fm-run.sh <id> url` prints the task's live URL, resolved from `sdev ls --json` for the task `<project>/<slug>`, or exits non-zero when there is no live URL yet.
`fm-run.sh <id> open` opens the URL in a browser with `sdev open <slug>`.
This URL read is distinct from the watcher's pane-endpoint liveness check: it reports whether the stack serves a URL, not whether the crewmate pane is alive.

## Teardown and recovery - `bin/fm-teardown.sh`, `bin/fm-session-start.sh`

For an SDev task (meta carries `slug=`) teardown applies the landed-work gate PER REPO: every changed repo's `task/<slug>` branch must be landed - a `landed_<key>=` marker recorded at ship, its content already in the repo's default, or (local-only) merged into its local base - and clean, or teardown refuses and names the offending repos.
Any dirty repo refuses.
On success it archives the workspace with `sdev end <slug>` instead of returning a treehouse worktree.
`--force` is the explicit discard path, exactly as for a single-repo task.
The single-repo teardown gate (a treehouse `project=` task) is unchanged.
On restart, the session-start fleet digest surfaces an SDev task's `slug`, `repos`, workspace, and `sdev_home`, so recovery reconstructs the multi-repo shape from meta rather than assuming a single `project=`/`worktree=`.

## Combined review - `bin/fm-review-diff.sh`

For an SDev task (meta carries `slug=`), `fm-review-diff.sh <id>` resolves the workspace's per-repo worktrees from the registry and emits one combined diff across the changed repos.
Each repo is compared against its OWN authoritative base - its `default_base` from the registry, which may differ per repo (one repo on `origin/develop`, another on `origin/main`) - fetched from origin when the repo is remote-backed, else the local base branch.
Each changed repo is printed under a `===== repo: <key> (base <base>) =====` header; untouched repos are excluded.
A treehouse task (meta carries `project=` and no `slug=`) takes the unchanged single-repo path.

## All-or-nothing ship - `bin/fm-ship-multi.sh`

`fm-ship-multi.sh <id>` reports the ship plan and readiness across the task's changed repos; `--merge` lands them.
A repo is CHANGED when its `task/<slug>` branch differs from its own base; each changed repo's landing mode comes from `bin/fm-landing-policy.sh`.
Every changed repo must be a ready landing candidate before ANY repo lands: a remote repo (no-mistakes / direct-PR) needs a recorded `pr_<key>=<url>` whose PR is OPEN, APPROVED, and green; a local-only repo needs its `task/<slug>` branch to fast-forward onto its base.
Partial-failure policy: NEVER partial-merge - if any changed repo is not ready, nothing lands and the blocking repo is reported.
Ready repos land in dependency order: the overlay's `order` array for the project (via `fm-landing-policy.sh order <project>`), or common-first-then-registry-order when unset.
A remote repo lands by squash-merging its PR with `gh-axi`; a local-only repo lands by a local fast-forward of its base branch in the source worktree.
Each landed repo records a `landed_<key>=<url|local>` marker in meta for teardown.
The single-repo ship path (`fm-pr-check.sh` / `fm-pr-merge.sh` for a treehouse task) is untouched.

## Multi-repo ship brief - `bin/fm-brief.sh --sdev`

`fm-brief.sh <id> <project> --sdev` scaffolds a multi-repo ship brief: one git worktree per repo (resolved from the registry), each on branch `task/<slug>`, with a combined definition of done across the repos.
It is ship-only and requires the project to be SDev-backed.
The single-repo ship brief is unchanged when the flag is absent.

## Empirical verification

Date: 2026-07-12.
Tools: mikefarah `yq` version v4.53.2; `sdev` at `/Users/santhosh/.local/bin/sdev`; SDEV_HOME `/Users/santhosh/code/shamrock`.
The opt-in real smoke `tests/fm-sdev-backend-smoke.test.sh` (guarded by `FM_SDEV_SMOKE=1`, since it mutates the real SDev home) was run and passed.

Registry read against the real registry (monorepo pdmt, then multi-repo scdi):

```
$ SDEV_HOME=~/code/shamrock bin/fm-sdev-registry.sh repos pdmt
chips	edm-apps-obs-pdmt-chips-ui	develop	app

$ SDEV_HOME=~/code/shamrock bin/fm-sdev-registry.sh repos scdi
api	cognito_ai_scdi_api	develop	api
ui	edm-apps-ai-observability	develop	ui
common	common	develop	common

$ SDEV_HOME=~/code/shamrock bin/fm-sdev-registry.sh home
/Users/santhosh/code/shamrock
```

Real workspace isolation (the smoke, monorepo pdmt):

```
$ FM_SDEV_SMOKE=1 SDEV_HOME=~/code/shamrock tests/fm-sdev-backend-smoke.test.sh
ok - fm-sdev-registry reads real repo composition for pdmt
ok - sdev new yields 1 isolated git worktree(s) under the workspace, distinct from source
ok - real SDev smoke complete; ephemeral task fm-sdev-smoke-37157 destroyed
```

The ephemeral task is destroyed on exit; `sdev -p pdmt ls` showed no leftover smoke task after the run.

Known environment gotcha (not a firstmate defect): on this box `sdev new` creates the isolated worktree ("worktrees created: chips") and then exits non-zero at a later step with `error: open /Users/santhosh/.local/bin/templates/compose.tmpl: no such file or directory`.
That is a missing sdev compose template in the local install, past the worktree-creation step firstmate relies on for isolation.
The smoke asserts the isolation invariant on the created worktree and skips gracefully when the environment produces no workspace at all.
