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

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

`sq-peek.sh` reads with `orca terminal read`.
`sq-send.sh` types and verifies composer clearance, follows `oldestCursor` when Orca returns a limited page, and retries Enter without retyping when a slash popup first fills an argument placeholder.
A bare shell row is `unknown`, not an empty agent composer.
pi operators launched from a positional brief complete their turn and exit to the shell instead of idling at a composer, so on Linux they never render the bordered composer row the clearance classifier verifies against.
A steer sent while such an operator is mid-turn is delivered and queued - verified live on v1.4.188, the terminal shows the queued message and the operator later acts on it - but verification still returns `unknown` and `sq-send.sh` exits reporting delivery unconfirmed.
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

## Active limits

- Orca is explicit-only on macOS and Linux.
- The Orca runtime must report ready: the desktop app on macOS, or `orca serve` on Linux.
- XO spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.

## Regression entry points

```sh
tests/sq-backend-orca.test.sh
tests/sq-backend.test.sh
tests/sq-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
