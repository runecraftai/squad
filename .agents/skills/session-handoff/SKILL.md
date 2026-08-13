---
name: session-handoff
description: >-
  Deterministic new-session handoff at a milestone close. Load on a
  `handoff-request` operational wake, when the session-start digest's HANDOFF
  REQUESTS section lists records, and before writing a handoff request at a
  milestone close (a merged milestone PR or a drained flight queue). Owns the
  milestone-close write, the handoff-card presentation, and the durable close.
user-invocable: false
metadata:
  internal: true
---

# session-handoff

The commander preference (2026-08-10) makes the new-session suggestion a
deterministic contract: at a milestone close, Squad runs the debrief sweep and
presents a handoff card, then ASKS the commander whether to start a new
session. Never assume or auto-start; the commander owns the `/new` decision.
This skill is the operating contract for the durable mechanism that enforces
it. The mechanism itself - the queue, the surfacer, and the hook surfaces - is
owned by `docs/handoff-request.md`.

## When a milestone closes

A milestone closes when a milestone PR merges or the flight queue drains.
Squad judges that a merge or drain is a milestone close; nothing in the queue
makes that call for it.

Record the close deterministically, in the primary base only:

```sh
bin/sq-handoff-request.sh add pr-merged <key> "<milestone context>"
bin/sq-handoff-request.sh add queue-drained <key> "<milestone context>"
```

- `<key>` is a unique slug for the milestone (`[A-Za-z0-9_.-]`), for example
  the PR number or the milestone id. The same key never records twice, so a
  retried write cannot duplicate the card.
- The context payload names the milestone in plain terms, for example
  `M2 landed via PR https://...` or `flight queue drained (3 items)`.
- `add` is idempotent and safe to call again; a duplicate exits 0 silently.
- Run the debrief sweep when the close happens: load the `debrief` skill and
  let it own the sweep, including the XO cascade.

## When a handoff card surfaces

A card surfaces exactly once per milestone through whichever surface runs
first - the session-start digest's HANDOFF REQUESTS section or the Pi turn-end
extension - as a `handoff-request` operational wake whose body is the card.

On the wake, or when the digest's HANDOFF REQUESTS section lists a card:

1. Load this skill if it is not already loaded.
2. Run the debrief sweep (load the `debrief` skill for the sweep), and present
   its completion receipt alongside the card.
3. Present the handoff card to the commander in plain commander-facing
   language: the milestone that closed, that the debrief sweep completed, and
   the question whether to start a new session now.
4. Never start a new session yourself. The commander owns the `/new` decision.
5. When the commander answers, close the record durably:
   ```sh
   bin/sq-handoff-request.sh resolve <key>
   ```
   A `no` still closes the record - the milestone was handled and the card was
   presented once; a later milestone is a new key. If the commander defers, the
   record stays open and the digest keeps listing it until it is resolved.

## Boundaries

- The queue is per base: an XO base records and surfaces only its own
  milestone closes, never the main base's.
- `sq-handoff-surface.sh` scopes itself to a real primary checkout, so the
  surfacing can never fire from an operator or recon worktree.
- The card is a suggestion, never an approval: starting a new session, merging,
  and every destructive or irreversible action keep their normal commander
  authority from AGENTS.md.
