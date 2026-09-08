# Personal OS V1 Squad MCP

This page documents the local stdio MCP server for the approved Personal OS V1 proof.

## Setup

Build the package with `pnpm --dir packages/squad-mcp install` followed by `pnpm --dir packages/squad-mcp build`.

Configure an MCP client to launch `packages/squad-mcp/dist/bin/squad-mcp.js` with its working directory set to the Squad repository.

The server uses the active Squad base selected by `SQUAD_BASE` or the normal Squad default.

It requires a registered project clone and the existing Squad scripts.

## Tools

The server exposes exactly `squad_start`, `squad_status`, and `squad_stop`.

`taskId` is the durable external identity and this interface does not expose a session identity.

`squad_start` accepts a registered project name and a bounded engineering objective and creates a normal drill task.

`squad_status` reconstructs current state from Squad's durable records.

`squad_stop` invokes normal cleanup without force or discard controls and returns a typed refusal when safety protections reject cleanup.

Successful and failed results are structured JSON objects with bounded summaries.

## Exclusions

V1 does not expose `squad_send`.

V1 does not expose shell commands, arbitrary paths, HTTP, environment mutation, runtime selection, harness selection, tmux controls, or force flags.

V1 does not change the interactive Pi-to-Squad lifecycle.

V1 does not modify Hermes, LifeForge, their home directories, or their repositories.

The four approved decisions are recorded in [ADR-001](adr-001-lifeforge-interface.md), [ADR-002](adr-002-task-identity.md), [ADR-003](adr-003-pi-boundary.md), and [ADR-004](adr-004-durable-state.md).
