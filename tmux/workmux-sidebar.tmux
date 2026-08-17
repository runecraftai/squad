#!/usr/bin/env bash
# workmux-sidebar.tmux - tmux plugin loader for the workmux sidebar.
#
# Sourced by tmux (or run by a plugin manager) from inside a running tmux
# server. It binds C-M-s to toggle the workmux sidebar pane.
#
# The workmux sidebar reads from Squad's ground-truth state directory when
# SQUAD_BASE or SQUAD_HOME is set (auto-detected by workmux). See
# docs/sq-sidebar.md for the integration details and the workmux README
# for full sidebar documentation.
set -euo pipefail

# Verify workmux is available
if ! command -v workmux >/dev/null 2>&1; then
  echo "workmux-sidebar: workmux not found in PATH; the plugin cannot load" >&2
  exit 1
fi

# Bind C-M-s to toggle the workmux sidebar
tmux bind-key -n C-M-s run-shell "workmux sidebar"
