# Durable new-session handoff requests

This is the authoritative current contract for the deterministic new-session
suggestion hook.
The commander preference (2026-08-10) requires: at a milestone close (a merged
milestone PR or a drained flight queue), Squad runs the debrief sweep and
presents a handoff card, then ASKS the commander whether to start a new
session; the commander owns the `/new` decision and it must never auto-start.
This mechanism makes that suggestion deterministic instead of ad hoc.
The operating contract for Squad's side of the flow is the
[`session-handoff`](../.agents/skills/session-handoff/SKILL.md) skill, and the
debrief sweep itself stays owned by the `debrief` skill.

## Durable queue

`state/.handoff-queue` is a per-base append-only queue of milestone closes,
one record per line, TAB separated:

```
ts<TAB>seq<TAB>kind<TAB>key<TAB>state<TAB>payload
```

- `ts` is the epoch second the record was written.
- `seq` is a monotonic per-base counter (`state/.handoff-queue.seq`) that is
  never reused.
- `kind` is the milestone-close reason: `pr-merged` or `queue-drained`.
- `key` is a unique milestone slug (`[A-Za-z0-9_.-]`). `add` never creates a
  second record for the same `kind`+`key` in any state, so the
  once-per-milestone guarantee holds at the source.
- `state` is the record lifecycle: `pending` -> `surfaced` -> `resolved`.
- `payload` is the milestone context (tabs, newlines, and carriage returns are
  collapsed to spaces by the writer, so the TAB wire format cannot break).

All mutations run under the shared `state/.handoff-queue.lock` (the portable
lock helpers from `bin/sq-stand-to-lib.sh`), so a concurrent surfaver can
never observe or double-mark a partial transition.
Each base owns its own queue: an XO base records and surfaces only its own
milestone closes in its own `state/`, exactly like every other base-local
durable record.

## Writer

`bin/sq-handoff-request.sh` is the single owner of the wire format and the
state machine.

```sh
bin/sq-handoff-request.sh add <kind> <key> <payload...>
bin/sq-handoff-request.sh resolve <key>
bin/sq-handoff-request.sh list [--all|--pending|--surfaced|--open]
```

- `add` writes a `pending` record and is idempotent by `kind`+`key`: a
  duplicate leaves the existing record untouched, prints nothing, and exits 0,
  so a retried milestone-close write cannot duplicate the card.
- `resolve` moves the record for `key` to `resolved`; Squad runs it when the
  commander answers, whether the answer is yes or no.
- `list` prints records newest first; the default `--open` filter (pending and
  surfaced, everything not yet resolved) is the still-actionable set a session
  start must see.

## Surfacer and the once-per-milestone guarantee

`bin/sq-handoff-surface.sh` is the single surfacing authority.
Under the queue lock it atomically moves every `pending` record to `surfaced`
and prints the handoff card for each record it just surfaced.
A second call finds nothing pending and prints nothing.
That atomic mark is what makes the card appear exactly once per milestone no
matter how many surfaces race.
The surfacer scopes itself to a real primary checkout with
`bin/sq-primary-scope-lib.sh`, so an operator or recon worktree that runs the
same tracked file stays silent.

The card names the milestone, the reason, and the context, and carries the
exact `sq-handoff-request.sh resolve <key>` command so the record can be
closed durably after the commander answers.

## Hook surfaces

Two primary surfaces call the surfacer; whichever runs first presents the
card, and every later call stays silent.

- **Session-start digest** (`bin/sq-session-start.sh`): the unit-state section
  emits a `HANDOFF REQUESTS` subsection that runs the surfacer (marking and
  printing any pending card) and then lists the still-open records, so a
  presented-but-unanswered question stays visible across restarts.
  A read-only session never runs the surfacer; it only lists.
- **Pi turn-end extension** (`.pi/extensions/sq-primary-turnend-guard.ts`):
  the `agent_settled` handler runs the surfacer after every agent run and
  delivers a printed card as a typed `handoff-request` operational wake via
  `pi.sendUserMessage(..., { deliverAs: "followUp" })`, exactly like the
  turn-end guard delivers its banner.
  The wake is structurally typed through `bin/sq-operational-input.sh`, so
  Reporting does not treat an injected card as a commander message.

Other primary harnesses inherit the session-start surface, which is
harness-agnostic: their session-open adapters already run the digest.

## Operational wake kind

`handoff-request` is a current construction kind of the canonical
operational-input protocol, owned by `bin/sq-operational-input.sh` and
mirrored in `.pi/extensions/lib/sq-operational-input.ts`.
It exists so the injected card is structurally typed and never mistaken for
commander-authored text.
The `session-handoff` skill owns handling the wake and closing the record.

## Regression coverage

`tests/sq-handoff-queue.test.sh` covers the record format, the writer's
idempotence and validation, the surfacer's atomic once-per-milestone mark
(including a concurrent-surfacer race), the primary-scope silence, and the
payload sanitization.
`tests/sq-turnend-guard.test.sh` proves the Pi extension injects a pending card
exactly once as a typed `handoff-request` follow-up, and `tests/sq-session-start.test.sh`
proves the digest surfaces a pending card once and keeps the open question
listed on later starts.
`tests/sq-operational-input.test.sh` pins `handoff-request` as a current
construction kind, and `tests/sq-pi-primary-types.test.sh` typechecks the
extension change.
