# operation-board

Mission-planning board for [Squad](https://github.com/runecraftai/squad) — combines the backlog queue with live operational state into a single view.

## What it does

`sq-board` reads Squad's durable state files and renders a formatted board of missions:

- **Backlog** (`data/backlog.md`) — task queue grouped by section (In flight / Held / Queued)
- **Live state** (`state/<id>.meta`) — model, effort, delivery mode, backend
- **Endpoint truth** (`state/window-states`) — per-window operator state from `sq-window-state.sh`
- **Status events** (`state/<id>.status`) — latest wake event per task
- **Elapsed time** (`state/<id>.busy_gen`) — mtime-derived busy duration

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
| `SQ_TASKS_BIN` | `sq-tasks` | Path to sq-tasks binary |

## Naming

- CLI binary: `sq-board` (follows `sq-*` convention)
- Package name: `operation-board` (commander's choice)
- Alternatives considered: `sq-ops` (too generic), `sq-opsboard` (verbose)

## License

MIT
