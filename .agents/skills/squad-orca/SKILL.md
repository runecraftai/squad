---
name: squad-orca
description: Agent-only operator checklist for Squad's Orca runtime backend. Use when switching to Orca, spawning or supervising Orca-backed work, smoke-testing Orca backend behavior, debugging Orca task state, or reconciling Orca-backed task metadata.
user-invocable: false
metadata:
  internal: true
---

# squad-orca

Use this as the operator checklist for Squad's experimental Orca runtime backend.
It does not replace `AGENTS.md`, `docs/orca-backend.md`, or `harness-adapters`.

Orca is a runtime backend, not an agent harness.
The runtime backend owns the task endpoint and, for Orca, the task worktree.
The harness is the agent process launched inside that endpoint, such as `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, or `kimi`.
Load `harness-adapters` for harness-specific launch, interrupt, resume, trust-dialog, and skill-invocation facts.

Implementation details, metadata fields, teardown guarantees, and limitations live in `docs/orca-backend.md`.
`docs/verification/runtime-backends.md` "Orca" owns active smoke evidence.
Prefer the `bin/sq-*` helpers over raw `orca` commands.
Use raw `orca` only when the helper surface cannot answer the inspection question, and keep the recorded Squad metadata as the task identity.

## Preflight

Work from the current Squad base or repo root.
If `SQUAD_BASE` is set, remember that operational state lives under `$SQUAD_BASE` while the helper scripts still run from this repo's `bin/`.

Before switching or spawning against Orca:

- Confirm Orca is intentionally selected through `--backend orca`, `SQUAD_BACKEND=orca`, or local `config/backend`.
- Confirm the Orca app is running and the backend readiness checks pass before expecting spawn to work.
- Inspect active `state/*.meta` records before changing backend selection.
- Treat a backend switch as affecting future spawns only; existing tasks keep their recorded backend.
- Reconcile sentry wakes before unrelated work, especially if Orca tasks are already in flight.

## Spawn

Use `bin/sq-spawn.sh` so Squad creates the brief, worktree, terminal, metadata, status file, and sentry surface together.
Pass `--backend orca` for a one-off Orca task, or rely on the already-selected Orca backend when that selection is intentional.

After spawn, check the task with Squad helpers:

- `bin/sq-peek.sh sq-<id>` for launch failures, trust dialogs, or first output.
- `state/<id>.meta` for `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`.
- `bin/sq-crew-state.sh <id>` when the current run state matters.
- `bin/sq-sentry.sh` whenever there are tasks in flight and this session owns supervision.

Do not manually create the Orca worktree or terminal for a normal Squad task.
Do not manually patch metadata to make an externally-created Orca terminal look like a Squad task.

## Supervision

Use `bin/sq-peek.sh`, `bin/sq-send.sh`, `bin/sq-crew-state.sh`, and `bin/sq-teardown.sh` for routine operation.
For steer messages, send short lines through `bin/sq-send.sh <id> '...'`; the stable `sq-<id>` alias also works.
Put long instructions in the task brief or a temporary file and point the operator at that file.

When supervising, treat `state/<id>.meta` as the routing record and Orca's own ids as backend implementation details.
The stable Squad alias is `sq-<id>`.
The recorded `terminal=` and `orca_worktree_id=` fields are what backend helpers use under the hood.

If `sq-send` fails to submit, do not immediately repeat the same long instruction.
Peek first, then decide whether the target is busy, waiting on a prompt, stuck behind a popup, or genuinely wedged.
For harness-specific interrupts or exits, load `harness-adapters`.

## Recovery

For a messy Orca-backed task:

1. Read `state/<id>.meta` and the relevant status tail first.
2. Confirm the task is actually Orca-backed before using Orca-specific assumptions.
3. Use the recorded `terminal=`, `orca_worktree_id=`, and `worktree=` as the task identity.
4. Prefer Squad helpers for peek, send, state, and teardown.
5. Avoid raw deletion of Orca worktrees or manual branch cleanup.
6. Stop and inspect if the recorded worktree path, Orca worktree id, or project checkout no longer matches expectations.

Teardown remains governed by the normal Squad landing rules.
Recon work can be torn down after the report exists and the `decision-hold-lifecycle` completion gate passes.
Ship work can be torn down only after the work is landed by its project mode.

## Smoke Test

Keep Orca smoke tests focused on lifecycle plumbing:

1. Select Orca intentionally for a disposable task or recon.
2. Spawn through `bin/sq-spawn.sh`.
3. Confirm metadata records the Orca backend, terminal, Orca worktree id, and isolated worktree path.
4. Verify `bin/sq-peek.sh`, a short `bin/sq-send.sh` steer, sentry wake behavior, and `bin/sq-crew-state.sh`.
5. Tear down through `bin/sq-teardown.sh` after the task is safely disposable or landed.
6. Restore the previous backend selection if Orca was selected only for the smoke test.

Do not mix a backend smoke test with unrelated feature work.
