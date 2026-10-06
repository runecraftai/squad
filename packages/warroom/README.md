# Runecraft Warroom core

This product-neutral package owns a local SQLite event log and a replay-derived canonical state model. It has no Squad runtime, network beyond localhost, Git, or delivery integration.

## Model

Call `Warroom.command()` to make state changes. Each accepted command records one versioned event and updates queryable SQLite records in the same transaction. `Warroom.state()` reconstructs state from ordered events; the event table rejects update and delete operations. Run `migrate()` on open; migrations are versioned and safe to reapply.

Plan and code are immutable revision kinds; a revision is identified by a monotonic identity and carries a SHA-256 digest over its exact UTF-8 content. Restoring earlier identical content creates a new revision with a new identity and the same digest, so digest equality is evidence of identical content rather than revision identity, and a superseded approval never revives. Decisions bind to plan revisions. Plan approval and execution authorization bind to plan revisions; code-review acceptance and merge permission bind to code revisions. These are separate records and no scope grants another scope. Approved code-review acceptance additionally requires passing validation evidence for that exact revision, while rejected and changes-requested reviews are recordable without it. A later revision supersedes every prior approval bound to that kind's earlier revisions, marks their validation evidence stale, and retains their comments as outdated.

This first slice intentionally narrowed the discovery model: it represents a reviewable code snapshot as a `code` revision and its digest, rather than a separate review-packet entity with repository/base/head and patch metadata. The Git adapter and richer review packet belong to a later slice; this core does not claim that a content digest proves Git ancestry or Drill execution.

## Planning surface (slice 2)

Slice 2 adds the planning surface on top of the slice 1 core, with no second source of truth: everything it shows is derived from `events()` and the replayed `state()`.

- **Questions and answers.** `question.ask` asks a structured question against one exact revision (plan or code); `question.answer` binds the answer to that same question. Answering a question that a newer revision has superseded is mechanically rejected (`"question is not open"` / `"question's revision is missing or stale"`) — there is no path to answer against a different revision than the one asked. Like comments, an answered or still-open question is retained, not deleted, and marked `outdated` when its revision is superseded.
- **Revision compare.** `Warroom.compare(initiativeId, a, b)` compares two revisions of the same kind: `identicalContent` reports digest equality and `sameIdentity` reports whether they are the same revision row, so "restored identical content, new identity" (`identicalContent: true`, `sameIdentity: false`) is distinguishable from "genuinely different content" (`identicalContent: false`, with a line-level structural `diff` from `src/diff.ts`). The diff is a plain LCS line diff over revision content — it makes no claim about Git ancestry or patch parsing (that belongs to the slice 3 Git adapter).
- **Initiative timeline.** `Warroom.timeline(initiativeId)` (`src/timeline.ts`) reconstructs the ordered history of one initiative — revisions, decisions, approvals, comments, questions, validation evidence — from events plus the replayed state, annotated with `stale`/`superseded`/`outdated` flags. It introduces no storage of its own.
- **Separate approval and authorization actions.** The surface records plan-approval and execution-authorization as two independent `approval.record` commands against the same plan revision; this was already a slice 1 invariant (distinct `kind`, distinct `subjectRevisionId`, no scope implies another), and slice 2 exercises it through the new surface rather than weakening it.

## Planning surface hosting (slice 2)

`src/server.ts` hosts the planning surface as a local HTTP server (`Bun.serve`, loopback `127.0.0.1` only) serving a single self-contained static page (`src/web/index.html`, no external scripts, fonts, or stylesheets — the forge-table visual direction from the discovery prototype) plus a small JSON API (`GET /api/initiatives`, `GET /api/initiative/:id`, `GET /api/compare/:initiativeId?a=&b=`, `POST /api/command`) that is a thin wrapper around `Warroom`: it performs no validation of its own beyond what the core already enforces. `createApp()` in `src/server.ts` builds the request handler without binding a socket, which is what the HTTP tests in `tests/server.test.ts` exercise directly.

Run it with:

```sh
bun run packages/warroom/src/server.ts [db-path] [port]
```

`db-path` defaults to `./warroom.db` (use `:memory:` for a throwaway run); `port` defaults to `4600`. This is the simplest hosting this package can do on its own: no build step, no bundler, no external service, no network dependency beyond the loopback socket it binds, and no cloud storage — the SQLite file is the only state. It does not include the real Git adapter, Drill JSON ingestion, file tree/diff, or anchored comments (slice 3), and it grants no Squad runtime, approval, or safety authority.

## Verify

From the repository root:

```sh
bun test packages/warroom/tests
bunx tsc --noEmit -p packages/warroom/tsconfig.json
```
