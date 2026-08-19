# Workmux Fork - Squad Integration

This is a fork of [workmux](https://github.com/raine/workmux) with added support for reading agent state from Squad's state directory.

## Key Architecture

### Data Source

The sidebar always uses tmux native tracking to discover panes automatically.
When `SQUAD_BASE` or `SQUAD_HOME` is set, the sidebar reads from Squad's
`state/` directory structure for task metadata.

### Squad Data Source

When Squad state files are present, the sidebar reads:

1. `state/window-states` (TSV: window, id, label, state, detail)
2. `state/<id>.meta` (JSON: model, effort, kind, mode)
3. `state/<id>.busy-gen` (mtime for elapsed time)

### Key Files

- `src/command/sidebar/daemon_ctrl.rs` - Daemon spawning (always uses tmux native tracking)
- `src/command/sidebar/daemon.rs` - Daemon with pane discovery logic

### Environment Variables

- `SQUAD_BASE` - Primary Squad base directory (takes precedence)
- `SQUAD_HOME` - Legacy Squad home directory (fallback)
- Default: `~/.fob/squad/`

## Maintaining This File

Keep this file for knowledge useful to almost every future session in this project.
Prefer pointers to authoritative sources over copying detail.
