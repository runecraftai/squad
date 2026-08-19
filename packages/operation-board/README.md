# operation-board

Mission-planning board for [Squad](https://github.com/runecraftai/squad) — combines the backlog queue with live operational state into a single view.

## What it does

`sq-board` reads Squad's durable state files and renders a formatted board of missions:

- **Backlog** (`data/backlog.md`) — task queue grouped by section (In flight / Held / Queued)
- **Live state** (`state/<id>.meta`) — model, effort, delivery mode, backend
- **Endpoint truth** (`state/window-states`) — per-window operator state from `sq-window-state.sh`
- **Status events** (`state/<id>.status`) — latest wake event per task
- **Elapsed time** (`state/<id>.busy-gen`) — mtime-derived busy duration

## Live sidebar (vendored workmux)

This package also vendors the full [workmux](https://github.com/raine/workmux) source (MIT) under `sidebar/`, with two Squad fixes (real task id as the sidebar primary label; click-to-jump resolving to the real `session:window` tmux target) applied. The sidebar always uses tmux native tracking to discover panes automatically.

The vendored binary is built locally from this repo - never installed from an external repository - via `bin/sq-install-workmux-sidebar.sh`, and runs as a live docked tmux sidebar that auto-updates from `state/window-states`.

See [docs/sq-sidebar.md](../../docs/sq-sidebar.md) for the integration and usage.

`sq-board` remains a separate headless entry point: it needs no tmux and prints a static snapshot (table/JSON/compact) on demand, while the sidebar is the live tmux surface.

## Install

```bash
# As part of Squad (already available via bin/sq-board)
# Or standalone via npm:
npm install -g @runecraft/operation-board
```

## Usage

```bash
# Default: formatted terminal table
sq-board

# Machine-readable JSON
sq-board --json

# Compact one-line-per-mission
sq-board --compact

# Filter by state or kind
sq-board --state in_flight
sq-board --kind strike
sq-board --state held --kind recon

# Include done items (excluded by default)
sq-board --with-done
```

## Output

### Table mode (default)

```
  ▶ IN FLIGHT
  ────────────────────────────────────────────────────────────
  ⠋ ◆ my-task                opencode-go/mimo-v2.5/high  [drill]
       Implementation task title here
       → working: implementing feature X

  ■ QUEUED
  ────────────────────────────────────────────────────────────
  · ◇ pending-recon           opencode-go/mimo-v2.5/medium
       Investigation task title
```

### JSON mode (`--json`)

Array of objects with: `id`, `state`, `kind`, `repo`, `title`, `model`, `effort`, `mode`, `backend`, `endpoint_label`, `endpoint_state`, `endpoint_detail`, `last_event`, `busy_elapsed`, `window`.

### Compact mode (`--compact`)

One line per mission with icon, id, kind, model, and elapsed time.

## Icons

| Icon | Meaning |
|------|---------|
| ⠋ | Working (active) |
| ◆ | Awaiting decision |
| ✖ | Blocked |
| ✓ | Done |
| ◌ | Idle (paused) |
| ✗ | Failed |
| · | No endpoint data |

## Kind badges

| Badge | Kind |
|-------|------|
| ◆ | Strike (implementation) |
| ◇ | Recon (investigation) |
| ★ | Commander decision |
| ⚙ | Ops |
| ✎ | Docs |

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `SQUAD_BASE` | auto-detected | Squad base directory |
| `SQUAD_BACKLOG` | `$SQUAD_BASE/data/backlog.md` | Backlog file path |

## Naming

- CLI binary: `sq-board` (follows `sq-*` convention)
- Package name: `operation-board` (commander's choice)
- Alternatives considered: `sq-ops` (too generic), `sq-opsboard` (verbose)

## License

MIT
