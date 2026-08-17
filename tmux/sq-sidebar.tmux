#!/usr/bin/env bash
# sq-sidebar.tmux - tmux plugin loader for the Squad Operations Board.
#
# Sourced by tmux (or run by a plugin manager) from inside a running tmux
# server. It binds the workmux-style toggle key, the click-to-focus mouse
# action, the next-attention / acknowledge / filter keys, sidebar-local
# navigation keys, and the per-window tab badge, and records the bin tool
# path in the @sq-sidebar-path global option so machine-side scripts (the old
# ~/.local/bin/sq-sidebar-start.sh flow and the powerkit segment) can delegate
# without hardcoding a path.
#
# SESSION SCOPING:
# The sidebar is session-scoped by construction. All hooks use -t <session>,
# sidebar-local keybindings check @sq-sidebar-active-<session> before
# intercepting, and pane operations target the current session only. This
# prevents the sidebar from leaking into other concurrent tmux sessions.
#
# GLOBAL SIDEBAR:
# The sidebar is GLOBAL within a session: when toggled on, a sidebar pane is
# created in EVERY tmux window of the current session and a session-scoped
# hook (after-new-window) auto-adds sidebar panes to newly created windows
# in that session. When toggled off, all sidebar panes in the session are
# killed and the hook is removed.
#
# SIDEBAR-LOCAL KEYBINDINGS:
# When the sidebar pane is focused (detected via session-scoped
# @sq-sidebar-active-<session> option), these keys are intercepted and routed
# to sidebar actions; when other panes are focused, the keys pass through
# normally:
#   j/k     navigate down/up
#   Enter   jump to selected agent
#   g/G     jump to first/last
#   v       toggle layout mode (tiles/compact)
#   f       toggle session filter
#   q       close sidebar in current session
#
# GLOBAL KEYBINDINGS (work from any pane):
#   C-M-s   toggle sidebar on/off (in current session)
#   C-M-n   next attention operator
#   C-M-a   acknowledge done operators
#   C-M-f   cycle filter
#   C-M-d   jump to last done/attention operator
#   C-M-l   toggle between current and last visited window
#
# The loader owns the key and mouse bindings and the window-tab badge; the
# rendering, toggle, click, badge, filter, and next-inbox logic lives in
# bin/sq-sidebar.sh (see its header and docs/sq-sidebar.md). The toggle
# interface is `bin/sq-sidebar.sh toggle [BASE]`, which is what the machine-
# side auto-open script calls. The click binding passes the 1-based mouse row
# (`#{e|+|:#{mouse_y},1}`) and the base the run loop recorded in the pane's
# `@sq-sidebar-base` option, shell-quoted once with `#{q:...}` so a base with
# spaces or shell specials stays one argument. On non-sidebar clicks the
# binding replicates tmux's default MouseDown1Pane behavior (focus the clicked
# pane and pass the mouse event through).
#
# The window-tab badge prepends a colored state icon to the standard
# index:name tab label via `#()`. The `#{q:@sq-sidebar-path}` inside it shell-
# quotes the tool path so a spaced checkout path still runs, and the window
# target is passed as `#{session_name}:#{window_name}`, the same target shape
# bin/sq-window-state.sh records.
#
# SESSION-SCOPED KEYBINDING STRATEGY:
# The sidebar-local keys (j/k/Enter/g/G/v/f/q) use `if-shell -F` with a
# session-scoped format check: `#{==:#{@sq-sidebar-active-#{session_name}},1}`.
# This ensures keys are intercepted only when the current session has an active
# sidebar, preventing cross-session interference. The toggle key (C-M-s) works
# from any session.
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$CURRENT_DIR/.." && pwd)/bin/sq-sidebar.sh"

if [ ! -f "$BIN" ]; then
  echo "sq-sidebar: missing $BIN; the plugin cannot load" >&2
  exit 1
fi

tmux set-option -g @sq-sidebar-path "$BIN"

# Global keybindings (work from any pane)
tmux bind-key -n C-M-s run-shell '#{q:@sq-sidebar-path} toggle'
tmux bind-key -n C-M-n run-shell '#{q:@sq-sidebar-path} next-inbox'
tmux bind-key -n C-M-a run-shell '#{q:@sq-sidebar-path} ack'
tmux bind-key -n C-M-f run-shell '#{q:@sq-sidebar-path} filter'
tmux bind-key -n C-M-d run-shell '#{q:@sq-sidebar-path} last-done'
tmux bind-key -n C-M-l run-shell '#{q:@sq-sidebar-path} last-agent'

# Sidebar-local keybindings: session-scoped via @sq-sidebar-active-<session>.
# The if-shell -F checks the session-scoped option, so keys are intercepted
# only when the current session has an active sidebar; other sessions pass
# the keys through normally.
tmux bind-key -n j if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} navigate down #{q:@sq-sidebar-base}'" \
  'send-keys j'
tmux bind-key -n k if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} navigate up #{q:@sq-sidebar-base}'" \
  'send-keys k'
tmux bind-key -n Enter if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} select #{q:@sq-sidebar-base}'" \
  'send-keys Enter'
tmux bind-key -n g if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} first #{q:@sq-sidebar-base}'" \
  'send-keys g'
tmux bind-key -n G if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} last #{q:@sq-sidebar-base}'" \
  'send-keys G'
tmux bind-key -n v if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} layout'" \
  'send-keys v'
tmux bind-key -n f if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} filter'" \
  'send-keys f'
tmux bind-key -n q if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
  "run-shell '#{q:@sq-sidebar-path} toggle'" \
  'send-keys q'

# Window-tab badge
tmux set-option -g window-status-format ' #(#{q:@sq-sidebar-path} badge "#{session_name}:#{window_name}") #I:#W'
tmux set-option -g window-status-current-format ' #(#{q:@sq-sidebar-path} badge "#{session_name}:#{window_name}") #I:#W'

# Mouse click binding: session-scoped sidebar clicks resolve to the card's
# window, non-sidebar clicks pass through to tmux's default behavior.
tmux bind-key -n MouseDown1Pane \
  if-shell -F '#{==:#{@sq-sidebar-active-#{session_name}},1}' \
    "run-shell '#{q:@sq-sidebar-path} click #{e|+|:#{mouse_y},1} #{q:@sq-sidebar-base}'" \
    'select-pane -t= \; send-keys -M'
