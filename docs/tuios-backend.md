# TUIOS runtime backend

TUIOS is an experimental terminal-session backend. It owns terminal sessions and windows only; Squad and fob continue to own task identity, task state, and isolated git worktrees. Shared backend selection and metadata semantics are documented in [`configuration.md`](configuration.md#runtime-backend-configbackend--squad_backend).

Every mechanism below was validated against an installed TUIOS binary and its own verb catalogue, not against web documentation alone. [`verification/runtime-backends.md`](verification/runtime-backends.md#tuios) owns the live evidence and states exactly what is still unverified.

## Setup

Install TUIOS 0.8.0 or newer, `jq`, and `flock`, and ensure `fob` is available as required by the normal session-provider contract.
`python3` is needed only for the optional native agent-state event subscription; without it the backend is supervised by the ordinary `SQUAD_POLL` reconcile instead.
Select it explicitly with local `config/backend` containing `tuios` or `SQUAD_BACKEND=tuios`. TUIOS is never auto-detected from `TUIOS_*` ambient markers, and the adapter never creates, adopts, restarts, or deletes a session.

Set `SQUAD_TUIOS_SESSION` explicitly to a TUIOS session that the Squad base is authorized to use. The adapter only validates and uses that existing session. Task windows are created without requesting focus, each task target is `<session-name>:<opaque-window-id>`, and the exact session and opaque window id are recorded in the task metadata.

Each task uses its own existing empty, unnamed workspace in the configured session. The adapter prefers the available workspace number in local `config/tuios-workspace`; without that preference it chooses the lowest eligible number. A preferred workspace that is occupied, named, or leased is skipped, while a configured number absent from the session is an error. Allocations are serialized per session with an exclusive kernel `flock` on a stable lock file under the user's `XDG_RUNTIME_DIR` (or the effective config directory when unset) and rechecked against live inventory. The lock file is never removed, so waiters cannot switch to a replacement inode and kernel process-exit handling releases abandoned locks. The adapter temporarily names the selected workspace for the task, creates the window there without requesting focus, and verifies the exact window ID's placement. It never creates or renumbers workspaces, changes an existing name, or moves an existing window.

At detection the adapter validates the daemon's own verb catalogue (`tuios list-verbs --json`) for every verb and parameter it uses, and refuses to drive a daemon that is narrower or older than this adapter. Per-task placement requires `list-workspaces`, `set-workspace-name`, and the `new-window` workspace parameter. A missing verb or parameter fails loudly and names it.
Two capabilities are optional rather than detection requirements: the native `subscribe` stream is used only when the catalogue advertises its parameters, and the prompt-bound `respond` verb only when it advertises the parameters an answer needs.
A daemon lacking the capability an operation needs refuses that operation by name instead of substituting keystrokes, so an older daemon keeps the poll path and a prompt answer refuses rather than degrading.

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
- Queue entries are held in daemon memory, not durably persisted: a daemon restart, pane close, or agent leaving the pane drops them. `list-queued` inspects entries and `cancel-queued` removes one; neither makes the queue durable.
- Nothing is ever retyped or resent after bytes were typed. A `stalled` result means the text was typed and not taken; inspect the pane before resending.

Distinct delivery verdicts reach the caller:

| Verdict | Meaning | Exit status |
| --- | --- | --- |
| `empty` | The agent took the message, or it is queued for the agent's next rest. | 0 |
| `agent_blocked` | The pane is on `needs_input`. Nothing was typed, because free text would answer its prompt. | non-zero |
| `queue_full` | The pane's queue holds the configured maximum. Nothing was queued. | non-zero |
| `stalled` | The entry was typed and the agent showed no sign of taking it. Do not resend. | non-zero |
| `not_ready`, `prompt_stalled` | Mapped from the daemon's documented refusal codes. The asynchronous queue path does not currently raise them. | non-zero |
| `no_agent` | TUIOS cannot attribute an agent to the pane; Squad refuses delivery without typing into the terminal. | non-zero |
| `uncertain-delivery` | The daemon's queue reply carried no unambiguous entry id, so bytes may already have been queued. Never retype; inspect the queue and the pane. | non-zero |
| `send-failed` | Any other refusal. | non-zero |

Pi and pi-signed tasks still use Squad's task-private Pi delivery dropbox first, exactly as on every other backend; the TUIOS path is used when that dropbox is unavailable and for every other harness.

## State, prompts, and provenance

The adapter reads the daemon's own agent report and keeps its provenance instead of collapsing everything to one token:

| TUIOS state | Squad busy verdict | Recovery agent state |
| --- | --- | --- |
| `working` | `busy` | `alive` |
| `needs_input` (approval or question) | `blocked` | `alive` |
| `errored` | `blocked` | `alive` |
| `idle` | `idle` | `alive` |
| `done`, foreground program present | `idle` | `alive` |
| `done`, no foreground program, attributed | `idle` | `dead` |
| `none`, no attributable agent | `unknown` | `dead` |
| `unknown`, or a state with no attribution | `unknown` | `ambiguous` |
| unreadable inventory | `unknown` | `unreadable` |

`bin/sq-crew-state.sh` renders a blocked pane as `state: blocked` and includes the prompt the daemon read, including the exact `prompt_id` an answer must name. The report verb `tuios peek-prompt` supplies that prompt text, numbered options, and id, and the adapter reads it only for a pane the daemon reports as `needs_input`; its text is another program's screen and is treated as data. The daemon exposes no generic "ordinary composer is empty" bit, so composer state is read from the pane (see "Composer state" below); anything that is not provably a composer frame stays `unknown`, which never authorizes a write.

### Waking Squad on a blocked pane

When the installed daemon advertises a verified `subscribe` verb in its catalog, TUIOS agent-state events wake the sentry's bounded native event wait. Events are wake hints only: Squad re-reads the exact window's current state and prompt before acting, using the normalized transition policy (`bin/sq-transition-lib.sh`). Daemons without the catalogued verb are poll-only instead: `fm_backend_tuios_poll_transition` in `bin/backends/tuios.sh` is the level-reconcile producer, and `docs/architecture.md`'s "Capability matrix: the person-needed escalation" owns how both TUIOS paths fit alongside Herdr's push path, Orca's poll path, and the backends that cannot report the condition at all.

On a native `blocked` verdict (`needs_input` or `errored`), Squad wakes with the task's window and the prompt `fm_backend_prompt_summary` read, including the numbered options above when the daemon supplied any and the exact `prompt_id` an answer must name.
With catalogued `subscribe`, agent-state events provide the prompt wake; the adapter subscribes before reconciliation, then re-reads current state and prompt before applying shared policy.
This is a wake hint, not a decision or an answer: only a person-authorized `sq-send --respond` call can answer, and TUIOS checks both the `respond` grant and the prompt id.
Event delivery is prompt and bounded; gap, reconnect, or unsupported capability falls back to the ordinary `SQUAD_POLL` reconciliation.
The wake fires exactly once per distinct pending prompt, keyed on the prompt's own identity rather than the `needs_input` status alone; [`architecture.md`](architecture.md#capability-matrix-the-person-needed-escalation) owns that identity's exact contents and its numbered-options exclusion.
A status-only dedupe would miss a pane that shows one prompt, has it dismissed, and immediately shows a different one while never leaving `needs_input`.
A new or changed prompt always wakes again, the identical standing prompt never repeats one, and a blocked pane is never folded into the ordinary stale/wedge detection, so it is never misread as a possible wedge.
A transiently unreadable native status or prompt read is an ambiguous fallback, not a cleared state: the dedupe markers stand until a later readable read establishes a genuinely different prompt, so one unreadable poll never duplicates the wake.
Nothing is ever typed over the open prompt: the wake only tells Squad a person is needed and what the prompt asks, and Squad still decides and sends the answer itself.
Sending that answer needs the `respond` grant on the pane that types it (see "Answering a blocked prompt" below).
A backend with no native blocked verdict (tmux) never raises this wake - it is never guessed from rendered pane text.

### Answering a blocked prompt

A pane waiting on a prompt refuses every keystroke that would answer it unless the pane that *types* the answer holds `respond`.
The grant therefore belongs to the answering pane - normally the supervisor's own - and not to the blocked pane, so granting it to the operator's window changes nothing.
`admin` includes read, write, and fan but never `respond`, and a pane can never give more than it holds, so the first `respond` on a supervised pane can only come from a caller that runs in no pane of that daemon.
That is TUIOS 0.9.1's deliberate rule, measured on 2026-10-20: the same `send-keys` into a `needs_input` pane was refused from a pane holding `admin` and succeeded once that same pane held `admin,respond`, and every in-pane attempt to add `respond` was refused with "a pane cannot give more than it holds".
So the one-line human step below is a provider boundary Squad respects on purpose, not a Squad defect to route around.
[`verification/runtime-backends.md`](verification/runtime-backends.md#tuios) owns that evidence.

`bin/sq-pane-grants.sh` is the sanctioned surface for this grant, and the raw-session guard's refusal names it as the one sanctioned pane-grant path (`bin/sq-backend-pretool-check.sh`), except for a refused `set-pane-grants --reset`, whose removal the wrapper cannot perform and which the refusal leaves with the person outside TUIOS:

```sh
bin/sq-pane-grants.sh show <target>            # read-only: grants, and whether respond is present
bin/sq-pane-grants.sh grant respond <target>   # add respond, keep everything the pane already held
bin/sq-pane-grants.sh verify <target>          # read-only gate: exit 0 only when respond is present
```

`<target>` is a task id resolved through `state/<id>.meta` (which must record `backend=tuios`) or an explicit `<session>:<window>`.
The wrapper accepts no other grant, never addresses a whole session, and never replaces a pane's grants, so it cannot become a general TUIOS proxy.
It also refuses a `grant` on a target that the inventory reports as waiting on a prompt (`needs_input` or `errored`): that is the pane whose dialog needs answering, not the pane that should be allowed to answer it.
When `respond` is missing on such a target, `show` and `verify` say so and print one `person command:` aimed at the pane that types the answer - the caller's own pane whenever the daemon reports that placement - and print no command at all when that pane cannot be named, which is when the daemon reports no placement or reports the caller itself inside the blocked pane.
An unknown, ambiguous, or unreadable target is refused before any grant write, and a daemon refusal is reported verbatim with the exact command that fixes it.
A pane's grant set is read from `list-windows`: the daemon leaves `grants` absent or `null` for a pane that holds its default set (`tuios set-pane-grants --reset` restores `null`), so that shape is read as the default and the add-only write keeps the inherited grants, while an explicit list (including an empty `[]`) is taken literally and any other shape is refused rather than guessed.
`show` keeps the two empty shapes distinct, so an unset pane is never read as a deliberate denial: a pane with no explicit set whose daemon default is empty prints `grants: unset (daemon default is empty)` and `verify` reports the same, while only an explicit empty list prints `grants: none`.
When `show`, `verify`, or a daemon-refused `grant` prints a `person command:` line, it uses the same form: the wrapper by absolute path with the resolved window id, ready to paste into the person's own shell outside TUIOS.
The supervisor's own pane is not a task, so address it explicitly as `"$TUIOS_SESSION:$TUIOS_PANE_ID"`.
`show` without a target reads the pane it runs in, and a caller outside every pane is told so with the target form to name instead, never the daemon default passed off as its own grants.

The flow when a dialog blocks an operator:

1. The wake reports the pane, the prompt it read, and the exact prompt id an answer must give.
2. `bin/sq-pane-grants.sh show "$TUIOS_SESSION:$TUIOS_PANE_ID"` says whether the answering pane can already answer it, and prints the `person command:` line when it cannot.
   That delegation is the person's, once, from a shell outside TUIOS; no pane can give it to itself.
3. `bin/sq-pane-grants.sh verify <target>` confirms the grant landed before anything is retyped, and its non-zero exit means the send would still be refused.
4. The authorized actor takes the prompt id from that wake, or re-reads the current prompt with `bin/sq-crew-state.sh <id>` when the prompt may have changed since the wake; both are sanctioned Squad surfaces, while a raw `tuios peek-prompt` call is refused for the guarded primary scope.
   Send the decision with `bin/sq-send.sh <id> --respond <action> <prompt-id> [value]`.
   Use `approve` or `deny` for an approval, `choose` with the displayed option number for a numbered question, and `text` with the answer a free-text prompt accepts; an action the current prompt does not accept is refused by name and nothing is answered.
   It re-reads the current prompt, requires the same `prompt_id`, verifies the action and selected option, then lets TUIOS enforce the answering pane's `respond` authority and atomically refuse a changed prompt.
   A stale id expires the old decision for every action and returns a `tuios_prompt_recovery` JSON snapshot with the target, current id, supported actions, displayed options, and prompt, alongside the attempted id, action, and value; the supervisor must make a new decision.
   A daemon-confirmed changed-prompt refusal performs at most one read-only recovery read and returns that snapshot, an explicit nonblocked state, or an explicit read failure.
   `approve_always` and risk-matched approvals are not inferred or automated; a TUIOS risk refusal confirms that nothing was answered.
   The command invokes `respond` once; an unconfirmed write preserves the attempted id, action, value, and original diagnostic and remains unresolved even if reconciliation still sees the same prompt, and its read-only observation never authorizes a retry.
   Exact-id confirmation is emitted independently of settlement, so an unknown settlement does not erase evidence that the answer was confirmed.
   The older `bin/sq-send.sh <id> --key <key>` path remains available for key-only prompts, but it does not bind the answer to a prompt id.
   Free text through ordinary `sq-send` remains refused while blocked because that would answer without the prompt-specific permission and identity checks.
5. The grant is a delegation, not standing practice: it stays on the one pane that answers, is never given to operators, and the person removes it with `tuios set-pane-grants -w <pane> --reset` from outside TUIOS when the delegation ends.

One delegation is enough after that: a pane that already holds `respond` can pass it on, so a supervisor holding it can grant it to a task pane that supervises its own operators, such as an XO primary.
When a send is refused for this missing grant, `bin/sq-send.sh` prints that same `person command:` line for the pane that must hold it, and keeps only the provider's refusal sentence instead of forwarding its `set-pane-grants` remediation advice, which Squad's guard refuses.
It recognises that refusal from the daemon's own sentence or its structured error code, so any other refusal keeps its full diagnostic and gets no grant hint.

## Restart recovery

A daemon restart destroys every running program. The restored session keeps its names and window ids but runs a fresh shell in every pane, and the daemon's own boot id changes. The adapter records `tuios_boot_id=` with the task metadata at spawn.

- Reconciliation is inventory-based. A restored pane has an exact window id, no attributable agent, and `state=none`, so it classifies as `dead` (endpoint present, no agent) instead of the silent `ambiguous` that never licensed recovery. Recovery is not achieved by an event subscription.
- Conversation resume uses the product's own verb. `tuios resume-agent` builds its command from the harness manifest and the conversation id the daemon recorded for the pane, so nothing caller-chosen is typed. The adapter first confirms the conversation id exists and refuses with `unsupported` when the installed manifest has no resume command for that harness (Pi is one such harness).
- Otherwise the task routes back into Squad's existing safe relaunch path. Because a restored window still holds the task's label, a relaunch reuses that exact window - only when the recorded boot id differs from the daemon's current boot id and the window is confirmed agentless - and resumes into the task's recorded worktree instead of leasing a second copy.

## Finished-agent recovery

A harness can exit while the daemon keeps its window: Pi prints its resume pointer, the process ends, and the pane falls back to a shell.
The daemon then still reports `state=done` and still names the harness it recorded, but its `foreground` program is empty.
That is the second recovery-grade agentless shape, and the exact rule is: `state=done`, empty `foreground`, and positive attribution that does not come from a foreground program (a non-empty `harness_id` or a non-`none` `confidence`).
The endpoint classifies as `dead`, so the same resume-then-relaunch path as a restart applies, and the safe-relaunch step reuses the task's recorded window and worktree through the same duplicate-label guard as a post-restart relaunch.
This shape is boot-independent: the daemon's own finished-and-foreground-less report is the proof, so it recovers even when the task metadata predates the `tuios_boot_id=` marker, and only the post-restart `state=none` shape still requires a changed boot id.
Every other shape keeps its existing verdict and never authorizes a relaunch: any report with a detected `foreground` program is `alive`; a state other than `done` is `alive` when attributed, stays `dead` for the agentless `none`/empty state, and is `ambiguous` otherwise; a `done` report with no attribution is `ambiguous`; and an unreadable or contradictory inventory is `unreadable`.

What remains unproven: the rule is derived from one daemon build (TUIOS 0.8.0), where every live agent reported a `foreground` program and the one exited Pi agent reported none.
A daemon build or harness that legitimately reports `state=done` without a `foreground` program while its agent is still running would be misclassified as `dead`.
The structural signal is the pane's own foreground process, so a build that stops reporting `foreground` for live agents must be re-characterized before this rule is trusted.

## Cleanup

Cleanup verifies both the exact opaque window id and the recorded task label before closing anything, so only the recorded task window can ever be closed. The close is TUIOS's own window-close path (`close-window`, which the CLI surfaces as `tuios run-command CloseWindow <id>`) addressed by the exact session and window id - never the tmux compatibility shim, which would resolve a shim pane id instead. `run-command` exits 0 even when the close failed, so its result envelope is the only success signal and a refusal is surfaced with the daemon's own message. After the exact task window is confirmed gone, cleanup clears only that task's recorded workspace name and only when the workspace is otherwise empty. A mismatch, remaining window, or unreadable inventory preserves the name rather than risking another owner's layout. Cleanup never deletes a session and never touches the daemon.

## Away-mode supervision

A TUIOS-hosted Squad primary can be supervised in away mode without any terminal typing: the preferred path delivers through Pi's own message queue via `.pi/extensions/sq-primary-away-handoff.ts` and `bin/sq-afk-pi-handoff.sh`, and the daemon never types while that path is available.
When the native path refuses, delivery falls back to the guarded composer path, which queues the digest through the supervisor pane's own agent (TUIOS delivery is queue-only) only after that composer is positively read as empty for a daemon-attributed live agent, as described in "Composer state" and "Limits and verification" below.
A pane TUIOS cannot attribute a live agent to is refused as `no_agent` and nothing is typed into its terminal.

- The extension binds to the exact `TUIOS_SESSION` and `TUIOS_PANE_ID`, publishes its own `state/.pi-away-handoff/ready.<session>.<window>.json` with its process identity and a one-second heartbeat, and accepts a request only when it names that exact target.
- Only the Pi that holds the base's session lock publishes or accepts anything, and only the exact lock owner counts: `bin/sq-lock.sh` records the innermost harness pid, so a Pi started from the primary's own shell - which inherits `SQUAD_BASE` and the TUIOS pane variables - is a worker even though the lock holder is its ancestor.
  A worker's Pi inherits `SQUAD_BASE` and the TUIOS pane variables, and its Squad worktree carries this same project extension, so a single shared record used to be overwritten by whichever worker wrote last and the daemon fell back to the guarded composer path; readiness is therefore keyed by target and a record naming another window never satisfies the supervised pane.
- `bin/sq-afk-pi-handoff.sh` publishes one durable `request.json` and observes `result.json`; it never retypes an unresolved escalation and reports success only on a consumption acknowledgement.
- The extension queues the digest with `sendUserMessage(..., { deliverAs: "followUp" })`, which never touches the composer or an open dialog, and acknowledges consumption when Pi's own `before_agent_start` prompt carries the handoff marker.
  The acknowledgement is written only by the lock-owning Pi and only for a request naming its own exact target, so a worker or nested Pi can never retire a buffer prefix for a digest the primary never received.

Delivery is gated by three positive conditions: Pi must be idle, the editor must hold no draft, and no Pi prompt may be open.
The last one is a native signal: Pi emits `ui_prompt_start` and `ui_prompt_end` around every built-in dialog (`select`, `confirm`, `input`, `editor`, `custom`), and the extension defers while that count is non-zero.
A queued escalation stays durable while it waits, so a busy Pi, a typed draft, or an open approval prompt delays delivery instead of losing or duplicating it.

Each readiness record is a version-3 delivery-state record carrying `idle`, `draft`, `prompts`, and `sending`; the daemon refuses an older record and falls back to the composer path rather than trusting a handoff that cannot describe its state.
A legacy shared `ready.json` is still honoured when it names the exact target, so a primary that started before the per-target layout keeps working until it restarts.
When the daemon uses the composer path it logs why once per distinct reason, and every reason the handoff can report is named here so a silent fallback is never invisible.
The preconditions, checked before any record is read, are `not-tuios` (the supervisor is not the TUIOS backend), `backend-unavailable` (the TUIOS adapter could not be sourced), `target-gone` (the exact supervisor target no longer exists), and `no-handoff-dir` (no Pi has published readiness in this state directory yet).
The record reasons are `no-record` (no per-target record for this target, and no legacy `ready.json` naming it), `other-target` (the per-target record exists but names a different session or window, which only a sanitized-name collision or a copied record produces), `unreadable-record` (the file is not a JSON object), `schema` (the record predates version 3 or is malformed), `other-session` (the base's session lock names a different pid that is still alive, so another session really owns the base), `dead-process` (the recorded pid is gone), `identity-unavailable` (the recorded pid's identity could not be computed for comparison), `identity-mismatch` (that pid was recycled by a different process), and `stale-heartbeat` (no heartbeat for more than five seconds, so Pi's event loop is blocked).
A lock naming a dead process counts as absent, on both the extension side and the daemon side, so a crash-relaunched primary engages again without anyone reclaiming the lock first; a lock that exists but cannot be read, or that is empty or non-numeric, still refuses as `other-session` because a competing session may own it.
`bin/sq-afk-pi-handoff.sh` owns this enumeration, so a new refusal token there belongs here too.
`no-record` after a restart-free upgrade means the primary Pi has not loaded the extension yet and must be restarted, and an `other-session`, `dead-process`, `identity-mismatch`, or `stale-heartbeat` verdict right after a crash or restart means the primary must be relaunched or its stale lock reclaimed before native delivery resumes.

Delivery is idempotent across batches.
A published request records how many buffered escalations it covers, and once Pi acknowledges consuming it the daemon retires exactly that buffer prefix, so a later digest that also carries a newer escalation never re-sends the one Pi already handled.
A request is republished only when replacing it cannot duplicate delivery: Pi consumed it, or the extension's send never reached Pi (`uncertain`), or a `submitting` record has aged past the bound while the live, identity-verified extension reports no in-flight send, or a `queued` record was written by a process that is no longer the live extension - that followUp queue died with its writer, so republishing it under a new id is the only way the digest is ever delivered.
A `submitting` or `queued` record owned by the live extension is never replaced, because that send or queue can still deliver, and the wedge alarm still covers a request that stays undelivered.
When the native verdict is transiently refused while that live, identity-verified extension still holds an unresolved request for the exact target, the daemon defers instead of delivering the digest again through the composer path, so an escalation Pi already holds is not delivered twice once its event loop unblocks.
The deferral is bounded: a request whose result entry is older than `SQUAD_PI_HANDOFF_STALE_SECS`, names another target, or was written by a dead or foreign process does not block the composer path, so a stuck request can never wedge delivery.

`bin/sq-afk-launch.sh` starts the away daemon in its own exact, newly created, detached TUIOS session.
It refuses cleanup unless the recorded session id, its one owned window, and its unattached state still match, and every failure after the session is created closes that exact session again, so a failed launch cannot leak an unrecorded detached session.

`bin/sq-afk-tuios-lab.sh` (guarded by `SQUAD_TUIOS_AFK_LIVE=1`) is the only supported live verification path.
It uses a private daemon with fresh `XDG_RUNTIME_DIR`, `XDG_STATE_HOME`, and `XDG_CONFIG_HOME`, a temporary Squad base, and a loopback-only mock provider, and it destroys only sessions it created.
`tests/sq-afk-tuios-live-optin.test.sh` is the env-gated, self-skipping wrapper that puts that lab in `bin/sq-test-run.sh`'s `live-harness-optin` family, so the live half of the composer and readiness guarantee is mechanically reachable instead of depending on someone remembering the lab command.
See [`verification/runtime-backends.md`](verification/runtime-backends.md#tuios) for the live evidence.

## Composer state

`fm_backend_tuios_composer_state` reads the pane tail and classifies the composer frame through the shared owner in `bin/sq-composer-lib.sh`.
Two frames are recognized: a box (`╭──╮`, `│ … │`, `╰──╯`, drawn by claude and by a Pi setup that customizes its editor, as on the commander's primary) and a pair of full-width rules with no side borders (stock Pi 1.1.0).
Every row between the borders is judged together, so a multi-line draft is `pending` even when its last line is blank.
The frame must sit at the bottom of the pane above a short footer, so tool-output boxes and markdown rules in the scrollback are never mistaken for the composer.
A frame whose rows are all blank is `empty`, any content is `pending`, and everything else is `unknown`, which still never authorizes a write.
`empty` additionally requires the daemon to attribute a live agent to that pane: a crashed Pi can leave its last composer frame on screen above the shell prompt, and the frame alone cannot tell that apart from an idle agent.
A dead, missing, ambiguous, or unreadable agent report therefore turns an otherwise empty frame into `unknown`, so the composer fallback is never handed a pane whose agent is gone.
The frame read is tunable for a harness or theme that draws it differently: `SQUAD_BACKEND_TUIOS_COMPOSER_LINES` sets the pane tail captured, `SQUAD_BACKEND_TUIOS_COMPOSER_FOOTER_MAX` how many footer rows are tolerated below the frame, `SQUAD_BACKEND_TUIOS_COMPOSER_ROWS_MAX` how many editor rows are admitted between the two borders, and `SQUAD_BACKEND_TUIOS_IDLE_RE` matches an empty-composer placeholder; their defaults are listed in [`configuration.md`](configuration.md).
This is a rendered-surface signal, so it is a harness-dependent check: `tests/sq-backend-tuios.test.sh` pins the portable logic against the captured frame shapes and the dead-agent case, and the guarded live lab (`bin/sq-afk-tuios-lab.sh lifecycle`, reachable from the `live-harness-optin` lane through `tests/sq-afk-tuios-live-optin.test.sh`) proves it against a real Pi, reading `empty` when idle and `pending` once a draft is typed.
Rerun the lab after every Pi or TUIOS upgrade, because a theme change that redraws the frame would otherwise degrade quietly to `unknown` and defer every escalation.

## Limits and verification

- Native away-mode delivery to a TUIOS supervisor pane requires the shipped Pi extension on the primary, loaded at Pi startup; a primary started before the extension existed keeps using the composer path until restarted.
  The composer path delivers only into a composer positively read as empty, and defers on a draft, a busy or blocked pane, or any frame it cannot identify.
- The open-prompt guard depends on Pi's `ui_prompt_start`/`ui_prompt_end` events, which were verified live on Pi 0.99.0 by opening a real dialog while the primary was idle and confirming the escalation was held until it closed.
  A future Pi release that stopped emitting those events would silently reduce the guard to idle plus draft, so that event contract must be re-verified on a Pi upgrade.
- Native agent-state events are used when the daemon's verb catalogue confirms `subscribe` and its required parameters: a stream gap or reader failure falls back to ordinary reconciliation, an event that is not a fresh actionable edge does not end the wait early, and the caller's SIGTERM stops the reader with its subscription instead of leaving it connected to the daemon.
  The reader starts a fresh subscription rather than requesting sequence replay, so recovery after reconnect depends on the baseline read and bounded poll, while older daemons remain poll-supervised with latency bounded by `SQUAD_POLL`.
- The daemon's queue, mail, activity, and agent state live in daemon memory and die with it; a restart is reconciled from the inventory and the durable Squad task record, never from a replayed event.
- `not_ready` and `prompt_stalled` mappings exist and are tested against the daemon's documented codes, but the asynchronous queue path does not raise them, so they were not observed live.
- The durable lease on a failed spawn is returned by the adapter; a lease whose spawn succeeded is returned by Squad teardown.
- The away-mode extension, the sender, and the launcher each have portable regression coverage, but the live TUIOS/Pi path is exercised only by the guarded lab above; there is no CI coverage of a real TUIOS daemon or a real Pi TUI.
- An accepted-but-never-consumed request (`queued` while Pi never starts the turn) is preserved while the extension that accepted it is still the live, identity-verified one, because republishing could duplicate a delivery it still holds; once that writer is gone its followUp queue died with it and the request is republished instead, so a restart can no longer wedge every later digest. The wedge alarm covers a request that stays undelivered for any other reason.
- The fake-CLI suite covers preferred-workspace selection, occupied/named/leased exclusions, exact-ID placement verification, abort cleanup, and guarded workspace release. A focused check on the existing isolated nine-workspace private TUIOS session created two tasks in distinct non-current workspaces, confirmed the original focused window and current workspace were unchanged, then closed both probe windows and restored both names to empty. The shared daemon and every non-lab session were untouched.

[`verification/runtime-backends.md`](verification/runtime-backends.md#tuios) owns the commands and output behind each claim above, and the honest list of what is not yet established. The portable contract is covered by `tests/sq-backend-tuios.test.sh` and `tests/sq-spawn-tuios-worktree.test.sh` using fake CLIs; those tests never contact or change a live TUIOS session.
The blocked-operator answer path also has an opt-in isolated lab (`bin/sq-afk-tuios-lab.sh respond`, driven by `tests/sq-tuios-respond-live-optin.test.sh`) that runs against a private daemon it creates and destroys.
It proves, live, the daemon's own prompt read, the native blocked event, the supervisor wake carrying the question and numbered options, the refusal of an in-pane answer, the exact prompt id answered from the person's shell, the observed resume, and the absence of a duplicate answer or replayed wake.
Its operator process draws the approval screen itself instead of a vendor harness drawing it, so a vendor CLI's own dialog and a model turn are not part of that evidence.
