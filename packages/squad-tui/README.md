# @runecraft/squad-tui

Versioned contracts for the Squad cockpit (T05 of `data/squad-tui-prd-plan/`).
Later, separately authorized tasks add the terminal cockpit itself.

## Contracts

`src/contracts/` defines the versioned Zod schemas for TUI-specific sessions, mission/stage projections, transcript messages, extension interactions, adapter capabilities, and the service-exclusivity lock.
These are projections and TUI-owned command/event shapes.
They do not redefine Squad's or the (separately tracked) Hugin adapter's authoritative task mutations.

## Toolchain

Bun must resolve to `>=1.3.0` for this package (`.bun-version` pins `1.4.2`, the version proved in `data/squad-tui-opentui-spike/report.md`).
Every script must be invoked as `bun --bun run <script>`, never the bare `bun run <script>`.
Vitest's worker pool forks a real subprocess, and without `--bun` that subprocess resolves under Node instead of Bun, which this package's dependencies are not proven to support.

Scripts: `test`, `typecheck`, `lint`, `format`, `format:check`.
