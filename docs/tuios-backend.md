# TUIOS runtime backend

TUIOS is an experimental terminal-session backend. It owns terminal sessions and windows only; Squad and fob continue to own task identity, task state, and isolated git worktrees. Shared backend selection and metadata semantics are documented in [`configuration.md`](configuration.md#runtime-backend-configbackend--squad_backend).

Every mechanism below was validated against the installed TUIOS 0.8.0 binary and its own verb catalogue, not against web documentation alone. [`verification/runtime-backends.md`](verification/runtime-backends.md#tuios) owns the live evidence and states exactly what is still unverified.

## Setup

Install TUIOS 0.8.0 or newer, `jq`, and `flock`, and ensure `fob` is available as required by the normal session-provider contract. Select it explicitly with local `config/backend` containing `tuios` or `SQUAD_BACKEND=tuios`. TUIOS is never auto-detected from `TUIOS_*` ambient markers, and the adapter never creates, adopts, restarts, or deletes a session.

Set `SQUAD_TUIOS_SESSION` explicitly to a TUIOS session that the Squad base is authorized to use. The adapter only validates and uses that existing session. Task windows are created without requesting focus, each task target is `<session-name>:<opaque-window-id>`, and the exact session and opaque window id are recorded in the task metadata.

Each task uses its own existing empty, unnamed workspace in the configured session. The adapter prefers the available workspace number in local `config/tuios-workspace`; without that preference it chooses the lowest eligible number. A preferred workspace that is occupied, named, or leased is skipped, while a configured number absent from the session is an error. Allocations are serialized per session with an exclusive kernel `flock` on a stable lock file under the user's `XDG_RUNTIME_DIR` (or the effective config directory when unset) and rechecked against live inventory. The lock file is never removed, so waiters cannot switch to a replacement inode and kernel process-exit handling releases abandoned locks. The adapter temporarily names the selected workspace for the task, creates the window there without requesting focus, and verifies the exact window ID's placement. It never creates or renumbers workspaces, changes an existing name, or moves an existing window.

At detection the adapter validates the daemon's own verb catalogue (`tuios list-verbs --json`) for every verb and parameter it uses, and refuses to drive a daemon that is narrower or older than this adapter. Per-task placement requires `list-workspaces`, `set-workspace-name`, and the `new-window` workspace parameter. A missing verb or parameter fails loudly and names it.

## Worktree acquisition

TUIOS reports only its own top-level shell's cwd. `fob get` acquires its worktree by opening a **nested subshell**, so a TUIOS spawn cannot discover the worktree by polling the window's reported cwd - that nested shell is invisible to the daemon.

A TUIOS spawn therefore acquires the lease non-interactively and moves the window's own shell into it:

1. `fob get --lease --lease-holder <task-id>` runs outside the window and prints only the absolute worktree path.
2. The window receives one top-level `cd -- <lease-path>`.
3. The spawn waits until the window's reported cwd equals that lease path, then requires the recorded `worktree=` to be exactly it.

If the window never reports the lease path, the spawn fails, writes no metadata, and returns the lease with `fob return --force` so a failure never leaks a worktree out of the pool. A lease is durable: it is held until teardown returns it, which also makes the recorded worktree safe from being handed to another task between a restart and a relaunch.

## Task control and delivery

Capture and terminal operations address the exact recorded window. Delivery to an agent uses TUIOS's own agent-aware queue instead of raw text plus Enter:

- `tuios queue` (`queue-prompt`) types a message only once the agent has been at rest, never types over a prompt the agent is waiting on, and marks an entry the agent shows no sign of taking as `stalled`.
- Squad reports success only on an observed postcondition: the queue entry was taken, or the entry waits safely for the agent's next rest (the daemon owns it from there and will not type over a prompt).
- Nothing is ever retyped or resent after bytes were typed. A `stalled` result means the text was typed and not taken; inspect the pane before resending.

Distinct delivery verdicts reach the caller:

| Verdict | Meaning | Exit status |
| --- | --- | --- |
| `empty` | The agent took the message, or it is queued for the agent's next rest. | 0 |
| `agent_blocked` | The pane is on `needs_input`. Nothing was typed, because free text would answer its prompt. | non-zero |
| `queue_full` | The pane's queue holds the configured maximum. Nothing was queued. | non-zero |
| `stalled` | The entry was typed and the agent showed no sign of taking it. Do not resend. | non-zero |
| `not_ready`, `prompt_stalled` | Mapped from the daemon's documented refusal codes. The asynchronous queue path does not currently raise them. | non-zero |
| `uncertain-delivery` | The pane holds no agent TUIOS can attribute, so the pre-existing literal write was used; it proves only that bytes reached the terminal. | non-zero |
| `send-failed` | Any other refusal. | non-zero |

Pi and pi-signed tasks still use Squad's task-private Pi delivery dropbox first, exactly as on every other backend; the TUIOS path is used when that dropbox is unavailable and for every other harness.

## State, prompts, and provenance

The adapter reads the daemon's own agent report and keeps its provenance instead of collapsing everything to one token:

| TUIOS state | Squad busy verdict | Recovery agent state |
| --- | --- | --- |
| `working` | `busy` | `alive` |
| `needs_input` (approval or question) | `blocked` | `alive` |
| `errored` | `blocked` | `alive` |
| `idle`, `done` | `idle` | `alive` |
| `none`, no attributable agent | `unknown` | `dead` |
| `unknown`, or a state with no attribution | `unknown` | `ambiguous` |
| unreadable inventory | `unknown` | `unreadable` |

`bin/sq-crew-state.sh` renders a blocked pane as `state: blocked` and includes the prompt the daemon read. The report verb `tuios peek-prompt` supplies the prompt text and numbered options, and it is read only for a pane the daemon reports as `needs_input`; its text is another program's screen and is treated as data. The daemon exposes no generic "ordinary composer is empty" bit, so composer state stays `unknown`, which never authorizes a write.

## Restart recovery

A daemon restart destroys every running program. The restored session keeps its names and window ids but runs a fresh shell in every pane, and the daemon's own boot id changes. The adapter records `tuios_boot_id=` with the task metadata at spawn.

- Reconciliation is inventory-based. A restored pane has an exact window id, no attributable agent, and `state=none`, so it classifies as `dead` (endpoint present, no agent) instead of the silent `ambiguous` that never licensed recovery. Recovery is not achieved by an event subscription.
- Conversation resume uses the product's own verb. `tuios resume-agent` builds its command from the harness manifest and the conversation id the daemon recorded for the pane, so nothing caller-chosen is typed. The adapter first confirms the conversation id exists and refuses with `unsupported` when the installed manifest has no resume command for that harness (Pi is one such harness).
- Otherwise the task routes back into Squad's existing safe relaunch path. Because a restored window still holds the task's label, a relaunch reuses that exact window - only when the recorded boot id differs from the daemon's current boot id and the window is confirmed agentless - and resumes into the task's recorded worktree instead of leasing a second copy.

## Cleanup

Cleanup verifies both the exact opaque window id and the recorded task label before closing anything, so only the recorded task window can ever be closed. The close is TUIOS's own window-close path (`close-window`, which the CLI surfaces as `tuios run-command CloseWindow <id>`) addressed by the exact session and window id - never the tmux compatibility shim, which would resolve a shim pane id instead. `run-command` exits 0 even when the close failed, so its result envelope is the only success signal and a refusal is surfaced with the daemon's own message. After the exact task window is confirmed gone, cleanup clears only that task's recorded workspace name and only when the workspace is otherwise empty. A mismatch, remaining window, or unreadable inventory preserves the name rather than risking another owner's layout. Cleanup never deletes a session and never touches the daemon.

## Limits and verification

- Supervision stays poll-based. No event subscription (`subscribe` / `after_seq`) is used, so a stream gap cannot be replayed and a state change is observed on the next poll rather than immediately.
- The daemon's queue, mail, activity, and agent state live in daemon memory and die with it; a restart is reconciled from the inventory and the durable Squad task record, never from a replayed event.
- `not_ready` and `prompt_stalled` mappings exist and are tested against the daemon's documented codes, but the asynchronous queue path does not raise them, so they were not observed live.
- The durable lease on a failed spawn is returned by the adapter; a lease whose spawn succeeded is returned by Squad teardown.
- The fake-CLI suite covers preferred-workspace selection, occupied/named/leased exclusions, exact-ID placement verification, abort cleanup, and guarded workspace release. A focused check on the existing isolated nine-workspace private TUIOS session created two tasks in distinct non-current workspaces, confirmed the original focused window and current workspace were unchanged, then closed both probe windows and restored both names to empty. The shared daemon and every non-lab session were untouched.

[`verification/runtime-backends.md`](verification/runtime-backends.md#tuios) owns the commands and output behind each claim above, and the honest list of what is not yet established. The portable contract is covered by `tests/sq-backend-tuios.test.sh` and `tests/sq-spawn-tuios-worktree.test.sh` using fake CLIs; those tests never contact or change a live TUIOS session.
