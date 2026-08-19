# Workmux Fork - Squad Integration

This is a fork of [workmux](https://github.com/raine/workmux) with added support for reading agent state from Squad's state directory.

## Key Architecture

### Data Source Abstraction

The fork adds a `DataSource` trait abstraction in `src/data_source/mod.rs` that allows the sidebar daemon to read agent state from different sources:

- **tmux** (default): Original Workmux behavior, polls tmux for pane state
- **squad**: Reads from Squad's `state/` directory structure

### Squad Data Source

`src/data_source/squad.rs` implements `SquadDataSource` which reads:

1. `state/window-states` (TSV: window, id, label, state, detail)
2. `state/<id>.meta` (JSON: model, effort, kind, mode)
3. `state/<id>.busy-gen` (mtime for elapsed time)

### Key Files

- `src/data_source/mod.rs` - DataSource trait and DataSourceType enum
- `src/data_source/squad.rs` - SquadDataSource implementation
- `src/command/sidebar/daemon.rs` - Daemon with `run_with_data_source()` function
- `src/cli.rs` - CLI flag `--data-source` on `_sidebar-daemon` command

### Usage

```bash
# Start sidebar daemon reading from Squad
workmux _sidebar-daemon --data-source squad

# Default tmux behavior (backward compatible)
workmux _sidebar-daemon --data-source tmux
```

### Environment Variables

- `SQUAD_BASE` - Primary Squad base directory (takes precedence)
- `SQUAD_HOME` - Legacy Squad home directory (fallback)
- Default: `~/.fob/squad/`

## Maintaining This File

Keep this file for knowledge useful to almost every future session in this project.
Prefer pointers to authoritative sources over copying detail.
