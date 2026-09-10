---
name: spec-driven-development
description: Turn an ambiguous or multi-part feature request into a reviewed, testable specification before implementation.
license: MIT
metadata:
  source: addyosmani/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Spec-Driven Development

Use this skill when a feature is new, ambiguous, spans several capabilities, or will take more than one focused session.
Treat the specification as the shared contract for implementation and verification.

## Specify

1. State the objective, users, scope, and measurable success criteria.
2. Surface assumptions and ask about the ones that could change the design.
3. Define the relevant commands, project structure, style, testing strategy, and boundaries.
4. If the request contains independently testable capabilities, create a small capability map first.
5. Record open questions instead of guessing.

A useful specification covers objective, stack, commands, structure, style, tests, boundaries, success criteria, and open questions.

## Plan and implement

After the specification is accepted, create a dependency-aware plan.
Break the plan into tasks with acceptance criteria and verification steps.
Update the specification before implementing a changed decision.
Keep the specification and implementation in the same project history.

## Example

Vague request: "Make the dashboard faster."

Testable criteria: "Initial data load is below 500 ms on the representative fixture, LCP is below 2.5 seconds, and no layout shift exceeds 0.1."

## Do not use for

- A one-line fix with unambiguous behavior.
- A typo or documentation correction.
- Implementing an already-approved specification without changing its scope.
