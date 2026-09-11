# @runecraft/squad-mcp

MCP adapter for the Squad Personal OS.
Hermes talks through these tools; Squad decides.

## Architecture

The adapter exposes read-only unit introspection, durable task writes through the
sanctioned `sq-tasks` CLI, and a request channel that enqueues `launch-brief`
operational inputs through Squad's canonical stand-to queue path (`fm_wake_append`).
No tool can spawn an operator, merge a PR, or tear down a task.

All read tools read directly from Squad's authoritative durable records - status
logs, `data/*/report.md`, backlog, and done-archive. No new summary layer is
invented.

### Tools

| Tool | Direction | What it does |
|---|---|---|
| `squad_status` | Read | Reconciled status of a single task |
| `squad_situation` | Read | Unit overview: active tasks, states, afk flag |
| `squad_backlog` | Read | Backlog by state with dependencies |
| `squad_decisions` | Read | Commander decisions (pending + resolved with answer) |
| `squad_reports` | Read | List recon/status reports with task identity, date, size |
| `squad_report_read` | Read | Read a report with bounded paging or section index |
| `squad_history` | Read | Recent done items with PR URL or report path |
| `squad_task_create` | Write | Create a task via `sq-tasks add` |
| `squad_task_update` | Write | Update title/body via `sq-tasks update` |
| `squad_task_hold` | Write | Place a hold via `sq-tasks hold` |
| `squad_task_block` | Write | Declare a dependency via `sq-tasks block` |
| `squad_task_unblock` | Write | Remove a dependency via `sq-tasks unblock` |
| `squad_request` | Write | Enqueue a launch-brief to Squad's wake queue |
| `squad_replies` | Write | Read and acknowledge replies from the MCP outbox |

### Report paging

Reports can exceed a thousand lines. Use `squad_report_read` with:
- `offset` + `limit` for bounded line-range paging (max 500 lines per call)
- `section=index` to get a table of contents (all markdown headers with line numbers)
- Always page rather than reading the whole report

### Request flow

1. Hermes calls `squad_request` with a project and objective.
2. The MCP encodes a `launch-brief` operational input in the canonical wire form.
3. It enqueues a `signal` wake record through `sq-mcp-wake-append.sh`, which
   sources `sq-stand-to-lib.sh` and uses `fm_wake_append` with its lock.
4. Squad drains the wake queue on its next cycle and processes the request.
5. Squad writes replies to `state/mcp-outbox/<request-id>.reply` via
   `sq-mcp-outbox-write.sh`.
6. Hermes reads replies via `squad_replies`.

### Outbox

Replies live in `$STATE/mcp-outbox/<request-id>.reply`.
Reading a reply moves it to `$STATE/mcp-outbox/.read/<request-id>.reply.delivered`
so each reply is delivered exactly once and remains auditable.

## Installation for Hermes

The installed Personal OS copy is produced from this repository copy.

### One-source-of-truth rule

`packages/squad-mcp/` in the Squad repository is canonical.
The installed Personal OS copy at `~/.local/share/personal-os/squad-mcp/` is built from this source.
The package version is `0.3.0`, and the installed copy's `package.json` must carry the same version after each rollout.

To publish a new installed copy:

```sh
# From the Squad repo root:
bun run --cwd packages/squad-mcp build

INSTALL="$HOME/.local/share/personal-os/squad-mcp"
BACKUP="$INSTALL.backup-$(date +%Y%m%d-%H%M%S)"
cp -a "$INSTALL" "$BACKUP"
test -x "$INSTALL/run-squad-mcp"
cp -a packages/squad-mcp/dist/. "$INSTALL/dist/"
cp packages/squad-mcp/package.json "$INSTALL/package.json"
test -x "$INSTALL/run-squad-mcp"

# Confirm the installed manifest matches this source version.
test "$(node -p "require('$INSTALL/package.json').version")" = "$(node -p "require('./packages/squad-mcp/package.json').version")"

# Confirm the launcher still works and the installed list has no dispatch or teardown capability.
(
  cd "$INSTALL"
  node --input-type=module <<'NODE'
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
const transport = new StdioClientTransport({ command: './run-squad-mcp' });
const client = new Client({ name: 'rollout-check', version: '1' });
await client.connect(transport);
const names = (await client.listTools()).tools.map(({ name }) => name);
const forbidden = names.filter((name) => /dispatch|spawn|merge|teardown/i.test(name));
if (forbidden.length) throw new Error(`forbidden tools: ${forbidden.join(', ')}`);
console.log(names.join('\n'));
await client.close();
NODE
)
```

Keep the existing `run-squad-mcp` launcher in place because Hermes invokes it to start the installed adapter.
The installed list must remain read-only introspection, sanctioned task writes, request enqueueing, and reply acknowledgement only.
The commander restarts Hermes after the rollout so Hermes reloads the installed adapter.

The repository copy must never be edited by hand to match the installed copy.
Always rebuild and copy from repo to install.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `SQUAD_ROOT` | `cwd` | Squad repo root |
| `SQUAD_BASE` | `SQUAD_HOME` or `SQUAD_ROOT` | Squad base (state, data) |
| `SQUAD_DATA_OVERRIDE` | `$SQUAD_BASE/data` | Data directory override |
| `SQUAD_STATE_OVERRIDE` | `$SQUAD_BASE/state` | State directory override |

## Development

```sh
bun install
bun run --cwd packages/squad-mcp build
bun run --cwd packages/squad-mcp test
```

### Adding a tool

1. Define the tool in `src/server.ts` using `server.tool(...)`.
2. Read tools must never call `command()`, `writeFileSync()`, `mkdirSync()`, or
   spawn anything. They read files and shell CLI output only.
3. Task writes must go through `sq-tasks` CLI calls, never hand-edits to
   `backlog.md`.
4. Requests must go through `sq-mcp-wake-append.sh`, never direct queue writes.
5. Add a test in `test/server.test.ts`.
6. Update this README's tool table.
