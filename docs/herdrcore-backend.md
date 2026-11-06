# Herdr desktop runtime backend

`herdrcore` is an experimental session provider for the Herdr desktop app.
It uses `hc` for herdr-core terminals and `herdr-app` for spaces; it does not use the older `herdr` runtime CLI.
Every local crew worker and secondmate gets a separate space and an initial terminal.
Treehouse still supplies crew worktrees, while secondmates start in their existing homes.

## Setup and selection

Install `hc` and `herdr-app` on PATH and open the Herdr desktop app before spawning.
The adapter also requires `jq` and Firstmate's normal toolchain, including Treehouse for crew worktrees.
Select `herdrcore` explicitly with `config/backend`, `FM_BACKEND=herdrcore`, or an authorized `--backend herdrcore` spawn.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns precedence and metadata fields.
No runtime auto-detection is enabled: `HC_TERMINAL_ID` and `__CFBundleIdentifier=dev.herdr.app` still need live verification, including nested multiplexer behavior.
The adapter issues no core or desktop application startup, shutdown, update, or restart commands.

## Ownership and operation

`bin/backends/herdrcore.sh` owns command arguments, creation receipts, label bindings, and cleanup mechanics.
Space titles show the plain task ID, such as `sm-planner`, without the `fm-` prefix or home hash.
Different homes may display identical titles; ownership remains bound to the physical home, task label, and random nonce, with the home hash retained in hidden terminal labels and private receipts.
A successful creation records the exact space, tab, and terminal and adds home, task, and random ownership labels to the terminal.
Private receipts under the creating home's `state/herdrcore-endpoints/` bind those identities across spawn failure and cleanup retries.
Cleanup retains receipts as tombstones so a later teardown retry remains idempotent.
Existing spaces with long titles remain recognized and clean up using the title recorded in their original receipt.
Preserve them with the home state; losing a receipt refuses endpoint operations rather than adopting a same-named space.
A failed launch prints the command or validation that failed on stderr; failures after space creation identify retained receipts when available, so inspect the app and receipt before retrying.

Reads, input, and cleanup require the receipt and matching terminal labels.
The adapter never rebinds a stale terminal address by title or chooses the currently focused terminal.
Cleanup refuses a renamed space, an extra tab, a moved terminal, or unrelated terminals carrying the space's label.
It confirms space closure only for its exact recorded creation and preserves the receipt when a close fails.
As with other terminal applications, a concurrent manual change between validation and a command remains a race; avoid rearranging a task space during cleanup.

`hc send` pastes and submits in one call, so launch and typed steering never append another Enter or repeat submitted text.
An explicit blocked refusal can reflect an agent's conversational question rather than an interactive dialog.
After that refusal, the adapter reads the owned terminal again and retries once with force only when the shared composer classifier proves the input empty.
Visible dialogs, pending drafts, unreadable captures, and ambiguous composer states refuse with a diagnostic; other send failures never trigger force.
As with other rendered input guards, a manual change between the screen read and input remains a race.
The native key interface provides Enter, Escape, Ctrl-C, and Ctrl-U; the additional `Interrupt` key uses `hc interrupt`, whose stop key depends on the running program.
Routine text steering still uses the durable inbox; only the notification is typed, and secondmate reply tracking remains on the shared pending-reply path.
Capture uses `hc read`, with the result trimmed locally to the requested number of lines.
Worktree discovery reads the live `foreground.cwd`, never the terminal's launch directory.

Native status can inform busy polling, but a status report alone never proves a live agent.
Recovery requires a successful terminal inventory and binding check; finished and absent endpoints are distinct from unavailable or contradictory inventory.
A live foreground process is classified through Firstmate's shared process classifier.
Shell-only or unrecognized process evidence remains ambiguous, so shell-only secondmate recovery and stop/relaunch through `fm-control` are not verified for this backend.
There is no native event-push integration.

## Verification and live smoke test

Run the offline regression with `bin/fm-test-run.sh tests/fm-backend-herdrcore.test.sh`.
It supplies both tools as strict PATH stubs and never contacts the live app.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdrcore) records the verification boundary.

Before relying on the backend, a maintainer should use a disposable task and confirm:

1. Installed `hc --help`, `herdr-app --help`, and `herdr-app commands` agree with the adapter's CLI contract, and `herdr-app ls`, `hc ls --all --json`, and `hc get` JSON agree with its strict parsers.
2. A crew launch creates one space, enters its isolated worktree, starts the selected interactive harness, and records matching space, tab, terminal, and receipt identities.
3. A local secondmate launch creates another space in its home, and a steer arrives through its inbox with pending-reply delivery recorded.
4. Capture, Enter, Escape, Ctrl-U, interrupt, and single-submit text delivery work for each intended harness without dismissing a startup dialog or repeating input.
5. Foreground process and cwd observations remain accurate after Treehouse starts a subshell and after the agent exits; core recovery shells remain conservatively ambiguous.
6. Cleanup affects only the disposable task's space; adding a foreign tab or moving its terminal makes cleanup refuse, and an app or core outage retains records for retry.

Do not use existing personal spaces for that smoke test or run broad core lifecycle commands.
The offline tests establish Firstmate routing and safety logic, not actual app focus behavior, JSON compatibility, harness startup, process attribution, or desktop cleanup behavior.
