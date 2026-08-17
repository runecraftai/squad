# Squad Operations Board (tmux sidebar)

`bin/sq-sidebar.sh` renders a per-operator card sidebar in tmux panes, powered by Squad ground truth instead of screen reading.
It is the Operations Board: a session-scoped tmux sidebar that shows operator status, enables quick navigation, and surfaces attention-needing operators.
The sidebar is a pure consumer of the ground-truth contract: it reads `state/window-states` (published by `bin/sq-window-state.sh`, whose header owns the file contract), `state/<id>.meta`, `state/<id>.busy-gen`, and `state/<id>.status`.
It never reads screens and never maps Squad verbs itself: `bin/sq-window-state.sh` owns the verb to label translation and `bin/sq-classify-lib.sh` owns the status vocabulary.

The script header owns the full command, environment, and behavior reference.
This page covers setup, usage, and the interface contract with the machine-side scripts.

## Session scoping

The sidebar is session-scoped by construction.
All tmux hooks, options, and pane operations target the current session only.
Global keybindings (C-M-s/n/a/f/d/l) work from any session, but sidebar-local keys (j/k/Enter/g/G/v/f/q) are intercepted only when the current session has an active sidebar pane.
This prevents the sidebar from leaking into other concurrent tmux sessions.

Toggle the sidebar on in one session; open a second tmux session side by side.
The second session must show no sidebar pane and its keys must pass through normally.
Toggle the sidebar off in the first session; the second session remains unaffected.

## Global sidebar (workmux parity)

When toggled on, a sidebar pane is created in EVERY tmux window of the CURRENT SESSION and a session-scoped tmux hook (`after-new-window`) auto-adds sidebar panes to newly created windows in that session.
When toggled off, all sidebar panes in the session are killed and the hook is removed.
Every sidebar pane renders the same ground-truth data; the pane placement is per-window, the data is not.

This matches workmux's default sidebar behavior: the sidebar is always visible across all windows without needing to toggle per-window, but scoped to the current session to prevent cross-session interference.

## Layout modes

Two layout modes are supported, toggled live with the `v` key in a focused sidebar pane or via `bin/sq-sidebar.sh layout`:

- **tiles** (default) - two-line cards with status stripe, matching the original card model
- **compact** - one-line per card showing glyph, id, elapsed, label, and detail

The compact template is configurable via `SQ_SIDEBAR_COMPACT_LINE` (default `{glyph} {id} {elapsed} {label} {detail}`).
Layout preference is persisted in the `@sq-sidebar-layout` tmux global option.

## Layout

The sidebar pane is laid out top to bottom, and every section can be turned off by an environment variable:

- **Rollup** - one line per tmux session showing that session's worst (most-actionable) operator state, a colored icon, and the operator count.
  A session with any attention operator surfaces that state here, so a glance at the rollup tells you whether the whole unit is healthy.
  Disable with `SQ_SIDEBAR_NO_ROLLUP=1`.
- **INBOX** - the operators needing commander attention (awaiting-decision, blocked, failed), sorted most-actionable first, under an `INBOX` header.
  They sit above the routine cards, so what needs you is always at the top.
  Disable with `SQ_SIDEBAR_NO_INBOX=1` (this also reverts to plain window-order sorting).
- **Cards** - one two-line card per remaining operator (working, idle, done, unknown), sorted by window target.
  In compact mode, each card is one line instead of two.

The actionability ordering (failed, blocked, awaiting-decision, unknown, working, idle, done) and the INBOX membership set (awaiting-decision, blocked, failed) are the sidebar's own rendering policy - the ground truth only supplies labels.

## Card model

Each operator renders as one card of two display lines (tiles mode) or one line (compact mode), and both line templates are configurable:

- Line 1 is `SQ_SIDEBAR_LINE1` (default `{glyph} {id}{elapsed}{unread}`): a spinner while the operator is working, a static state icon otherwise, the mission id, wall-clock elapsed time, and the unread glyph when a done card is unacknowledged.
- Line 2 is `SQ_SIDEBAR_LINE2` (default `{label} {detail}`): the sidebar-facing state label (working, awaiting-decision, blocked, done, idle, failed, unknown) and the reconciled current-status prose from `state/window-states`.
- Compact line is `SQ_SIDEBAR_COMPACT_LINE` (default `{glyph} {id} {elapsed} {label} {detail}`): all tokens on one line.

