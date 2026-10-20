# Runecraft Warroom — review slice

This private package owns a local SQLite event log, a replay-derived state model, the planning surface built in earlier slices, and the first code-review slice: a human review of one real Drill-validated change at an exact revision, before merge.

It is a private prototype in this repository.
It is not published, not distributed, and not a Drill replacement.

## What this slice adds

The existing core already records initiatives, immutable plan and code revisions, decisions, approvals, comments, questions and validation evidence, with append-only events and replay-derived projections.
This slice extends that core additively instead of building a second store:

- **Review packet.** One packet binds an initiative, a plan revision and its digest, a local repository fingerprint, the explicit review base, the head, both Git trees, a complete file manifest, the patch, a scope digest, Drill evidence and a packet digest.
  The code revision's content is the deterministic manifest serialization, not free text pretending to be code.
- **Captured evidence.** A read-only adapter reads exactly one named Drill run from the SQLite database the run owner provides, records the run identity, Drill version and build, the Drill base, the submitted, review-approved and delivered heads, the native step results with exit codes, rounds, CI readiness and eligibility reasons.
  A capture is immutable and stored by digest.
  Digests detect alteration; they do not authenticate origin, and the adapter makes no claim that Warroom validated anything.
- **Anchored comments and suggestions.** Comments can bind to a plan range, a flow node, a code range or the review itself.
  A code anchor stores the packet, path, side, line range, blob id and snapshot digest, so it never silently travels to another snapshot.
  A suggestion is stored text only; Warroom never applies it, writes Git, resolves conflicts or publishes a review.
- **Scoped acceptance.** Human acceptance records actor, declaration, packet digest, the complete scope digest and the evidence digest.
  It is refused when the packet is stale or corrupt, the scope is partial, the evidence is not an eligible real Drill capture for the delivered head, the currentness source is unavailable, or the actor was not confirmed by the local session.
- **Currentness and supersession.** A packet is stale when the recorded head, observed target base, current plan revision, scope or evidence no longer matches, and stays visible as history.
  A new head never inherits the previous evidence or acceptance.
- **Static export.** `GET /api/review/:packetId/export` renders a derived, escaped, fully offline HTML snapshot with revision identities and digests.
  It contains no scripts, remote resources, approval control or merge control, and it changes no review state.
  `sq-report export` may package that HTML locally; it does not generate or validate its content.

Approval scopes remain separate and never imply one another.
Plan approval, execution authorization, code-review acceptance and merge permission are distinct records, and this surface never emits merge permission.

## Contract and limits

- Warroom reads Git only through explicit objects and refs (`rev-parse`, `merge-base`, `ls-tree`, `cat-file`, `diff --no-ext-diff --no-textconv --full-index --no-renames --binary`).
  It never checks out, commits, pushes, merges, runs a validation step, answers a Drill finding, or mutates the Drill database or its own source repository.
- Browser requests never choose a filesystem path or database.
  File content is looked up only through the stored manifest, and every displayed byte comes from an immutable artifact.
- Review commands require the exact local `Host` and `Origin` plus a per-session token.
  The acting identity comes from the local server session, never from a request body.
  The generic command API refuses validation evidence, review acceptance and merge permission, so it cannot bypass these checks.
- Currentness is verified against the recorded local refs, not the forge.
  The display says so, and a previous acceptance never becomes standing merge authorization.
  Squad remains responsible for checking the pull request, base, head and checks before any merge.
- The trust scope is one person, one machine, one writer process.
  This slice does not claim externally authenticated identity or protection from another process already running as the same user.
- Fixture and manually supplied evidence is stored visibly and is always ineligible for human acceptance.
  Synthetic data can exercise the flow without masquerading as a real Drill result.

## Reuse decisions

- The core, planning surface, questions and timeline are extended, not rebuilt.
- `sq-report` is used only as an optional local packager for a derived HTML export; it is not a store and not an approval surface.
- `visual-explainer` is a method reference only: claims link to code, before/after, scope, risk, evidence and explicit unknown rationale.
- Nothing is copied from Plannotator or the referenced videos in this slice.
  Reading Drill's internal SQLite schema is a private, versioned adaptation confined to `src/drill-evidence.ts`; it is not a Drill API.

## Commands

Capture one real change from one named Drill run and one named local repository.
Every input is explicit; there is no default run, repository, base or head.
Base and head are derived from the named objects and must match the Drill-delivered head.

```sh
bun run packages/warroom/src/review-cli.ts capture \
  --repo "$REVIEW_REPO" \
  --drill-db "$DRILL_DB" \
  --drill-logs "$DRILL_LOGS" \
  --repo-id "$DRILL_REPO_ID" \
  --run "$RUN_ID" \
  --target-ref "$TARGET_REF" \
  --head-ref "$HEAD_REF" \
  --plan "$PLAN_REVISION_ID" \
  --warroom-data "$WARROOM_DATA"
```

The command prints the packet id, packet digest, evidence digest, manifest digest, scope digest and the derived base and head.
Repeating the same capture is idempotent and adds no duplicate event.

Check currentness without writing:

```sh
bun run packages/warroom/src/review-cli.ts check --warroom-data "$WARROOM_DATA" --packet "$PACKET_ID"
```

It exits non-zero unless the packet is ready, its currentness is verified and its evidence is eligible, and prints JSON with the full reasons and observations.
The serving layer calls the same function before recording acceptance.

Serve the local surface over private data:

```sh
WARROOM_ACTOR=commander bun run packages/warroom/src/server.ts "$WARROOM_DATA/warroom.db" 4600
```

Open `http://127.0.0.1:4600/`.
The page embeds a per-session token; the actor is the declared local session identity, and the browser never supplies an actor.
Use `:memory:` for a throwaway database.

Export the derived snapshot and optionally package it locally:

```sh
curl -sS "http://127.0.0.1:4600/api/review/$PACKET_ID/export" -o "$SNAPSHOT_HTML"
sq-report export "$SNAPSHOT_HTML" --out "$EXPORT_HTML"
```

Neither step records acceptance, and neither authorizes merge.

## Verify

```sh
bun test packages/warroom/tests
bun run --cwd packages/warroom typecheck
bunx --no-install playwright test --config packages/warroom/playwright.config.ts
```

The browser suite runs only against a private fixture server with a disposable Git repository, a synthetic Drill-shaped database and private Warroom data.
It blocks every non-loopback request and never records a human acceptance.
