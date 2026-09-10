---
name: grill-with-docs
description: Interview me to clarify a design, then record settled domain terms and durable tradeoffs in project docs.
license: MIT
metadata:
  source: mattpocock/skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Grill With Docs

Use this skill when a design discussion must leave behind a glossary or an architectural decision record.
Run a focused interview first, then document only decisions that actually became settled.

## Interview

Ask one question at a time.
Start with the outcome, users, and boundaries.
Probe terminology, invariants, edge cases, alternatives, and reversibility.
State each decision back to the user before recording it.

## Documentation

Inspect existing `CONTEXT.md` and `docs/adr/` before creating anything.
Use the project's existing glossary and ADR format when present.
Create `CONTEXT.md` only when a domain term was clarified.
Create an ADR only when the choice is hard to reverse, surprising without context, and the result of a real tradeoff.
Keep the glossary free of implementation details.
Keep one decision in one authoritative document.

## Finish

Report the decisions, changed files, unresolved questions, and the next implementation step.
Do not claim the design is settled while a decision that changes scope or behavior remains open.

## Example

Input: "We need to define what archived means."

Record in the glossary: "Archived means hidden from default lists while retaining history and restore capability."

Create an ADR only if choosing archival over deletion commits the system to a meaningful retention tradeoff.

## Do not use for

- A terminology lookup with no design discussion.
- A routine implementation that has no new domain language or durable tradeoff.
- Writing generic project documentation without a settled decision.