Tokens: `{glyph}` (the state icon; spinner while working), `{id}` (left-padded to 12), `{label}`, `{state}` (the canonical Squad verb), `{detail}` (prose, or `model·effort` when there is no prose), `{elapsed}` (right-padded to 8 when present), `{model}`, `{effort}`, `{unread}` (the unread glyph on a done card not yet acknowledged, else empty), `{window}`, `{session}`.
Unknown tokens pass through unchanged, so a template with a typo is visible rather than silently blank.

The label and state names come verbatim from the ground-truth contract; the sidebar only picks glyphs, colors, and the actionability ordering per label.
Elapsed time is a simple honest approximation: wall-clock since the task's busy contract was armed (`state/<id>.busy-gen` mtime, written once at spawn), falling back to the meta file's mtime.
It is not billing-grade, and the sidebar does NOT compute session cost: when a card has no detail prose, line 2 shows the recorded `model=` and `effort=` meta tags as the cost context instead.
See `bin/sq-busy-event.sh` for who arms the busy contract and `bin/sq-crew-state.sh` for what the reconciled prose means.

The two-lines-per-card layout (tiles) or one-line-per-card (compact) is the layout constant the script owns; `click` resolves a rendered pane line to its card's window through the same frame the renderer emits, so the mapping stays exact even with the rollup, INBOX header, and separator lines in between.
The renderer truncates every line to the pane width minus one, so a card never wraps.

## Unread done markers

A `done` card shows the unread glyph (`SQ_SIDEBAR_UNREAD`, default `●`) until the commander acknowledges it.
`bin/sq-sidebar.sh ack` (the `C-M-a` key) writes `state/<id>.sidebar-ack` for every currently-done task, and a done task is unread while that marker is missing or older than the task's last status-log append (`state/<id>.status` mtime).
A task that finishes, is acknowledged, and finishes again becomes unread again.
The same dot appears on the window-tab badge.

## Window tab badge

The loader sets `window-status-format` and `window-status-current-format` to prepend a colored state icon (plus the unread dot) to each tmux window tab.
`bin/sq-sidebar.sh badge <session:window>` emits the icon for a window, so the tab badge reflects the same ground truth as the sidebar.
The badge uses the always-static icon, not the spinner, since status-line formats re-evaluate on the status interval rather than per frame.

## Pane lifecycle cleanup

Cards disappear automatically when a mission is torn down: the ground-truth file (`state/window-states`) drops entries whose meta file is gone, so the next render no longer shows the card.
The sidebar pane itself is killed when its host window is killed (standard tmux behavior).
No explicit cleanup step is needed; the ground-truth contract handles card lifecycle.

## Requirements

- tmux 3.2 or newer (pane user options, `if-shell -F`, and the `#{e|+|:...}` and `#{q:...}` click formats are required; verified on 3.7).
- A UTF-8 terminal for the spinner and state glyphs; `SQ_SIDEBAR_SPINNER` can replace them with ASCII frames.
- A Squad base with tmux task windows; the sidebar shows nothing when `state/window-states` is absent or empty.

## Session isolation verification

After toggling the sidebar on in one session, verify cross-session isolation:
1. Open a second tmux session: `tmux new-session -s test-isolation`
2. Confirm the second session has no sidebar pane and keys pass through normally
3. Toggle sidebar off in the first session; confirm the second session is unaffected
4. Close the test session: `tmux kill-session -t test-isolation`

## Install and load

The plugin loads as a `.tmux` shell script, the same way tmux plugin managers run plugins.
Put this repo (or a plugin checkout of it) on the machine and add one line to `~/.config/tmux/tmux.conf`:

```conf
run-shell "/home/you/squad/tmux/sq-sidebar.tmux"
```

