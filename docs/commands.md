# Squad commands reference

[`AGENTS.md`](../AGENTS.md) section 8's "Tool usage rules (MANDATORY)" makes the replacements below a hard rule, not a style suggestion; this page is that rule's single owner for the full table, the banned-command list, and worked examples.
[`docs/scripts.md`](scripts.md) remains the authoritative one-line-per-script index of the whole `bin/` toolbelt; this page exists to make the specific replacements below hard to miss and hard to skip.
Each script's own header comment is the authoritative description of its flags and contracts, so read the header before first use rather than relying on this summary.
Five PreToolUse seatbelts mechanically enforce the sharpest-edged of these rules regardless of what the agent remembers: `bin/sq-cd-pretool-check.sh` blocks a persistent top-level `cd`/`pushd`/`popd` in the primary checkout ([`docs/cd-guard.md`](cd-guard.md)), `bin/sq-arm-pretool-check.sh` blocks a malformed or bypassed sentry-arm/checkpoint command ([`docs/arm-pretool-check.md`](arm-pretool-check.md)), `bin/sq-subagent-pretool-check.sh` blocks primary-session delegation outside the unit ([`docs/subagent-guard.md`](subagent-guard.md)), `bin/sq-backend-pretool-check.sh` blocks raw session-provider CLI control, and `bin/sq-poll-pretool-check.sh` blocks narrow `sleep`/`while` polling of `state/`.
Every other row in the table below is enforced by instruction and self-correction only; a weaker model still needs to catch and fix its own raw-command use, because no seatbelt exists for it.

## Index

| Command | When to use | Why not raw bash/tmux |
| --- | --- | --- |
| `bin/sq-window-state.sh list` | Check the state of every tracked task window at a glance | Derives ground truth from `state/<id>.status` and the harness busy state through `sq-crew-state.sh`, not from a raw `tmux list-windows` label that only proves a window exists |
| `bin/sq-window-state.sh publish` | Refresh the published `state/window-states` file a sidebar or script consumes | Writes the one atomic, parseable file other tooling relies on instead of leaving each caller to re-derive state itself |
| `bin/sq-crew-state.sh <id>` | Check one operator's current state before steering, escalating, or re-checking a decision | Reconciles the possibly-stale `state/<id>.status` event log against the authoritative drill run-step or pane busy-signature; a raw `tail -1` of the status file reports the last wake event, not the current state |
| `bin/sq-spawn.sh` | Launch an operator, recon, or XO | Resolves the harness, runtime backend, and an isolated task worktree, and asserts that isolation before launch; a manually created process or window skips every one of those checks |
| `bin/sq-send.sh <target> <text>` | Send a steer, decision answer, or key press to an operator | Resolves the target through recorded metadata, uses native Pi extension delivery for eligible metadata-routed local non-XO Pi or pi-signed tasks, otherwise verifies the line was actually submitted (retrying only the Enter, never the text), and marks XO-routed replies correctly; `tmux send-keys` does none of that and can silently swallow the Enter |
| `bin/sq-stand-to-drain.sh` | Drain the durable wake queue at the start of a wake-handling turn | Atomically drains queued sentry wake records, folds unit-wide open decisions, and asserts supervision health in one pass; hand-inspecting status files misses queued records and never asserts liveness |
| `bin/sq-status-notify.sh watch [BASE]` | Run desktop notifications for done/needs-decision/blocked/failed wake events | Watches the append-only status logs correctly (new lines only, focused-window suppression) instead of a hand-rolled poll loop |
| `bin/sq-session-start.sh` | Start or resume a session | Composes the lock, bootstrap, and wake-drain steps into one ordered, safe digest; running the pieces by hand risks acting on stale or partially locked state |
| `sq-gh` (`npx -y @runecraft/sq-gh ...`) | Any GitHub operation: issues, PRs, CI runs, releases, labels, gists, Projects, secrets, variables | Token-efficient, structured output with contextual next-step hints, purpose-built for agent use; prefer it over raw `gh` and always over hand-parsed `git`/API calls |
| `bin/sq-brief.sh` | Scaffold an operator brief, recon brief, or XO charter | Fills the standard Setup/Rules/Definition-of-done safety contract (worktree isolation assertion, status protocol, delivery-mode contract) that a hand-written brief would have to reproduce correctly from scratch |
| `bin/sq-teardown.sh <id>` | Clean up a finished task | Refuses when work has not landed (uncommitted changes, or commits unreachable from any remote and not covered by a merged PR), then removes the runtime endpoint and volatile state; a manual `rm`/`kill` skips that landed-work safety check entirely |

