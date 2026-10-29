# Orca runtime backend

Orca is an experimental backend on macOS and Linux in which the Orca app owns both the task worktree and terminal endpoint.
The operator harness remains the agent process launched inside that endpoint.
Squad agents load [`squad-orca`](../.agents/skills/squad-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca app and want Orca-managed worktrees and terminals instead of FOB plus a session multiplexer.
Orca runs on macOS and Linux, is explicit-only as a task backend, and does not support XO spawns.

Prerequisites:

- macOS: `/Applications/Orca.app` installed, running, and ready, with the CLI installed via `brew install orca`.
- Linux: the Orca release asset installed (`orca-linux.AppImage`, or `orca-ide_<version>_amd64.deb`) with an `orca` CLI on PATH - either a symlink to the AppImage (for example `~/.local/bin/orca -> orca-linux.AppImage`) or the native `orca-ide` binary that `orca serve` self-installs.
- Linux runtime: start the supported headless runtime with `orca serve` (for example `orca serve --port 6768 --json`) instead of opening the desktop app; a ready `serve` process satisfies exactly the same readiness gate below.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `SQUAD_BACKEND=orca` for one launch, or an explicit request to Squad.
It is never auto-detected for task placement.

Before any spawn mutates repository state, Squad requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.
Spawn also resolves the Squad base itself as Orca's hosting workspace, best-effort registering the base first, and refuses before allocating a worktree or tab when Orca still cannot show that workspace.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/sq-peek.sh <id>` and `SQUAD_BASE=<home> bin/sq-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one Orca-managed git worktree, where the agent runs, and one visible mission tab, which lives in the Squad base's hosting workspace.
`sq-spawn.sh` does not call FOB for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=sq-<id>
terminal=<orca terminal handle>
orca_host_workspace_id=<hosting workspace id>
orca_worktree_id=<orca worktree id>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Squad alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.
`orca_host_workspace_id=` names the workspace that owns the tab; it is never the mission worktree, so a send or close cannot resolve to the wrong place.
On macOS builds `orca_worktree_id=` records a bare atom (UUID).
On Linux builds (verified against v1.4.188) it records the composite form `<repo-id>::<absolute-path>`, which cleanup accepts alongside the bare form and validates structurally.

## Current lifecycle and safety

Spawn first resolves the Squad base's hosting workspace through Orca, registering the base with Orca when Orca does not know it yet, then validates that any existing metadata file is regular, registers the repository, creates an independent worktree, closes the terminal Orca returned for that worktree, opens a visible mission tab in the hosting workspace titled exactly `sq-<id>`, installs harness hooks, records metadata, and launches the selected harness inside the worktree.
The guarded launch runs from a generated shell script rather than a long inline terminal command, so interactive-shell parsing does not depend on the harness arguments.
When the mission worktree cannot be entered and physically verified, the script reports the failure and exits nonzero without starting the agent in the base checkout.
If the launch script cannot be written, spawn reports the error and sends no launch command.
The task temp directory that holds the script is created private to the current user, and spawn refuses to use a task temp path this user does not own or cannot make private, so no other local user can plant or swap the generated script.
A hidden background handle is closed and refused, never used to host a mission.
The tab's title carries no state; Orca renders agent status itself.
When a mission reaches `done` or `failed`, the next sentry signal scan after that status line closes the tab once through the mission tab helper, which verifies the terminal belongs to the hosting workspace before closing it and records only a confirmed close.
Teardown closes that same recorded terminal through its own exact-handle retirement record instead of the tab helper.
A relaunch of a recorded Orca task is refused as unverified on purpose: the mission tab identity is not yet verified for recommissioning, so Orca relaunch needs its own design and is tracked as a separate follow-up.
A tab the commander already closed, or a handle left by a previous Orca runtime, is proven absent by a complete hosting-workspace inventory plus an exact observation of the recorded handle instead of blocking the worktree release; an explicit `sq-teardown.sh --force` also lets an unobservable runtime through without recording an unconfirmed close.
A spawn that aborts before it mints a mission tab records `orca_mission_tab=none` and no `orca_host_workspace_id=`, so teardown releases its worktree through the legacy path and never closes an empty handle; a record that merely lacks a terminal without that declaration is refused as incomplete.
Non-regular metadata (for example a directory left by a prior interrupted attempt) is refused before any mission worktree, mission tab, or launch is created; the base hosting-workspace lookup and its best-effort base registration run before that refusal.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.
Spawn also passes Orca's own managed status extension to a Pi or pi-signed operator launch as one extra `-e`, so Orca's UI can show that operator's live state; the extension reports to Orca and is not read by Squad's sentry.
Path resolution and the optional-file rule are owned by `bin/sq-spawn.sh --help`: an absent file leaves that launch exactly as on every other backend, and no other backend or harness receives the extra argument.

`sq-peek.sh` reads with `orca terminal read`.
For non-Pi targets, or when native Pi delivery is unavailable, `sq-send.sh` types and verifies composer clearance, follows `oldestCursor` when Orca returns a limited page, and retries Enter without retyping when a slash popup first fills an argument placeholder.
A bare shell row is `unknown`, not an empty agent composer.
Pi operators launched from a positional brief complete their turn and exit to the shell instead of idling at a composer, so on Linux they never render the bordered composer row the clearance classifier verifies against.
When native Pi delivery is unavailable, a steer sent while such an operator is mid-turn is delivered and queued - verified live on v1.4.188, the terminal shows the queued message and the operator later acts on it - but verification still returns `unknown` and `sq-send.sh` exits reporting delivery unconfirmed.
That verdict stays genuinely unconfirmed either way: peek the terminal before acting on it, and never resend blindly, because the same `unknown` also covers text parked at an exited operator's bare shell prompt.
The sentry has no native Orca busy/idle signal, so each harness adapter's semantic lifecycle supplies worker state; an idle or unknown operator with no active run is surfaced by the existing sentry path rather than treated as task completion.
Blocked prompts use Orca's exact-terminal `agentWait` observation through the shared normalized transition policy, with changed-prompt deduplication and the existing exact-target `sq-send` answer path.
When that observation is absent or unreadable, Orca is never read as clear: an un-escalated terminal falls back to the existing supervision, while an already-escalated one keeps its markers and is deliberately held out of ordinary supervision until a readable read proves the wait gone.
The wait is never guessed clear or replayed as a native answer.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Squad safety checks.
A recon still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
Cleanup then records that exact terminal identity, plus the recorded worktree identity, through `bin/sq-retired-missions.sh` before any later step can remove the task metadata, and refuses to continue when that record cannot be persisted.
Squad closes only through the recorded exact handle, and refuses to release the worktree or remove the metadata while that handle is not confirmed gone, so a rerun retries the same handle with every durable record intact.
A record left by a refused or interrupted teardown stays for that retry and is reconciled by the locked session-start bootstrap sweep; [`configuration.md`](configuration.md) owns the record layout.
After those checks, Squad releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Away-mode supervision

An Orca-hosted primary automatically adopts its runtime-issued `ORCA_TERMINAL_HANDLE` when the path in `ORCA_WORKTREE_ID` physically matches the Squad base.
Only the composite worktree id documented under [Task shape and metadata](#task-shape-and-metadata) carries a path to compare; a macOS primary records a bare worktree atom, so it has no path and keeps using the explicit override.
Set `SQUAD_SUPERVISOR_BACKEND=orca` and `SQUAD_SUPERVISOR_TARGET=<exact runtime-issued terminal handle>` as an explicit override for an unusual setup; non-empty explicit values take precedence, exported empty values count as unset, and a detected tmux, Herdr, or TUIOS pane marker outranks the inherited Orca identity.
Missing or malformed identity, or a worktree path that does not physically match, publishes no readiness and makes `bin/sq-afk-launch.sh start` refuse.
The target must be a connected, writable, non-orphaned local terminal whose worktree path is the physical `SQUAD_BASE` directory.
This selection is independent of `config/backend`; changing task placement is not required.
Do not select a currently active tab by name, attach another multiplexer as evidence of native mobile support, or infer a primary from an operator's terminal.

Only the interactive **Pi** receiver is enabled initially.
`pi-signed`, Claude, Codex, OpenCode, Grok, Kimi, Muse, and unknown harnesses are refused by name before away-mode state or endpoints are created because their native draft/modal safety and consumed-message acknowledgement have not been proven for this integration.
Load the shipped `.pi/extensions/sq-primary-away-handoff.ts` in the selected primary and let that primary acquire the base's session ownership before entering away mode.
A missing, stale, foreign-process, foreign-endpoint, or replaced-incarnation readiness record refuses rather than falling back to terminal typing.
A bare shell cannot publish native readiness.
`SQUAD_SUPERVISOR_HARNESS` names that receiver adapter for the daemon.
When it is unset, `bin/sq-harness.sh` process ancestry must resolve the exact Pi primary to `pi`; a lifecycle invoked from a shell outside that primary - an Orca terminal's own shell, for example - resolves `unknown` and refuses rather than typing a fallback, so set `SQUAD_SUPERVISOR_HARNESS=pi` there.
The variable selects only the adapter: the primary's published readiness record still has to prove the receiver process, endpoint, and session identity, so it cannot manufacture readiness.

Use `bin/sq-afk-launch.sh start`, `status`, `stop`, and `reconcile` for the lifecycle.
The create call passes **no focus flag** and never splits the primary, creates or removes a worktree, or stops the runtime.
Whether Orca focuses, keeps, or hides the new terminal tab is real host behaviour that remains **unverified**, so treat the daemon terminal as possibly visible or focused.
The creation intent is recorded before the CLI call; a returned daemon identity is persisted before any subsequent runtime lookup.
Cleanup requires the exact terminal handle, runtime and terminal incarnation, and worktree identity/path; terminal titles are display-only because the shell can change them during startup.
A live daemon process must additionally match the recorded launch token and operating-system process identity before it can be signalled.
A record written by the pre-token launcher has no launch token, so its stored legacy title marker may verify only the process that the exact recorded terminal identity already binds; it never selects or adopts a terminal by title, and a mismatched or missing marker still refuses to signal.
Pending-creation recovery is owned by `bin/sq-afk-orca-launch.sh` and covered by `tests/sq-afk-orca.test.sh`; it requires a recorded daemon identity and a complete inventory bound to the original primary and this base.
`start` adopts exactly one identity match without replacing it; with the recorded handle absent and no unclaimed live terminal matching its binding, it releases the old intent and makes at most one create call.
`stop` requires the same conjunctive absence proof to release a pending intent; multiple candidates, changed identity, and incomplete or unreadable inventory preserve the record without touching terminals.
`status` is read-only and reports a pending intent that carries a recorded handle as `terminal=recoverable` when that exact identity is live, `terminal=absent` when the complete absence proof succeeds, and `terminal=uncertain` when the probe is incomplete, mismatched, or still handle-less; it never reports such an intent as `terminal=dead` merely because its target field is `pending`.
A fresh ambiguous create is never retried inside the same invocation.
A create whose daemon identity was recorded counts as a started session, so a later probe failure keeps the away flag and the freshly cleared escalation artifacts instead of restoring a previous session's buffer that the adopted or refreshed daemon would then deliver.
An entirely lost response or legacy intent with no recorded daemon identity always remains uncertain, even with no title matches; automatic adoption and retry are forbidden.
A create receipt whose handle is the primary's is refused the same way: the parent terminal is never the daemon's, so it is never adopted or closed.
`stop` and `reconcile` recognise the Orca lifecycle from the recorded terminal and the daemon lock's owner marker, not from the invoking shell's `SQUAD_SUPERVISOR_BACKEND`, so a stop without that variable still refuses an unrecorded daemon or an unresolved native request instead of reporting completion.
Remote Orca targets are refused because the local receiver/process ownership proof does not apply to a remote host.

The native protocol in `bin/sq-supervisor-native.sh` binds requests and consumption acknowledgements to a backend-neutral endpoint object, receiver process identity, and receiver-session nonce.
The Pi receiver in `.pi/extensions/lib/sq-away-native.ts` checks actual idle, editor-draft and open-modal state before calling the supported message API.
Adding another harness requires its own equally proven native receiver, not a different task owner or a redesign of the endpoint shape.
Publication, queued messages, ambiguous sends, process death, receiver-session replacement, and reconnects are never treated as consumption or permission to replay.
Only an exact consumption acknowledgement retires the covered buffer prefix; an unresolved request stays unresolved, including across restarts.
Settlement is per exact primary: while a request published for any other primary is still unresolved, `start`, `stop`, and `reconcile` refuse rather than clear the shared escalation buffer it covers.
This deliberately prioritizes avoiding duplicate effects over automatic recovery: stop reports failure and preserves lifecycle state while delivery or endpoint cleanup is uncertain.
Inspect and reconcile that evidence before retrying; unresolved records are never deleted from a script or a flag to force a resend.

### Permanent-uncertainty recovery (explicit human approval)

Some records never resolve on their own.
A request published before a primary restart keeps the dead receiver-session nonce, so the exact-match acknowledgement can never accept it, and `start`, `stop`, and `reconcile` keep refusing while it exists.
A recorded creation with no daemon identity, several identity candidates, a changed parent binding, or no authoritative inventory also remains unresolved; proven absence of a recorded identity instead uses the launcher's automatic recovery above.
That is the intended fail-closed state: Squad never abandons, deletes, or replays a possibly accepted operation, and no flag adds one.

The only sanctioned recovery is the named, human-approved permanent-uncertainty recovery below, performed by an operator on one exact record.

1. Name the record: `state/.afk-daemon-terminal` for a recorded creation (a `pending` target plus whatever daemon identity the create receipt recorded), or `bin/sq-supervisor-native.sh dir <state> <exact-primary-target>` for the request directory holding `request.json` and `result.json`.
2. Read it and have the commander, as the base's session owner, confirm on the live host/primary whether that exact recorded daemon identity (handle, runtime, incarnation, worktree/path) exists or whether that exact message text was delivered and consumed; a terminal title is display-only and proves nothing.
3. Only with explicit approval for that specific record: for a creation, use the guarded pending-creation release procedure below, never title-based absence or hand deletion; for a native request, remove the `request.json` plus `result.json` pair and drop exactly the `lines` prefix recorded in that request from the head of `state/.subsuper-escalations`, so the never-delivered text cannot be republished.
4. Record the approver, the exact target, and the removed record id in the away-mode report.

#### Approved pending-creation release

After the commander approves one exact pending record, an operator uses `bin/sq-afk-launch.sh release-pending` for a recorded daemon identity or `bin/sq-afk-launch.sh release-handle-less` when no identity was recorded.
Both actions require the recorded base path to match this base and refuse while a live daemon process owns the session.
A handle-less intent is never automatically recovered, even with zero title matches.
The guarded actions perform the following read-only proof before clearing anything:

1. Check the live runtime: `orca status --json` must report `reachable=true`, `state="ready"`, and a non-empty runtime identity; a handle-less intent additionally requires its recorded `parent.runtime` to match.
2. Enumerate every live terminal: `orca terminal list --limit 10000 --json` must report `ok=true`, the current runtime's `_meta.runtimeId`, `result.truncated=false`, an empty `result.hostScope.omittedHostIds`, and non-empty string `handle`, `worktreeId`, and `worktreePath` fields for every terminal.
3. For an identity-bearing intent, refuse and name its recorded daemon handle if that handle appears anywhere in the inventory, even if the runtime, incarnation, worktree, or task claim changed.
4. Cross-check every `state/*.meta` endpoint: `terminal=` for `backend=orca`, otherwise `window=`, refusing unreadable, symlinked, or ambiguous Orca task records rather than treating them as complete claims.
5. Report and refuse every unclaimed live handle whose `worktreeId` equals `parent.worktree` or whose `worktreePath` equals `parent.path`, excluding only the recorded primary `parent.target` and task-claimed terminals.
6. Release an identity-bearing intent only when its recorded daemon handle is absent AND no unclaimed binding candidate exists, then settle the recorded primary's native request before clearing the pending record and `state/.afk`; the handle-less action requires the same no-candidate census.

Runtime or incarnation mismatch is never a release trigger: live evidence showed the same handle and incarnation surviving a runtime change.
The actions log the release/refusal branch and candidate handles, never create, adopt, retitle, signal, or close a terminal, and never infer identity from a title.
Incomplete or ambiguous evidence refuses and preserves the record; neither command is an automatic recovery fallback.

Any doubt that the text or terminal was delivered or consumed leaves every file in place and the lifecycle reported as not complete; removal never authorizes a resend.

Verification separates lifecycle from message consumption: Linux Orca **1.4.243** with real interactive **Pi 1.4.0** passed start, live status, repeated start without a duplicate terminal, stop, and a second start/stop in an isolated task copy with private lifecycle state.
Pi **1.1.0** separately supplied editor/modal and native consumption proof on an isolated PTY with a **fake Orca identity CLI**.
Combined real-host message consumption, macOS supervisor behavior, Chat UI eligibility, and physical Android acceptance remain unverified.
The installed host has shared live terminals, so live probes must have explicit authorization, use only exact lab-owned terminals and private state in a disposable copy, and leave no daemon running; they must never restart or reconfigure the shared host.
[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the exact refresh commands and evidence limits.

## Active limits

- Orca is explicit-only as a task backend on macOS and Linux.
- The Orca runtime must report ready: the desktop app on macOS, or `orca serve` on Linux.
- XO spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- For spawn and cleanup identity, only the observed terminal, tab, and worktree result fields are accepted and speculative response shapes there are rejected: a mission tab is accepted only when `surface=visible`, `tabId` is present, and `worktreeId` is exactly the requested hosting workspace, as the [live 1.4.243 creation observation](verification/runtime-backends.md#2026-10-28---live-orca-14243-terminal-create-observation) records; the blocked-prompt `agentWait` read below is the single documented exception, and every position it probes is treated as unverified.
- The terminal inventory response the launcher reads is the complete `orca terminal list --limit 10000 --json` (`truncated`, `hostScope.omittedHostIds`, `terminals[].handle/incarnationId/worktreeId/worktreePath`).
  The earlier worktree-filtered read-only observation of `orca terminal list` and the installed `orca terminal create --help` flags were recorded on 2026-10-25 and are retained in [`verification/runtime-backends.md`](verification/runtime-backends.md#orca).
  Exact identity-based create/cleanup and the Pi daemon lifecycle were subsequently verified on Linux Orca 1.4.243; focus behavior remains unverified, and any unexpected or incomplete inventory preserves the pending intent instead of permitting recovery.
- Busy-expiry cannot be evaluated: the complete-viewport read is unverified, so a static busy claim logs a named limitation and never escalates from a tail ([architecture](architecture.md)).
- Orca does not expose the event stream used by Herdr; blocked-prompt detection polls `agentWait` and degrades to the existing sentry fallback when that observation is not available.
  The non-null `agentWait` record's shape and meaning are **unverified**: only the absent value (`agentWait=null`) has been observed on a real terminal, so it is unknown whether every non-null record means a human must answer or whether it can also describe an operator parked at its composer between turns.
  The read looks for the record under `result.observation.agentWait` and keeps two speculative fallback positions (`result.agentWait`, `result.terminal.agentWait`) for robustness; none of them is a verified shape, and an absent field is read as unknown rather than as no prompt.
  This path is exercised by the fake-CLI suite only, which establishes call shape and this adapter's own behavior, never end-to-end Orca behaviour; treat a blocked escalation as unproven until a safe isolated real-runtime observation confirms the record's semantics.

## Regression entry points

```sh
tests/sq-backend-orca.test.sh
tests/sq-sentry-triage.test.sh
tests/sq-afk-orca.test.sh
tests/sq-afk-orca-live-optin.test.sh
tests/sq-backend.test.sh
tests/sq-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
