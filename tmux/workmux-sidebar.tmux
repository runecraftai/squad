#!/usr/bin/env bash
# workmux-sidebar.tmux - tmux plugin loader for the workmux sidebar.
#
# Sourced by tmux (or run by a plugin manager) from inside a running tmux
# server. It binds C-M-s to toggle the workmux sidebar pane.
#
# The workmux sidebar reads from Squad's ground-truth state directory when
# SQUAD_BASE or SQUAD_HOME is set (auto-detected by workmux). The C-M-s
# binding runs `workmux sidebar` through tmux run-shell, which executes in
# the tmux server's environment, so this loader pins any Squad base visible
# at load time into the server's global environment instead of relying on
# whatever the server happened to start with. See docs/sq-sidebar.md for the
# integration details and the workmux README for full sidebar documentation.
set -euo pipefail

# Verify workmux is available
if ! command -v workmux >/dev/null 2>&1; then
  echo "workmux-sidebar: workmux not found in PATH; the plugin cannot load" >&2
  exit 1
fi

# Pin the Squad base into the tmux server's global environment so the
# workmux daemon spawned by the binding always selects the Squad data
# source, even after attachments from shells without the variables set.
if [ -n "${SQUAD_BASE:-}" ]; then
  tmux set-environment -g SQUAD_BASE "$SQUAD_BASE"
fi
if [ -n "${SQUAD_HOME:-}" ]; then
  tmux set-environment -g SQUAD_HOME "$SQUAD_HOME"
fi

# Resolve Squad base for the publish driver
_pub_base="${SQUAD_BASE:-${SQUAD_HOME:-$HOME/.fob/squad}}"
_pub_bin="$_pub_base/bin/sq-window-state.sh"

# Kill any previous publish loop for this server
prev_pid=$(tmux show-option -gqv @workmux_publish_pid 2>/dev/null || true)
if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then
  kill "$prev_pid" 2>/dev/null || true
fi

# Start background publish loop if sq-window-state.sh exists.
# The old sidebar's run loop was the only caller of publish; this
# replaces it with a lightweight background loop that keeps
# state/window-states fresh for the workmux data source.
if [ -f "$_pub_bin" ]; then
  (
    while tmux list-sessions -F '#{session_name}' >/dev/null 2>&1; do
      "$_pub_bin" publish 2>/dev/null || true
      sleep 2
    done
  ) &
  tmux set-option -g @workmux_publish_pid "$!"
fi

# Bind C-M-s to toggle the workmux sidebar
tmux bind-key -n C-M-s run-shell "workmux sidebar"