The loader binds the keys, the click action, and the window-tab badge, and records the tool path in the global `@sq-sidebar-path` option.
Do not use `tmux source-file` on the loader: the loader is shell, not tmux config syntax.

## Usage

### Global keybindings (work from any pane)

| Key | Action |
| --- | ------ |
| `C-M-s` | Toggle the global sidebar on/off (all windows) |
| `C-M-n` | Focus the next operator needing attention (cycles the INBOX set) |
| `C-M-a` | Acknowledge every currently-done operator (clears their unread dots) |
| `C-M-f` | Cycle the filter: all, awaiting-decision, blocked, failed, working, idle, done |
| `C-M-d` | Jump to the most recently completed/attention-needing operator (cycles reverse-chronologically) |
| `C-M-l` | Toggle between current and last visited window (like vim's Ctrl-^) |

### Sidebar-local keybindings (when the sidebar pane is focused)

These keys are intercepted only when the current session has an active sidebar pane; in other sessions, they pass through normally.

| Key | Action |
| --- | ------ |
| `j` | Navigate down (select next card) |
| `k` | Navigate up (select previous card) |
| `Enter` | Jump to the selected agent's pane |
| `g` | Jump to the first agent |
| `G` | Jump to the last agent |
| `v` | Toggle layout mode (tiles/compact) |
| `f` | Toggle session filter |
| `q` | Close the sidebar in current session (with quit confirmation) |

The pane shows the rollup, the INBOX, and one card per operator window, and re-renders every second; the ground truth it reads is re-published every two seconds.
Click a card with the mouse to focus that operator's tmux window.
The click resolves the operator base from the `@sq-sidebar-base` pane option the sidebar records at start, so it works from any base the toggle was launched with.
A click anywhere else in a pane keeps tmux's default behavior: it focuses the clicked pane and passes the mouse event through.

The filter (`C-M-f`, or `SQ_SIDEBAR_FILTER`) restricts the cards to one state label so you can isolate, for example, only `blocked` or only `awaiting-decision` operators.
The rollup is independent of the filter and always reflects the whole session.

### Dashboard-adjacent commands

| Command | Action |
| ------- | ------ |
| `sq-sidebar.sh last-done [BASE]` | Jump to most recently completed/attention operator; repeated invocations cycle reverse-chronologically |
| `sq-sidebar.sh last-agent` | Toggle between current and last visited window |
| `sq-sidebar.sh reap [BASE]` | List stale operators (last status older than threshold); display-only |
| `sq-sidebar.sh layout [BASE]` | Toggle tiles/compact layout mode |

`last-done` is similar to `next-inbox` (`C-M-n`) but orders by recency (most recent status-log mtime first) and includes done operators, while `next-inbox` cycles forward through only the attention set (awaiting-decision/blocked/failed).
Both are kept because they serve different navigation patterns: `next-inbox` for systematically clearing the attention queue, `last-done` for jumping to whatever just happened.

`reap` is a read-only display of stale operators; it is never wired to interrupt/kill/recovery actions.
The sentry's own stale-detection machinery (`docs/turnend-guard.md`) is separate and owns real recovery.

Customize with environment variables (all optional):

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `SQ_SIDEBAR_WIDTH` | `25` | Sidebar pane width in columns |
| `SQ_SIDEBAR_SPINNER` | braille frames | Space-separated spinner glyphs |
| `SQ_SIDEBAR_REFRESH_SECS` | `2` | Ground-truth re-publish cadence in the run loop |
| `SQ_SIDEBAR_FRAME_SECS` | `1` | Render cadence in the run loop |
| `SQ_SIDEBAR_LINE1` | `{glyph} {id}{elapsed}{unread}` | Line 1 token template per card (tiles mode) |
| `SQ_SIDEBAR_LINE2` | `{label} {detail}` | Line 2 token template per card (tiles mode) |
| `SQ_SIDEBAR_COMPACT_LINE` | `{glyph} {id} {elapsed} {label} {detail}` | Token template per card (compact mode) |
| `SQ_SIDEBAR_FILTER` | empty (`all`) | State label to restrict cards to |
| `SQ_SIDEBAR_UNREAD` | `●` | The unread glyph on an unacknowledged done card |
| `SQ_SIDEBAR_NO_COLOR` | unset | `1` disables ANSI styling (plain text) |
| `SQ_SIDEBAR_NO_ELAPSED` | unset | `1` hides the elapsed time column |
| `SQ_SIDEBAR_NO_ROLLUP` | unset | `1` hides the per-session rollup |
| `SQ_SIDEBAR_NO_INBOX` | unset | `1` hides the INBOX section and reverts to window order |
| `SQ_SIDEBAR_STALE_THRESHOLD` | `4` | Hours for `reap` stale detection |

For a machine-side toggle or auto-open script, call `bin/sq-sidebar.sh toggle [BASE]` directly; the loader's `C-M-s` binding is exactly that command.

## Interface contract with the machine-side scripts

- `~/.local/bin/sq-sidebar-start.sh` (machine) owns the auto-open-on-boot and toggle flow; the follow-up machine swap re-points it at `bin/sq-sidebar.sh toggle [BASE]`, and it must not bind the keys a second time because the loader owns them.
- The powerkit agent-count segment reads `bin/sq-sidebar.sh cards [BASE]` (one raw TAB-separated record per card: window, id, label, state, detail, elapsed, model, effort) or `state/window-states` directly; the follow-up machine swap decides which.
- `bin/sq-sidebar.sh inbox [BASE]` returns the same record shape, restricted to attention operators and sorted most-actionable first.
- `bin/sq-sidebar.sh map [BASE]` returns one window target per rendered line (empty for non-card rows), which is how a script can resolve a click to a window without re-deriving the layout.
- `bin/sq-status-notify.sh` is independent: it watches `state/<id>.status` for desktop notifications and focuses via the same `window=` targets, with no interface change.
- `state/window-states` remains owned by `bin/sq-window-state.sh`; the sidebar never writes it, it only calls `publish` and reads the file. The unread marker `state/<id>.sidebar-ack` is the sidebar's own private state, written only by `ack`.

## Limits

- The sidebar shows only tmux-backend task windows, matching what `bin/sq-window-state.sh` publishes; orca, herdr, zellij, cmux, and XO tasks have no tmux window to show.
- Keeping the sidebar pane at `SQ_SIDEBAR_WIDTH` keeps the click line mapping exact; manually resizing the pane can wrap lines and drift the mapping.
- The spinner advances with the render cadence and is driven by the clock, not by per-frame events; it is a visual state hint, not a progress meter.
- The mouse click path is exercised through tmux's documented mouse binding semantics (`{mouse}` targets and the `#{e|+|:#{mouse_y},1}` row conversion); the full click flow was smoke-verified manually, not by automated mouse injection.
- The window-tab badge shells out through `#()` on the status interval, so it refreshes on the status cadence rather than per frame.

## Future direction: ratatui TUI panel

The sidebar is deliberately a tmux-pane shell renderer because it had to ship without new runtime dependencies and reuse the existing ground-truth pipeline.
A ratatui-based TUI panel (in the style of opensessions and herdr's configuration surface) is a candidate follow-up phase, not part of this rework.

Evaluation:

- **Fits cleanly** for richer visuals - boxed cards, a real scrollable list, and mouse/keyboard navigation that a line-oriented shell renderer can only approximate.
- **Costs** - a compiled or crate-fetched binary (new dependency and a build/install step), plus a second consumer of `state/window-states` that would need to stay byte-compatible with the shell path during migration.
- **Recommendation** - keep `state/window-states` as the single data source and `bin/sq-sidebar.sh cards|inbox|map` as the contract, and have the ratatui panel consume those exact subcommands (or the file directly) rather than re-deriving state.
  Ship it as an opt-in alternative behind the same `C-M-s` toggle, gated by a feature flag, so the shell renderer stays the fallback until the TUI is proven on the commander's machine.
  This is worth doing only after the token/card model here is settled, since that is what a TUI would render first-class.

## Regression entry point

```sh
tests/sq-sidebar.test.sh
```
