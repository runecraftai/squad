Mode: OpenCode TUI plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/sq-stand-to-drain.sh`.
2. First cycle: let `.opencode/plugins/sq-primary-sentry-arm.js` arm supervision after the OpenCode session goes idle.
3. The plugin listens for `session.idle`, spawns `bin/sq-sentry-arm.sh --restart` without awaiting it in the idle handler, and owns every later successor launch.
4. After an actionable child close, the plugin rechecks session-lock ownership and verifies one singleton successor before it calls `client.session.promptAsync`; its bounded fallback is defined in `docs/sentry-continuity.md`.
5. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
6. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a sentry failure instead of disappearing.
7. Failure or missing cycle only: if the plugin reports a sentry failure, drain queued wakes, inspect the failure text, and use `bin/sq-sentry-arm.sh` manually only as a short recovery probe.
8. Never use shell `&` for sentry supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/sq-primary-pretool-check.js`, `bin/sq-arm-pretool-check.sh`).
9. Do not rely on this plugin in headless `opencode run`; Squad primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and an XO's own home, and stays silent only in child operator and recon worktrees.