## Do not use raw commands for these operations

The following raw commands are banned wherever a Squad tool above covers the same operation.
Reach for the Squad tool first; refer to that script's own header when its exact flags matter.

- Never use `tmux list-windows` (or grep-ing `tmux list-windows` output) to check task state.
  Use `bin/sq-window-state.sh list`.
- Never use `tmux send-keys` to steer, answer, or interrupt an operator.
  Use `bin/sq-send.sh <target> <text>`.
- Never use raw `tmux` commands (`tmux kill-window`, `tmux new-session`, manually spawning a harness process, etc.) for operator lifecycle management.
  Use `bin/sq-spawn.sh` to launch and `bin/sq-teardown.sh` to retire.
- Never determine an operator's current status by `tail`-ing or `grep`-ing `state/<id>.status` by hand.
  Use `bin/sq-crew-state.sh <id>`; the status file is an append-only wake-event log, not current-state truth.
- Never poll or hand-parse `state/` files in a shell loop to watch for wake events.
  Use `bin/sq-stand-to-drain.sh` (queue drain) or `bin/sq-status-notify.sh watch` (desktop notifications).
- Never run raw `git push`/manual PR creation via the GitHub web UI or hand-built `curl` calls against the GitHub API.
  Use `sq-gh` (`npx -y @runecraft/sq-gh ...`).
- Never hand-delete a task's worktree, kill its process by PID, or `rm -rf` its state files to "clean up".
  Use `bin/sq-teardown.sh <id>`, which verifies the work has actually landed before removing anything.
- Never hand-write an operator brief from memory.
  Use `bin/sq-brief.sh` to scaffold it, then fill in the task-specific sections.

## Examples

### Checking whether work is done

Incorrect:

```sh
tail -1 state/sq-abc123.status
```

This reports the last wake event, which can be stale after a needs-decision or blocked gate has already been resolved and the operator has resumed.

Correct:

```sh
bin/sq-crew-state.sh sq-abc123
```

This reconciles the log against the authoritative run-step or pane signature and prints one deterministic `state: ...` line.

### Checking window/task overview

Incorrect:

```sh
tmux list-windows -t Squad
```

This only proves a tmux window exists; it says nothing about whether the operator inside it is working, parked, or stuck.

Correct:

```sh
bin/sq-window-state.sh list
```

### Steering an operator

Incorrect:

```sh
tmux send-keys -t Squad:sq-abc123 "please also add a test" Enter
```

`tmux send-keys` gives no confirmation that the Enter was actually submitted; a busy or popup-covered pane can silently swallow it.

Correct:

```sh
bin/sq-send.sh sq-abc123 "please also add a test"
```

`sq-send.sh` resolves the target from recorded metadata, uses native Pi extension delivery for eligible metadata-routed local non-XO Pi targets, and otherwise verifies submission and retries the Enter (never the text) if a swallowed submit is detected.

### Opening a pull request

Incorrect:

```sh
git push origin sq/my-branch
gh pr create --title "..." --body "..."
```

Correct:

```sh
npx -y @runecraft/sq-gh pr create --title "..." --body-file /tmp/pr-body.md
```

### Cleaning up a finished task

Incorrect:

```sh
rm -rf ~/fob-pool/sq-abc123
```

A raw `rm -rf` does not check whether the work has landed, and can destroy unlanded work irrecoverably.

Correct:

```sh
bin/sq-teardown.sh sq-abc123
```

This refuses when the branch's work is not reachable from a remote and not covered by a merged PR, so unlanded work is never silently discarded.

## See also

- [docs/scripts.md](scripts.md) - the complete `bin/` toolbelt reference, one purpose clause per script.
- [docs/tmux-backend.md](tmux-backend.md) - the tmux reference runtime backend's own setup and window-naming conventions, for the cases where inspecting a window directly by hand is still appropriate (attaching to watch, not to control).
- [docs/cd-guard.md](cd-guard.md), [docs/arm-pretool-check.md](arm-pretool-check.md), [docs/subagent-guard.md](subagent-guard.md) - the five PreToolUse seatbelts that mechanically enforce a subset of these rules.
- [`AGENTS.md`](../AGENTS.md) - the operating contract these tools implement; section 8 owns the supervision protocol and the mandatory tool-usage rule, section 7 owns the task lifecycle these commands drive.
