---
name: learnings-curation
description: Curate Squad startup learnings by consolidating duplicates, slimming entries, and routing procedural facts to authoritative owners.
user-invocable: false
metadata:
  internal: true
---

# learnings-curation

Own the routine curation pass for Squad's local startup-memory files.
This is the only curation procedure for CONSOLIDATE, SLIM, and procedural routing.
Use it from `/debrief` or when session start emits `STARTUP_MEMORY_BUDGET`.

## Triggers

Load this skill when startup reports an exceeded or unverifiable startup-memory budget.
Load it during every `/debrief` before editing an editable memory file.
Load it when routine curation is requested or when `data/learnings.md` is being reduced to environment facts.

## Do NOT use for

Do NOT use this skill to answer commander decisions, change project code, or edit a project's `AGENTS.md` directly.
Do NOT use it to create a new skill or store a report-sized procedure in `data/learnings.md`.
Do NOT curate `data/commander-shared.md` from an XO base; it is a counted, primary-owned read-only input.

## Procedure

1. Run `bin/sq-startup-memory-budget.sh report` and record the effective allowance and per-file totals.
   Stop and report the concrete error if the allowance or any memory file cannot be verified.
2. Read `data/commander.md`, `data/commander-shared.md`, and `data/learnings.md` completely.
   Treat an absent file as absent, and preserve the existing primary/XO ownership rules.
3. Build a retention and routing plan before editing.
   Keep only current commander preferences, stable environment facts, and concise pointers with no stronger owner.
4. **CONSOLIDATE:** merge duplicate or overlapping facts into one current actionable statement.
   Keep the strongest wording and remove incident chronology, stale versions or paths, transient task state, resolved alternatives, and duplicated procedures.
5. **SLIM:** shorten retained entries while preserving the trigger, symptom, remedy, and scope needed to act.
   Prefer a concise environment fact over a narrative, and keep each learning entry within the capture limit.
6. **ROUTE:** apply the existing knowledge-placement decision tree from `squad-coding-guidelines`.
   A tool-specific trap belongs in that script's header, a situation-specific procedure in an existing skill, an every-session rule in `AGENTS.md`, and guaranteed behavior in a hook.
   Route project-intrinsic knowledge through the project's normal delivery path; never write a project's `AGENTS.md` directly.
   Remove a learning only after its durable content is present at the stronger owner.
7. Run `bin/sq-learnings-consolidate.sh` without `--apply`, review every proposed removal or trim, then run it with `--apply` only after the plan is safe.
   Verify the surviving file and its backup after applying; the command must never leave the source empty.
8. Run `bin/sq-startup-memory-budget.sh report` again.
   Do not call the session reset-safe while the total is over budget or an exception remains unresolved.

## Example usage

```text
Session start: STARTUP_MEMORY_BUDGET: exceeded
Action: load learnings-curation through /debrief, route procedural facts, then verify the budget again.
```

## Validation checklist

- [ ] The three startup-memory files were accounted for before and after curation.
- [ ] Duplicate facts were consolidated and retained entries were slimmed without losing actionable content.
- [ ] Procedural facts were routed to existing authoritative script headers, skills, AGENTS.md, or hooks.
- [ ] `data/learnings.md` retains only facts with no stronger owner, including environment facts.
- [ ] `bin/sq-learnings-consolidate.sh --apply` preserved the surviving content and created its backup.
- [ ] The final report is within the effective budget or names the unresolved exception.
