#!/usr/bin/env bash
# sq-sidebar.tmux - tmux plugin loader for the Squad ground-truth sidebar.
#
# Sourced by tmux (or run by a plugin manager) from inside a running tmux
# server. It binds the workmux-style toggle key, the click-to-focus mouse
# action, the next-attention / acknowledge / filter keys, and the per-window
# tab badge, and records the bin tool path in the @sq-sidebar-path global
# option so machine-side scripts (the old ~/.local/bin/sq-sidebar-start.sh
# flow and the powerkit segment) can delegate without hardcoding a path.
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
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$CURRENT_DIR/.." && pwd)/bin/sq-sidebar.sh"

if [ ! -f "$BIN" ]; then
  echo "sq-sidebar: missing $BIN; the plugin cannot load" >&2
  exit 1
fi

tmux set-option -g @sq-sidebar-path "$BIN"
tmux bind-key -n C-M-s run-shell '#{q:@sq-sidebar-path} toggle'
tmux bind-key -n C-M-n run-shell '#{q:@sq-sidebar-path} next-inbox'
tmux bind-key -n C-M-a run-shell '#{q:@sq-sidebar-path} ack'
tmux bind-key -n C-M-f run-shell '#{q:@sq-sidebar-path} filter'
tmux set-option -g window-status-format ' #(#{q:@sq-sidebar-path} badge "#{session_name}:#{window_name}") #I:#W'
tmux set-option -g window-status-current-format ' #(#{q:@sq-sidebar-path} badge "#{session_name}:#{window_name}") #I:#W'
tmux bind-key -n MouseDown1Pane \
  if-shell -F '#{==:#{@sq-sidebar},1}' \
    "run-shell '#{q:@sq-sidebar-path} click #{e|+|:#{mouse_y},1} #{q:@sq-sidebar-base}'" \
    'select-pane -t= \; send-keys -M'
