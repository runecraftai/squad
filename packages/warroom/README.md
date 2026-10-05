# Runecraft Warroom core

This product-neutral package owns a local SQLite event log and a replay-derived canonical state model. It has no Squad runtime, UI, network, Git, or delivery integration.

## Model

Call `Warroom.command()` to make state changes. Each accepted command records one versioned event and updates queryable SQLite records in the same transaction. `Warroom.state()` reconstructs state from ordered events; the event table rejects update and delete operations. Run `migrate()` on open; migrations are versioned and safe to reapply.

Plan and code are immutable revision kinds identified by SHA-256 over exact UTF-8 content. Decisions bind to plan revisions. Plan approval and execution authorization bind to plan revisions; code-review acceptance and merge permission bind to code revisions. These are separate records and no scope grants another scope. Review acceptance additionally requires passing validation evidence for that exact revision. A later revision supersedes every prior approval bound to that kind's earlier revisions, marks their validation evidence stale, and retains their comments as outdated.

This first slice intentionally narrows the discovery model: it represents a reviewable code snapshot as a `code` revision and its digest, rather than a separate review-packet entity with repository/base/head and patch metadata. The Git adapter and richer review packet belong to a later slice; this core does not claim that a content digest proves Git ancestry or Drill execution.

## Verify

From the repository root:

```sh
bun test packages/warroom/tests
bunx tsc --noEmit -p packages/warroom/tsconfig.json
```
