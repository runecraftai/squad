---
name: sitrep
description: >-
  Generate a "pick up where I left off" unit digest from Squad's live unit state.
  Use when the commander invokes /sitrep or asks for a sitrep report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /sitrep is chat-only by default, while /sitrep file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact; live PR enrichment remains opt-in and composes with file mode.
user-invocable: true
metadata:
  internal: true
---

# sitrep

Generate a complete current snapshot from the unit's current state, so the commander can resume in one read after a break, a night, or a context reset.
Plain `/sitrep` returns only the concise four-section chat digest.
Only `/sitrep file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.
This skill is operationally read-only in both modes.
It never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, mutates backlog or task state, or writes any file except the single dated report in explicit file mode.

## Invocation modes

- Plain `/sitrep` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/sitrep file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the four-section chat digest with a link or path to that report.
- Treat `file` only as an explicit invocation option in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", or "make a file" as file mode unless the invocation explicitly includes the standalone `file` option.
- When the commander asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/sitrep include PRs` remains chat-only and makes the live-PR opt-in.
- `/sitrep file include PRs` writes the dated report and makes the live-PR opt-in.

## What it does

1. **Gather live unit state with one deterministic command.**
   Run `bin/sq-sitrep-snapshot.sh` at invocation time and read its compact output.
   It is the single bounded, deterministic unit-state source for Sitrep and renders TOON by default.
   Do not create or consult a second unit-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `sq-gh`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   Keep the default local-only read unless the commander asks to include PRs.
   For registered XOs, use the snapshot's structured-base classification and provenance.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured base state.
   Structured commander-held decisions come from `decision-hold-lifecycle` and appear under `decisions_open`.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived.
   Until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Charted Next with the related `omitted` disclosure, never invent an Underway row from backlog-only state, and never move it into Commander's Call.

2. **Compose the four-section chat digest from the fresh snapshot.**
   The gather step is deterministic; your judgment is scoped to ranking the command's facts by what matters right now and writing scannable commander-facing prose.
   The chat response uses the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

3. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Sitrep - <day> <YYYY-MM-DD>` (use "Morning status" only when the commander specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Commander's Call** - every open decision summarized with its options from the structured decision record, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state across the main unit and every registered XO base, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state, and the plans or main pickup pointers worth reopening (`data/<id>/report.md` files, `.lavish/*.html` boards).
   - **Charted Next** - queued or gated work, including any main-inventory integrity warning, with each item's blocker, date, or integrity reason.
   After writing the file, return the concise four-section chat digest and include the report path or link without adding a fifth section.
   For a richer review surface, optionally offer a Lavish board with `sq-report` when the report has enough structure to deserve one, but only after the required digest is ready.

## Chat-response contract

This skill is the one owner of the `/sitrep` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/sitrep` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Commander's Call** - ONLY items that need the commander's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the commander can clear.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main unit and every registered XO base.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report.
   Empty-state: "Nothing is underway."
4. **Charted Next** - queued or gated work waiting on the unit or a date, plus action-free unit-integrity warnings, never on the commander.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- The four buckets are mutually exclusive, so every item is forced into exactly one: needs-your-action is Commander's Call, done is Recently Landed, self-progressing is Underway, and not-yet-started work or an action-free unit-integrity warning is Charted Next.
- The strict boundary keeps action-free items OUT of Commander's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed recon's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Commander's Call.
- An XO's own row appears Underway only for `active_child_work`; `externally_held` belongs in Charted Next, and `unknown` belongs there as an unavailable-state gate unless its reason requires the commander's action.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` base merely because that XO's own row is `unknown`.
- Include the required direct address to the commander inside one item or empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Detailed decisions, plans, full gate reasons, and evidence belong in the file only when file mode is explicit, so plain chat stays concise and file-mode chat stays materially shorter than that file.
- In file mode, include the report path or link inside the four-section digest without adding another heading.

## Tone and content rules

- The optional file-mode report is a private, commander-facing internal artifact that lives in gitignored `data/`, so unlike normal commander chat it MAY reference task ids, PR URLs, and repo names.
- The commander works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this unit.

## Supervision discipline

This skill changes no unit state.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any `state/` or `data/` file other than the single report file in explicit file mode.
If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, or a needs-decision finding - name it in its section and leave the action to the normal lifecycle and configured authority rather than taking it from inside this skill.
