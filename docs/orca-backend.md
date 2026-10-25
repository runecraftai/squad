# Orca runtime backend

Orca is an experimental backend on macOS and Linux in which the Orca app owns both the task worktree and terminal endpoint.
The operator harness remains the agent process launched inside that endpoint.
Squad agents load [`squad-orca`](../.agents/skills/squad-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca app and want Orca-managed worktrees and terminals instead of FOB plus a session multiplexer.
Orca runs on macOS and Linux, is explicit-only, and does not support XO spawns.

Prerequisites:

- macOS: `/Applications/Orca.app` installed, running, and ready, with the CLI installed via `brew install orca`.
- Linux: the Orca release asset installed (`orca-linux.AppImage`, or `orca-ide_<version>_amd64.deb`) with an `orca` CLI on PATH - either a symlink to the AppImage (for example `~/.local/bin/orca -> orca-linux.AppImage`) or the native `orca-ide` binary that `orca serve` self-installs.
- Linux runtime: start the supported headless runtime with `orca serve` (for example `orca serve --port 6768 --json`) instead of opening the desktop app; a ready `serve` process satisfies exactly the same readiness gate below.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `SQUAD_BACKEND=orca` for one launch, or an explicit request to Squad.
It is never auto-detected.

Before any spawn mutates repository state, Squad requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/sq-peek.sh <id>` and `SQUAD_BASE=<home> bin/sq-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
`sq-spawn.sh` does not call FOB for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=sq-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Squad alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.
On macOS builds `orca_worktree_id=` records a bare atom (UUID).
On Linux builds (verified against v1.4.188) it records the composite form `<repo-id>::<absolute-path>`, which cleanup accepts alongside the bare form and validates structurally.

## Current lifecycle and safety

Spawn validates that any existing metadata file is regular, registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Non-regular metadata (for example a directory left by a prior interrupted attempt) is refused before any Orca resource is created.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

`sq-peek.sh` reads with `orca terminal read`.
For non-Pi targets, or when native Pi delivery is unavailable, `sq-send.sh` types and verifies composer clearance, follows `oldestCursor` when Orca returns a limited page, and retries Enter without retyping when a slash popup first fills an argument placeholder.
A bare shell row is `unknown`, not an empty agent composer.
Pi operators launched from a positional brief complete their turn and exit to the shell instead of idling at a composer, so on Linux they never render the bordered composer row the clearance classifier verifies against.
When native Pi delivery is unavailable, a steer sent while such an operator is mid-turn is delivered and queued - verified live on v1.4.188, the terminal shows the queued message and the operator later acts on it - but verification still returns `unknown` and `sq-send.sh` exits reporting delivery unconfirmed.
That verdict stays genuinely unconfirmed either way: peek the terminal before acting on it, and never resend blindly, because the same `unknown` also covers text parked at an exited operator's bare shell prompt.
The sentry has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Squad safety checks.
A recon still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Squad closes the exact terminal and releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Away-mode supervision

An Orca-hosted primary is explicit-only: launch the primary with `SQUAD_SUPERVISOR_BACKEND=orca` and `SQUAD_SUPERVISOR_TARGET=<exact runtime-issued terminal handle>` already set.
The target must be a connected, writable, non-orphaned local terminal whose worktree path is the physical `SQUAD_BASE` directory.
This selection is independent of `config/backend`; changing task placement is not required.
Do not select a currently active tab by name, attach another multiplexer as evidence of native mobile support, or infer a primary from an operator's terminal.

Only the interactive **Pi** receiver is enabled initially.
`pi-signed`, Claude, Codex, OpenCode, Grok, Kimi, Muse, and unknown harnesses are refused by name before away-mode state or endpoints are created because their native draft/modal safety and consumed-message acknowledgement have not been proven for this integration.
Load the shipped `.pi/extensions/sq-primary-away-handoff.ts` in the selected primary and let that primary acquire the base's session ownership before entering away mode.
A missing, stale, foreign-process, foreign-endpoint, or replaced-incarnation readiness record refuses rather than falling back to terminal typing.
A bare shell cannot publish native readiness.

Use `bin/sq-afk-launch.sh start`, `status`, `stop`, and `reconcile` for the lifecycle.
The create call passes **no focus flag** and never splits the primary, creates or removes a worktree, or stops the runtime.
Whether Orca focuses, keeps, or hides the new terminal tab is real host behaviour that remains **unverified**, so treat the daemon terminal as possibly visible or focused.
The creation intent is recorded before the CLI call, and cleanup requires the exact terminal handle, runtime and terminal incarnation, worktree identity/path, and unique title.
A live daemon process must additionally match the recorded launch token and operating-system process identity before it can be signalled.
Uncertain creation remains recorded and blocks another creation; reconciliation may recover only the exact uniquely titled endpoint, never sweep other terminals.
Remote Orca targets are refused because the local receiver/process ownership proof does not apply to a remote host.

The native protocol in `bin/sq-supervisor-native.sh` binds requests and consumption acknowledgements to a backend-neutral endpoint object, receiver process identity, and receiver-session nonce.
The Pi receiver in `.pi/extensions/lib/sq-away-native.ts` checks actual idle, editor-draft and open-modal state before calling the supported message API.
Adding another harness requires its own equally proven native receiver, not a different task owner or a redesign of the endpoint shape.
Publication, queued messages, ambiguous sends, process death, receiver-session replacement, and reconnects are never treated as consumption or permission to replay.
Only an exact consumption acknowledgement retires the covered buffer prefix; an unresolved request stays unresolved, including across restarts.
This deliberately prioritizes avoiding duplicate effects over automatic recovery: stop reports failure and preserves lifecycle state while delivery or endpoint cleanup is uncertain.
Inspect and reconcile that evidence before retrying; unresolved records are never deleted from a script or a flag to force a resend.

### Permanent-uncertainty recovery (explicit human approval)

Some records never resolve on their own.
A request published before a primary restart keeps the dead receiver-session nonce, so the exact-match acknowledgement can never accept it, and `start`, `stop`, and `reconcile` keep refusing while it exists.
A recorded-but-unresolvable creation with a unique title that matches zero or several terminals behaves the same way.
That is the intended fail-closed state: Squad never abandons, deletes, or replays a possibly accepted operation, and no flag adds one.

The only sanctioned recovery is the named, human-approved permanent-uncertainty recovery below, performed by an operator on one exact record.

1. Name the record: `state/.afk-daemon-terminal` for a recorded creation (`pending` target plus the recorded unique title), or `bin/sq-supervisor-native.sh dir <state> <exact-primary-target>` for the request directory holding `request.json` and `result.json`.
2. Read it and have the commander, as the base's session owner, confirm on the live host/primary whether that exact recorded terminal title exists or whether that exact message text was delivered and consumed.
3. Only with explicit approval for that specific record: for a creation, close that one matching terminal through Orca, or remove just the pending creation record when nothing matches; for a native request, remove the `request.json` plus `result.json` pair and drop exactly the `lines` prefix recorded in that request from the head of `state/.subsuper-escalations`, so the never-delivered text cannot be republished.
4. Record the approver, the exact target, and the removed record id in the away-mode report.

Any doubt that the text or terminal was delivered or consumed leaves every file in place and the lifecycle reported as not complete; removal never authorizes a resend.

Verification is split explicitly: Linux Orca **1.4.188** supplied the read-only runtime/terminal identity schema; interactive **Pi 1.1.0** supplied real editor/modal and native consumption proof on an isolated PTY with a **fake Orca identity CLI**.
No combined real Orca + Pi supervisor/AFK lifecycle, macOS supervisor, Chat UI eligibility, or physical Android acceptance is claimed by those separate checks.
The installed host has shared live terminals, and its documented `serve` options do not prove a separate user-data/profile boundary; a different port or project root alone is not isolation.
A disposable real-host probe therefore requires a proven independent Orca profile/runtime before launch, without restarting or reconfiguring the shared host.
[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the exact refresh commands and evidence limits.

## Active limits

- Orca is explicit-only on macOS and Linux.
- The Orca runtime must report ready: the desktop app on macOS, or `orca serve` on Linux.
- XO spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- The worktree-filtered `orca terminal list` response (`truncated`, `hostScope`, `terminals[]`), the `orca terminal create --worktree/--command` flags, and every real create/cleanup path remain unproven: no read-only receipt for them is retained, so any unexpected shape is an uncertain outcome that preserves the pending record instead of recovering.
- Busy-expiry cannot be evaluated: the complete-viewport read is unverified, so a static busy claim logs a named limitation and never escalates from a tail ([architecture](architecture.md)).

## Regression entry points

```sh
tests/sq-backend-orca.test.sh
tests/sq-afk-orca.test.sh
tests/sq-afk-orca-live-optin.test.sh
tests/sq-backend.test.sh
tests/sq-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
