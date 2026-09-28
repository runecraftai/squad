# TUIOS runtime backend

TUIOS is an experimental terminal-session backend. It owns terminal sessions and windows only; Squad and fob continue to own task identity, task state, and isolated git worktrees. Shared backend selection and metadata semantics are documented in [`configuration.md`](configuration.md#runtime-backend-configbackend--squad_backend).

## Setup

Install TUIOS 0.8.0 or newer and `jq`, and ensure `fob` is available as required by the normal session-provider contract. Select it explicitly with local `config/backend` containing `tuios` or `SQUAD_BACKEND=tuios`. TUIOS is never auto-detected.

Set `SQUAD_TUIOS_SESSION` explicitly to a TUIOS session that the Squad base is authorized to use. The adapter only validates and uses that existing session; it never creates, adopts, restarts, or deletes a session. It does not use ambient `TUIOS_SESSION`, so an unrelated terminal session is not selected accidentally.

TUIOS task windows are created without requesting focus. Each task target is `<session-name>:<opaque-window-id>`, and the exact session and opaque window id are recorded in the task metadata. Cleanup closes only the recorded task window, never a session. Squad refuses malformed, ambiguous, duplicate, or task-mismatched endpoint records.

## Task control and delivery

Capture and terminal operations address the exact recorded window. Pi and pi-signed tasks use Squad's existing task-private Pi delivery dropbox first; the TUIOS UI submit path cannot prove that a message was accepted and always returns an uncertain-delivery result. Do not resend through the UI when delivery is uncertain.

TUIOS does not currently provide a recovery-grade Squad busy or composer signal. Unknown state remains unknown. Recovery treats an agent as alive only when the exact TUIOS window and matching agent inventory corroborate one another; a process-presence hint alone is not enough. Inventory read failures and contradictions remain unreadable or ambiguous, not proof of absence.

## Limits and verification

This backend is experimental. The portable contract is covered by `tests/sq-backend-tuios.test.sh` using a fake CLI; that test never contacts or changes a live TUIOS session. Do not use the watched primary sessions for backend tests. Real-session lifecycle, restart, permissions, and Pi delivery evidence must be collected in a separately authorized disposable session before treating those behaviors as live-verified.
