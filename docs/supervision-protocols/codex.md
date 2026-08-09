Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/sq-stand-to-drain.sh`.
2. Source `__SQUAD_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground sentry checkpoint with `bin/sq-sentry-checkpoint.sh --seconds "${SQUAD_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
6. Never use shell `&` or Codex background tasks for Squad sentry supervision.
7. Do not run `bin/sq-sentry-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/sq-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
