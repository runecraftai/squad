# Scripts Guide

> Read this when designing or bundling scripts in the `scripts/` directory of a skill. The agent runs your scripts and reads stdout/stderr to decide what to do next — design choices here have outsized impact on reliability.

## One-off commands

When an existing package already does what you need, reference it directly in `SKILL.md` without a `scripts/` directory. Many ecosystems provide tools that auto-resolve dependencies at runtime.

| Runner | Install | Use when |
|---|---|---|
| `uvx` | Ships with `uv` | Python tools, fast, caches aggressively |
| `pipx` | OS package manager | Python tools, mature, broad OS availability |
| `npx` | Ships with npm | Node tools, no extra install |
| `bunx` | Ships with Bun | Node tools, Bun environment |
| `deno run` | Ships with Deno | TS/JS with permission flags |
| `go run` | Built into Go | Go tools, pinned versions |

Examples:

```bash
uvx ruff@0.8.0 check .
npx eslint@9 --fix .
deno run --allow-read npm:eslint@9 -- --fix .
go run github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.0 run
```

Tips for one-off commands in skills:

- **Pin versions** (`npx eslint@9.0.0`) so the command behaves the same over time.
- **State prerequisites** in `SKILL.md` ("Requires Node.js 18+"). For runtime-level requirements, use the `compatibility` frontmatter field.
- **Move complex commands into scripts.** When a command grows complex enough that it's hard to get right on the first try, bundle a tested script.

## Referencing scripts from `SKILL.md`

Use **relative paths from the skill directory root** to reference bundled files. The agent resolves these automatically.

List available scripts in your `SKILL.md` so the agent knows they exist:

```markdown
## Available scripts

- **`scripts/validate.sh`** — Validates configuration files
- **`scripts/process.py`** — Processes input data
```

Then instruct the agent to run them:

```markdown
## Workflow

1. Run the validation script:

   ```bash
   bash scripts/validate.sh "$INPUT_FILE"
   ```

2. Process the results:

   ```bash
   python3 scripts/process.py --input results.json
   ```
```

The same relative-path convention works in support files like `references/*.md` — script execution paths are relative to the **skill directory root**.

## Self-contained scripts

When you need reusable logic, bundle a script in `scripts/` that declares its own dependencies inline. The agent can run it with a single command — no separate manifest or install step.

### Python (PEP 723)

Declare dependencies in a TOML block inside `# ///` markers:

```python scripts/extract.py
# /// script
# dependencies = [
#   "beautifulsoup4",
# ]
# requires-python = ">=3.11"
# ///

from bs4 import BeautifulSoup

html = '<html><body><h1>Welcome</h1><p class="info">This is a test.</p></body></html>'
print(BeautifulSoup(html, "html.parser").select_one("p.info").get_text())
```

Run with `uv` (recommended):

```bash
uv run scripts/extract.py
```

`uv run` creates an isolated environment, installs declared dependencies, and runs the script. Pin with PEP 508 specifiers: `"beautifulsoup4>=4.12,<5"`. Use `uv lock --script` to create a lockfile for full reproducibility.

### Deno

`npm:` and `jsr:` import specifiers make every script self-contained:

```typescript scripts/extract.ts
#!/usr/bin/env -S deno run

import * as cheerio from "npm:cheerio@1.0.0";

const html = `<html><body><h1>Welcome</h1><p class="info">This is a test.</p></body></html>`;
const $ = cheerio.load(html);
console.log($("p.info").text());
```

```bash
deno run scripts/extract.ts
```

Use `npm:` for npm packages, `jsr:` for Deno-native. Pin with semver: `@1.0.0` exact, `@^1.0.0` compatible. Packages with native addons (node-gyp) may not work; pre-built binaries work best.

### Bun

Bun auto-installs missing packages at runtime when no `node_modules/` exists. Pin versions in the import path:

