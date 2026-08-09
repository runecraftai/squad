# Orca runtime backend

Orca is an experimental macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The operator harness remains the agent process launched inside that endpoint.
Squad agents load [`squad-orca`](../.agents/skills/squad-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of FOB plus a session multiplexer.
Orca is macOS-only, explicit-only, and does not support XO spawns.

Prerequisites:

- `/Applications/Orca.app` installed, running, and ready.
- The `orca` CLI, installed with `brew install orca`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `SQUAD_BACKEND=orca` for one launch, or an explicit request to Squad.
It is never auto-detected.

Before any spawn mutates repository state, Squad requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/sq-peek.sh <id>` and `SQUAD_HOME=<home> bin/sq-send.sh <id> '<text>'`.
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

## Current lifecycle and safety

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

`sq-peek.sh` reads with `orca terminal read`.
`sq-send.sh` types and verifies composer clearance, follows `oldestCursor` when Orca returns a limited page, and retries Enter without retyping when a slash popup first fills an argument placeholder.
A bare shell row is `unknown`, not an empty agent composer.
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

- Orca is macOS-only and explicit-only.
- The app must be running and report ready.
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
