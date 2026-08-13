---
name: debrief
description: Sweep the current session for uncaptured durable knowledge and file it to disk before a context reset. Use when the commander invokes /debrief (e.g. "/debrief", "debrief what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the Squad-internal skill. The public, installer-facing counterpart lives at skills/debrief/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# debrief

Sweep this session for durable knowledge that exists only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
This skill writes only through the existing Squad ownership and write boundaries.

## Required startup-memory pass

Every `/debrief` invocation performs this complete pass, even when the session contains no new finding:

1. Run `bin/sq-startup-memory-budget.sh report` before considering a write.
   Record its effective budget and each file's estimated-token total.
   The budget is per base: this base's three files against this base's own allowance, never a unit total.
   The helper's stable estimate is the documented conservative local approximation, not provider-exact accounting.
   If it rejects the setting or a memory file, do not infer a default or silently continue.
   Report that concrete exception and do not call the session reset-safe.
2. Read every current memory file completely: `data/commander.md`, `data/commander-shared.md`, and `data/learnings.md`.
   Treat an absent local file as absent, not as an invitation to manufacture content.
   In a primary base, all three are curation inputs under their existing ownership rules.
   In an XO base, `data/commander-shared.md` is a read-only primary-owned input: count it, never edit it, and curate only the editable local files.
3. Build one whole-file retention plan before editing.
   Retain, in order: current commander preferences, authority and safety boundaries, and recurring working style; stable base-local operating facts that repeatedly affect future work and are expensive to rediscover; then concise pointers to an existing authoritative report, project document, configuration, or backlog item.
   Retain lower-priority material only while budget remains.
4. Consolidate every editable memory file as needed, not only the file apparently related to a new finding.
   Prefer one concise current rule or authoritative pointer over duplicate prose.
   Remove, merge, or route completed incident and release chronology, stale versions and paths, transient task state, resolved alternatives, old metrics, superseded claims, duplicates, and report-sized procedures.
   Do not remove a unique current fact unless it is preserved directly elsewhere through a stronger existing owner.
5. Run `bin/sq-startup-memory-budget.sh report` again after the complete pass.
   Finish at or below the effective budget unless a concrete inability remains.
   An XO must explicitly report `primary-owned-shared-file-alone-exceeds-budget` when the inherited shared file alone exceeds its allowance, because local curation cannot resolve it.
   Any other unresolved excess must identify the fact that cannot safely be removed or routed and why.

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Before allowing it, consolidate enough lower-priority material to remain within budget.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

## Knowledge sweep and routing

1. **Sweep the session for uncaptured durable knowledge.**
   Look for operational learnings, commander preferences expressed in passing, project-intrinsic facts, standing decisions, and undone next steps.
2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md section 6 is the source of truth for destinations.
   Do not re-derive or duplicate that mapping here.
3. **Write within the existing boundaries.**
   - Commander preferences and unit-local operational facts belong in the destination selected by AGENTS.md after the required whole-file curation pass.
     Create `data/learnings.md` only for a genuinely new local learning with no stronger owner.
   - In a primary base, curate shared commander preferences only under the existing primary-authoritative shared-preference contract.
     In an XO base, route a newly discovered shared preference to the main Squad through marked status or a document pointer instead of editing the inherited file.
   - Project-intrinsic knowledge never goes directly into a project's `AGENTS.md`.
     Route it through a normal strike task so an operator records it with `bin/sq-ensure-agents-md.sh` and the project's delivery path.
   - Knowledge general to every Squad user belongs in this repo's shared tracked material through the normal branch, drill, PR, and commander-merge path.
   - For task-scoped notes, inspect the item with `sq-tasks show <id> --full`, classify the change as new, duplicate, superseding, or obsolete, then use a considered replacement body through `sq-tasks update <id> --body-file <path>`.
     Use `--archive-body` when recoverability matters.
     Never append.
   - File each undone next step as a queued backlog item with a genuine `blocked-by` dependency when applicable.
4. **Use inspect-then-update.**
   For every retained fact, ask which current statement it supersedes, whether it can be a one-sentence rewrite, and whether a stale entry should be deleted, retired, or routed to an existing stronger owner.
   The only graduation moves are promotion to tracked shared material through a PR, folding a learning into the commander-preference destination selected by AGENTS.md, or deletion of a stale entry.
   Do not invent another graduation path.

## Completion receipt

Report the outcome in plain commander-facing language with all of these facts:

- effective startup-memory budget and total estimated tokens before and after;
- one or more actions for each of `data/commander.md`, `data/commander-shared.md`, and `data/learnings.md`: `unchanged`, `added`, `rewritten`, `pruned`, or `routed`;
- each durable finding filed outside memory and its authoritative owner;
- every unresolved exception, including a primary-owned shared-file constraint in an XO base;
- whether the session is safe to reset, only when all durable findings are captured and the post-pass result is within budget with no exception.

Do not hide an over-budget result behind a reset-safe claim.
In a primary base the receipt is written after the cascade below, not instead of it.

## Automatic cascade to XOs

In a primary base, every `/debrief` cascades to every registered XO after this base's own required pass and knowledge sweep are complete.
In an XO base, `/debrief` curates that base only and never cascades further.
The cascade changes nothing until `/debrief` is invoked: it adds no notification, no digest section, and no background work.

Run `bin/sq-debrief-cascade.sh` once the primary's own pass is done.
It enumerates each registered XO exactly once, reports that base's own budget accounting, and resolves how the sweep reaches it; its header owns the stanza fields, the bound, and the exit codes.
Every base is judged against its own `config/startup-memory-budget` allowance, so never add bases together or treat one base's excess as another's.

Act on each base by its reported `transport`:

- `agent` - send the marked request with `bin/sq-send.sh sq-<id> "<request>"` so the live XO performs its own `/debrief`, including the uncaptured knowledge that exists only in its session.
  Ask it for the same completion receipt this skill defines, and read its reply from its status file or the document it points to, never from its chat.
- `direct` - curate that local base's editable memory files yourself under the same retention plan, then re-run the cascade to confirm the after totals.
  `data/commander-shared.md` stays a read-only counted input there, exactly as it is in any XO base.
- `deferred` - a remote base with no live agent. Its memory is accounted read-only and cannot be curated from here, because there is no generic remote write path for a base's own memory files.
  Report it as an unresolved exception and leave it to its next cascade.
  Relaunching that XO is a separate decision owned by `xo-provisioning`, never something `/debrief` does on its own.
- `unavailable` - that base's own accounting did not complete. Report the concrete exception and continue; a slow or unreachable base never blocks this base's `/debrief`.

A newly discovered shared commander preference still routes to the primary's `data/commander-shared.md` under the existing primary-authoritative contract, whichever base found it.

Extend the completion receipt with one entry per XO alongside the primary's own, carrying that base's budget before and after, its per-file actions, its exceptions, and whether that base swept itself or was curated from here.
Keep those entries in the same plain commander-facing language the rest of the receipt uses.
The session is reset-safe only when every base is within its own budget with no unresolved exception.

## Scope exclusion: no skill storage

`/debrief` must never store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
Until a human deliberately scopes a skill change as Squad repository work, route generalizable knowledge to shared tracked material through its pipeline and unit-local knowledge to `data/`, never to `.agents/skills/` or public `skills/`.