```typescript scripts/extract.ts
#!/usr/bin/env bun

import * as cheerio from "cheerio@1.0.0";

const html = `<html><body><h1>Welcome</h1><p class="info">This is a test.</p></body></html>`;
const $ = cheerio.load(html);
console.log($("p.info").text());
```

```bash
bun run scripts/extract.ts
```

No `package.json` or `node_modules` needed; TypeScript works natively. If a `node_modules` exists anywhere up the tree, auto-install is disabled and Bun falls back to standard Node resolution.

### Ruby

Bundler ships with Ruby since 2.6. Use `bundler/inline` to declare gems in the script:

```ruby scripts/extract.rb
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'nokogiri'
end

html = '<html><body><h1>Welcome</h1><p class="info">This is a test.</p></body></html>'
doc = Nokogiri::HTML(html)
puts doc.at_css('p.info').text
```

```bash
ruby scripts/extract.rb
```

Pin versions explicitly (`gem 'nokogiri', '~> 1.16'`) — there's no lockfile. An existing `Gemfile` or `BUNDLE_GEMFILE` env var in the working directory can interfere.

## Designing scripts for agentic use

When the agent runs your script, it reads stdout and stderr to decide what to do next. A few design choices make scripts dramatically easier to use.

### Avoid interactive prompts

Hard requirement of the agent environment. Agents operate in non-interactive shells — they cannot respond to TTY prompts, password dialogs, or confirmation menus. A script that blocks on interactive input will hang indefinitely.

Accept all input via command-line flags, environment variables, or stdin:

```text
# Bad: hangs waiting for input
$ python scripts/deploy.py
Target environment: _

# Good: clear error with guidance
$ python scripts/deploy.py
Error: --env is required. Options: development, staging, production.
Usage: python scripts/deploy.py --env staging --tag v1.2.3
```

### Document usage with `--help`

`--help` output is the primary way an agent learns your script's interface. Include a brief description, available flags, and usage examples:

```text
Usage: scripts/process.py [OPTIONS] INPUT_FILE

Process input data and produce a summary report.

Options:
  --format FORMAT    Output format: json, csv, table (default: json)
  --output FILE      Write output to FILE instead of stdout
  --verbose          Print progress to stderr

Examples:
  scripts/process.py data.csv
  scripts/process.py --format csv --output report.csv data.csv
```

Keep it concise — the output enters the agent's context window alongside everything else.

### Write helpful error messages

When an agent gets an error, the message directly shapes its next attempt. Opaque "Error: invalid input" wastes a turn. Say what went wrong, what was expected, and what to try:

```text
Error: --format must be one of: json, csv, table.
       Received: "xml"
```

### Use structured output

Prefer structured formats — JSON, CSV, TSV — over free-form text. Structured formats can be consumed by both the agent and standard tools (`jq`, `cut`, `awk`):

```text
# Whitespace-aligned — hard to parse
NAME          STATUS    CREATED
my-service    running   2025-01-15

# Delimited — unambiguous
{"name": "my-service", "status": "running", "created": "2025-01-15"}
```

**Separate data from diagnostics:** send structured data to stdout and progress messages, warnings, and other diagnostics to stderr. The agent can capture clean output while keeping access to diagnostic info.

### Further considerations

- **Idempotency.** Agents may retry. "Create if not exists" is safer than "create and fail on duplicate."
- **Input constraints.** Reject ambiguous input with a clear error rather than guessing. Use enums and closed sets where possible.
- **Dry-run support.** For destructive or stateful operations, a `--dry-run` flag lets the agent preview what will happen.
- **Meaningful exit codes.** Use distinct exit codes for different failure types (not found, invalid arguments, auth failure) and document them in `--help` so the agent knows what each code means.
- **Safe defaults.** Consider whether destructive operations should require explicit confirmation (`--confirm`, `--force`) or other safeguards appropriate to the risk level.
- **Predictable output size.** Many harnesses automatically truncate tool output beyond a threshold (e.g. 10-30K characters), potentially losing critical information. If your script may produce large output, default to a summary and support flags like `--offset` for pagination, or require an explicit `--output` flag.
