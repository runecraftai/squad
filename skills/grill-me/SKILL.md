---
name: grill-me
description: Interview me with focused questions to clarify a plan, design, or decision before implementation.
license: MIT
metadata:
  source: mattpocock/skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Grill Me

Use this skill when a good implementation depends on decisions that have not been made yet.
Ask one question at a time and wait for the answer before choosing the next question.

## Method

1. Restate the intended outcome in one sentence.
2. Ask the smallest question that separates the plausible options.
3. Probe constraints, users, failure cases, dependencies, and definition of done.
4. Summarize each decision in plain language before moving on.
5. Stop when the remaining work is implementation detail rather than an unresolved choice.

Prefer concrete scenarios over abstract prompts.
Challenge contradictions respectfully.
Do not answer your own questions or smuggle in a decision through leading wording.

## Output

Finish with:

- Decisions made.
- Assumptions still open.
- Risks that need explicit acceptance.
- A concise implementation-ready brief.

## Example

Input: "I want to add team invitations."

Good question: "Can an invite be accepted by a different email address than the one invited?"

Bad question: "Should I use a signed token for the invite?"

## Do not use for

- A small, unambiguous fix that can be implemented directly.
- A code review where the requested behavior is already explicit.
- A request that asks you to execute an already-approved plan.
