# @runecraft/squad-tui

Versioned contracts for the Squad cockpit (T05 of `data/squad-tui-prd-plan/`) and the local authenticated service boundary (T07).
Later, separately authorized tasks add the terminal cockpit, the durable agent owner, and operational adapters.

## Contracts

`src/contracts/` defines the versioned Zod schemas for TUI-specific sessions, mission/stage projections, transcript messages, extension interactions, adapter capabilities, the service-exclusivity lock, and the local-service wire surface.
These are projections and TUI-owned command/event shapes.
They do not redefine Squad's or the (separately tracked) Hugin adapter's authoritative task mutations.

## Local service (T07)

The service is a small foreground process that serves one canonical base over an authenticated loopback WebSocket.
Chord provides typed RPC and replicated state; Squad owns the principal, the source, the payload bounds, and the policy.
The service is its own process: a client never becomes its parent, and closing every client never stops it.

Run it from source, with an explicit disposable base:

```sh
cd packages/squad-tui
bun --bun run service --base "$TEMP_BASE" --port 0
bun --bun run service:rotate --base "$TEMP_BASE"
```

Both scripts execute `node src/service/main.ts`.
The service process runs on Node (verified on 25.2.1, minimum 22.19); the package toolchain (Vitest, `tsc`, Oxlint, Prettier) stays on Bun.
`$TEMP_BASE` must be an existing absolute directory you created and validated; the service never derives a base from the current directory or from `SQUAD_BASE`, and a conflicting ambient `SQUAD_BASE` is refused with `base-mismatch`.

### Discovery

On a successful start the service publishes `state/squad-tui/endpoint.json` (owner-only `0600`) containing only `schemaVersion`, `baseId`, `serviceInstanceId`, `pid`, `port`, and `startedAt`.
`baseId` is `sha256` of the base's canonical `realpath`.
The descriptor is discovery information, not the exclusivity lock and not a claim of primary authority.
A clean stop removes only this instance's descriptor; a crash leaves a stale one that the next lock owner replaces without signalling its recorded PID.

### Authentication

Read the token from `config/squad-tui/service-token` (owner-only `0600`, 64 lowercase hex characters plus a newline) and present it only in the upgrade request's `Authorization: Bearer <token>` header, together with `X-Squad-Base-Id: <baseId>`.
Tokens are never accepted in query strings, cookies, subprotocols, command arguments, or environment overrides.
Missing, invalid, or mismatched credentials receive the same generic `401` before any Chord resource exists, and the service binds only `127.0.0.1`.
Browser `Origin` headers are refused, the `Host` header must equal `127.0.0.1:<port>`, and every route other than `GET /v1/link` gets a fixed `404`/`405`/`426`.

### Rotation

Rotation is offline in this delivery.
Stop the service, then run `bun --bun run service:rotate --base "$TEMP_BASE"`.
It takes the same kernel lock, so a live service makes it refuse with `service-already-running` without touching any file.
A successful rotation prints only the non-secret credential path; clients must reread the file, and the previous token no longer authenticates.

### First-delivery surface

- Read `view`: service `schemaVersion`, `baseId`, `serviceInstanceId`, `startedAt`, `readiness: "ready"`, and explicit `availability` showing that operational projections and commands are **not** implemented.
- RPC `capabilities`: the implemented reads and the explicit unavailable features with reasons.
- RPC `execute`: validates the strict command envelope and every reserved operation (`prompt`, `steer`, `cancel`, `requestMission`, `answerDecision`) returns `accepted: false` with `operation-unavailable`. No T07 method executes a project command or reads operational records.
- Replication: one atomic snapshot at attach, then sequence-bearing operations from the same source. A reconnect takes a fresh snapshot; T07 promises no retained replay and never resubmits a command.
- Bounds: 8 KiB upgrade headers, 5 s header receipt, 64 KiB decoded RPC arguments, 1 MiB WebSocket messages, 8 links per base, 4 concurrent calls per link, library flow control with a reset for a stalled consumer, optional compression disabled.
- The 64 KiB decoded-argument bound is defence-in-depth: Chord validates and bounds every declared argument field before the handler runs, so it becomes a reachable refusal only if a future contract widens a declared field beyond the bound.

### Errors

Startup failures print `error: <code>: <fixed remedy>` on stderr, exit nonzero, and never print readiness for a partial start: `usage`, `invalid-base`, `base-mismatch`, `unsupported-runtime`, `lock-unavailable`, `service-already-running`, `unsafe-credential`, `credential-unreadable`, `invalid-port`, `listen-failed`, `descriptor-failed`, `internal`.
Logs never contain the token, headers, payloads, snapshots, raw library errors, or a client-supplied request id.

### Evidence scope

Verified on Linux x64 with Bun 1.4.2 (package toolchain), Node 25.2.1 (service process), Chord 1.3.0, TypeBox 1.3.27, `ws` 8.18.3, and `@types/ws` 8.18.1.
The compatibility probe, the process-level service tests, and the recorded commands live in `test/service/`.
Not proven: macOS/Windows lock and transport behaviour, a second non-root UID's wrong-owner refusal by actual access, real terminal-client reattach during a live mission, production throughput, and any T09 replay, T10 supervision, or T11 adapter behaviour.

## Toolchain

Bun must resolve to `>=1.3.0` for this package (`.bun-version` pins `1.4.2`, the version proved in `data/squad-tui-opentui-spike/report.md`).
Every script must be invoked as `bun --bun run <script>`, never the bare `bun run <script>`.
Vitest's worker pool forks a real subprocess, and without `--bun` that subprocess resolves under Node instead of Bun, which this package's dependencies are not proven to support.

Scripts: `test`, `typecheck`, `lint`, `format`, `format:check`, `service`, `service:rotate`.
