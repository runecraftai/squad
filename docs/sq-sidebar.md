# Squad ground-truth tmux sidebar (sq-sidebar)

`bin/sq-sidebar.sh` renders a herdr-like sidebar of per-operator cards in a tmux pane, powered by Squad ground truth instead of screen reading.
It replaces the old tmux-agents-mon sidebar on the commander's machine; the machine-side swap is a separate follow-up.
The sidebar is a pure consumer of the ground-truth contract: it reads `state/window-states` (published by `bin/sq-window-state.sh`, whose header owns the file contract), `state/<id>.meta`, and `state/<id>.busy-gen`.
It never reads screens and never maps Squad verbs itself: `bin/sq-window-state.sh` owns the verb to label translation and `bin/sq-classify-lib.sh` owns the status vocabulary.

The script header owns the full command, environment, and behavior reference.
This page covers setup, usage, and the interface contract with the machine-side scripts.

## Card model

Each operator window renders as one card of two display lines:

- Line 1 is `<glyph> <id> [<elapsed>]`: a spinner while the operator is working, a static glyph otherwise, the mission id, and wall-clock elapsed time.
- Line 2 is `<label> <detail>`: the sidebar-facing state label (working, awaiting-decision, blocked, done, idle, failed, unknown) and the reconciled current-status prose from `state/window-states`.

The label and state names come verbatim from the ground-truth contract; the sidebar only picks glyphs and colors per label.
Elapsed time is a simple honest approximation: wall-clock since the task's busy contract was armed (`state/<id>.busy-gen` mtime, written once at spawn), falling back to the meta file's mtime.
It is not billing-grade, and the sidebar does NOT compute session cost: when a card has no detail prose, line 2 shows the recorded `model=` and `effort=` meta tags as the cost context instead.
See `bin/sq-busy-event.sh` for who arms the busy contract and `bin/sq-crew-state.sh` for what the reconciled prose means.

The two-lines-per-card layout is the single layout constant the script owns; `click` maps a rendered pane line to its card with `((line + 1) / 2)`.
The renderer truncates every line to the pane width minus one, so a card never wraps and the mapping stays exact.

## Requirements

- tmux 3.2 or newer (pane user options, `if-shell -F`, and `#{mouse_line}` are required; verified on 3.7).
- A UTF-8 terminal for the spinner glyphs; `SQ_SIDEBAR_SPINNER` can replace them with ASCII frames.
- A Squad base with tmux task windows; the sidebar shows nothing when `state/window-states` is absent or empty.

## Install and load

The plugin loads as a `.tmux` shell script, the same way tmux plugin managers run plugins.
Put this repo (or a plugin checkout of it) on the machine and add one line to `~/.config/tmux/tmux.conf`:

```conf
run-shell "/home/you/squad/tmux/sq-sidebar.tmux"
```

The loader binds the toggle key and the click action and records the tool path in the global `@sq-sidebar-path` option.
Do not use `tmux source-file` on the loader: the loader is shell, not tmux config syntax.

## Usage

Press `C-M-s` (workmux-style) in any window to toggle a 25-wide sidebar pane on the left of the current window.
The pane shows one card per operator window and re-renders every second; the ground truth it reads is re-published every two seconds.
Click a card with the mouse to focus that operator's tmux window.
A click anywhere else in a pane keeps tmux's default behavior: it focuses the clicked pane and passes the mouse event through.

Customize with environment variables (all optional):

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `SQ_SIDEBAR_WIDTH` | `25` | Sidebar pane width in columns |
| `SQ_SIDEBAR_SPINNER` | braille frames | Space-separated spinner glyphs |
| `SQ_SIDEBAR_REFRESH_SECS` | `2` | Ground-truth re-publish cadence in the run loop |
| `SQ_SIDEBAR_FRAME_SECS` | `1` | Render cadence in the run loop |
| `SQ_SIDEBAR_NO_COLOR` | unset | `1` disables ANSI styling (plain text) |
| `SQ_SIDEBAR_NO_ELAPSED` | unset | `1` hides the elapsed time column |

For a machine-side toggle or auto-open script, call `bin/sq-sidebar.sh toggle [BASE]` directly; the loader's `C-M-s` binding is exactly that command.

## Interface contract with the machine-side scripts

- `~/.local/bin/sq-sidebar-start.sh` (machine) owns the auto-open-on-boot and toggle flow; the follow-up machine swap re-points it at `bin/sq-sidebar.sh toggle [BASE]`, and it must not bind `C-M-s` a second time because the loader owns that key.
- The powerkit agent-count segment reads `bin/sq-sidebar.sh cards [BASE]` (one raw TAB-separated record per card: window, id, label, state, detail, elapsed, model, effort) or `state/window-states` directly; the follow-up machine swap decides which.
- `bin/sq-status-notify.sh` is independent: it watches `state/<id>.status` for desktop notifications and focuses via the same `window=` targets, with no interface change.
- `state/window-states` remains owned by `bin/sq-window-state.sh`; the sidebar never writes it, it only calls `publish` and reads the file.

## Limits

- The sidebar shows only tmux-backend task windows, matching what `bin/sq-window-state.sh` publishes; orca, herdr, zellij, cmux, and XO tasks have no tmux window to show.
- Keeping the sidebar pane at `SQ_SIDEBAR_WIDTH` keeps the click line mapping exact; manually resizing the pane can wrap lines and drift the mapping.
- The spinner advances with the render cadence and is driven by the clock, not by per-frame events; it is a visual state hint, not a progress meter.
- The mouse click path is exercised through tmux's documented mouse binding semantics (`{mouse}` targets and `#{mouse_line}`); the full click flow was smoke-verified manually, not by automated mouse injection.

## Regression entry point

```sh
tests/sq-sidebar.test.sh
```
