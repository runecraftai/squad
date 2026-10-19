---
name: knowledge-pass
description: >-
  Load this skill the moment a request asks you to implement, fix, add, refactor, or change code - before the first edit - and again when explaining an existing PR, commit, branch, or diff ("me explica o que foi feito", "passa o conhecimento", "walk me through"). It keeps a decision ledger while you work, then converts the delivery into a code-grounded pass over the problem solved, the rules obeyed, the flow of execution, the decisions taken, and the verification, and verifies the user's understanding one question at a time. Use it even for a one-line fix, and even when the user never asks for an explanation. Do NOT use for code review verdicts, architecture proposals, incident postmortems, or status reports that deliver no code.
license: CC-BY-4.0
user-invocable: true
metadata:
  internal: true
  version: 1.0.0
---

# knowledge-pass

Delegating code is only cheap when the understanding comes back with it.
This skill makes every implementation hand off what it did in a form the user can defend: five short code-grounded sections, then a check that the user actually understood, one question at a time.

## Non-negotiables

- **Every claim carries a code reference** - `path/to/file.ext:120`, or a path plus a symbol.
  A claim you cannot anchor is labeled `[unverified]` or dropped. Confident prose never stands in for a line of code.
- **One question per message.** Two question marks aimed at the user is a bug. Ask, stop, wait.
- **Never answer your own question, and never advance past a wrong answer.**
- **The pass changes nothing about the delivery.** It runs after the delivery has its verdict: it never re-runs the pipeline, never edits code, never blocks a merge or a handoff.
- **The delivered repository stays untouched.** No pass file, no commit, no PR or MR comment. A client-visible surface never carries internal annotations.
- **Write in the user's language**, keeping paths, symbols, commands, and identifiers verbatim.

## Pick the mode

**Author mode** - you are the agent that implemented the change.
Capture while you work; never reconstruct at the end.

**Reviewer mode** - you are relaying someone else's delivery, for example a supervisor reporting a delegated task.
Reconstruct from the diff, commit messages, PR body, tests, and the implementer's report.

Reviewer mode adds one rule: every claim that is not directly readable in the delivered code or the record is marked `[inferred]`.
When a decision's reason is genuinely unrecoverable, ask the implementer; never invent a motive.

## Author mode: keep a ledger while working

Hold five lines in scratch notes as the work happens - in conversation, or in a temp file outside the repository:

1. **Problem** - the symptom, who hits it, before and after in one sentence.
2. **Rules** - constraints the solution must respect: domain and business rules, invariants, compatibility, security, performance.
3. **Flow** - entry point, ordered steps, where the new behavior sits, what happens on failure.
4. **Decisions** - each choice a reviewer would question: the alternative rejected, why, the tradeoff accepted.
5. **Verification** - commands and tests run, what each proves, what remains unverified.

A decision written down when it was made is worth ten rebuilt from a diff.

## Build the pass

Read `assets/knowledge-pass-template.md` before writing.
Keep each section to roughly 5-12 lines, and the whole pass under about 120 lines: this is a briefing, not a design document.

1. **Three-line summary** - problem, mechanism, outcome.
2. **Problem solved** - the observable symptom, the behavior before, the behavior now, and what the change deliberately leaves alone.
3. **Rules** - one line per rule, with where it is enforced. Split domain rules from engineering constraints so the user can tell which is which.
4. **Flow** - the runtime path as numbered hops, each with a reference, plus the failure path.
5. **Decisions** - for each: what was chosen, what was rejected and why, the cost accepted, the residual risk.
6. **Verification** - a table of proof, command or test, what it covers, and what it does not cover. The last column is the most valuable one; never leave it empty.

Reference the code the reader will open, not the file the agent happened to touch: entry point, the rule's enforcement site, the branch that changed behavior, the test that pins it.

## Deliver

The conversation is the delivery surface.
Add a durable copy only when the harness has a private record for it: in Squad, `data/<task-id>/knowledge-pass.md`; elsewhere only when the user asks, and outside the repository.
Never post the pass to a client-visible surface.

If the implementer cannot address the user directly - a delegated worker reporting to a supervisor - the implementer leaves the pass in that private record and stops.
The supervisor relays it and runs the understanding check; the implementer never addresses the user.

## Verify understanding

The pass is not finished until the user has demonstrated the model, not read it.

1. **Plan 3-5 questions**, ordered by leverage: flow mechanism first, then a rule or edge case, then a decision tradeoff, then the verification gap.
   Ask about behavior and consequence - "what happens if X", "what breaks if we had done Y" - never about identifiers, line numbers, or file names.
2. **Ask exactly one.** Ground it in the code: "in `<path:line>`, what happens when `<case>` arrives?"
3. **Wait for the answer.** Then grade it silently:
   - **Understood** - one short confirmation of the key point, then the next question.
   - **Partial** - name the missing piece with its reference, then ask a narrower variant.
   - **Wrong** - re-explain that piece a different way (a concrete trace, a counterfactual, or a smaller example), then re-ask. After two failed attempts, show the exact lines and walk them, then ask the simplest version.
4. **Adapt the count.** A user who answers precisely gets three questions; a shaky area earns the extra depth there instead of more ground.
5. **Close with a three-line map**: what is confirmed, what is still weak, what remains unverified. Then stop - never continue into a fourth round unless asked.

If the user answers with a question, answer it and re-ask the same question.
Never reveal the expected answer before the attempt, and never bundle the remaining questions "so they can answer at once".

## When to skip

Skip the pass when the delivery changes no behavior: docs, comments, formatting, dependency bumps, version strings, test-only tweaks, or renames with no semantic change.
Say in one line why it was skipped; do not silently drop it.

Any behavior change, however small, gets the pass. If you are unsure whether behavior changed, run it.

## Boundaries

- This skill explains a delivery; it does not judge it. Review verdicts belong to the delivery pipeline that produced them.
- It runs after that pipeline's outcome and never replaces, delays, or re-opens it.
- It is not a design proposal, a postmortem, or a progress report.
- When the change is large enough that the pass would exceed its budget, split by behavior, not by file: one pass per user-visible outcome.
