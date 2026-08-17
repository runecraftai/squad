# Squad tmux sidebar (workmux)

The Squad tmux sidebar is provided by [workmux](https://github.com/runecraftai/workmux), a tmux workspace manager with built-in Squad integration.

## How it works

The workmux sidebar reads from Squad's ground-truth state files:

- `state/window-states` - per-window operator state (published by `bin/sq-window-state.sh`)
- `state/<id>.meta` - task metadata (model, effort, kind, project, worktree)
- `state/<id>.busy-gen` - mtime used for elapsed time display

When `SQUAD_BASE` or `SQUAD_HOME` is set, workmux automatically uses the Squad data source instead of its default tmux monitoring.

The tmux plugin runs `workmux sidebar` in the tmux server's environment, so the variables must be visible there. The loader pins any `SQUAD_BASE` / `SQUAD_HOME` it sees at load time into the server's global environment (`tmux set-environment -g`), covering the common case where tmux is started from a shell that exports them. If tmux was started before the variables were exported, set them globally in `~/.config/tmux/tmux.conf` so the sidebar still selects the Squad data source:

```conf
set-environment -g SQUAD_BASE /path/to/your/squad-base
```

## Install

Install workmux from the Squad fork. The Squad integration (meta parsing and
SQUAD_BASE/SQUAD_HOME auto-detection) lives on the unmerged fork PR
[#1](https://github.com/runecraftai/workmux/pull/1) (branch
`fix/squad-meta-parsing`), so pin that branch until it merges:

```bash
cargo install --git https://github.com/runecraftai/workmux --branch fix/squad-meta-parsing
```

Or build from source:

```bash
git clone https://github.com/runecraftai/workmux.git
cd workmux
git checkout fix/squad-meta-parsing
cargo build --release
cp target/release/workmux ~/.local/bin/
```

Once the fork PR merges, drop the branch pin; `main` will then include the
Squad integration.

## Load the tmux plugin

Add to `~/.config/tmux/tmux.conf`:

```conf
run-shell "/path/to/squad/tmux/workmux-sidebar.tmux"
```

The plugin binds `C-M-s` to toggle the sidebar, and requires workmux in `PATH`.

## Usage

| Key | Action |
| --- | ------ |
| `C-M-s` | Toggle sidebar pane (global across all windows) |

The sidebar automatically appears in every tmux window, and new windows get the pane via tmux hooks.

## Data mapping

| Squad Source | Workmux Field |
|-------------|---------------|
| `state/window-states` col 1 (window) | session + window_name |
| `state/window-states` col 2 (id) | pane_id (synthetic `%{id}`) |
| `state/window-states` col 3 (label) | status (mapped to AgentStatus) |
| `state/window-states` col 4-5 (state/detail) | pane_title |
| `state/<id>.meta` model + effort | agent_command |
| `state/<id>.meta` kind | agent_kind |
| `state/<id>.busy-gen` mtime | status_ts (elapsed time) |

## Status mapping

| Squad Label | Workmux Status | Display |
|-------------|----------------|---------|
| `working` | Working | spinner |
| `done` | Done | checkmark |
| `blocked` / `awaiting-decision` | Waiting | message icon |
| `failed` | Done | danger color |
| `idle` / other | None | empty |

## Configuration

Workmux sidebar can be configured via `~/.workmux.yaml`:

```yaml
sidebar:
  position: left       # "left" or "top"
  width: 40            # columns, or "15%" for percentage
  layout: tiles        # "compact" or "tiles" (default)
```

## Ground truth

The sidebar is a pure consumer of Squad's ground-truth contract. `bin/sq-window-state.sh` owns the verb-to-label translation and publishes to `state/window-states`. The sidebar never reads screens.

See `bin/sq-window-state.sh` header for the file format contract.

## Limits

- The sidebar shows only tmux-backend task windows; orca, herdr, zellij, cmux, and XO tasks have no tmux window to show.
- The sidebar reads from Squad's state directory; it does not write back to Squad.

## Regression entry point

The workmux fork's Squad data source tests cover the integration:

```bash
cd /path/to/workmux
cargo test squad
```

## See also

- [workmux README](https://github.com/runecraftai/workmux) - full sidebar documentation
- [bin/sq-window-state.sh](../bin/sq-window-state.sh) - ground-truth publisher
- [docs/tmux-backend.md](tmux-backend.md) - tmux backend documentation
