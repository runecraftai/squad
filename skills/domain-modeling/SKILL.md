---
name: domain-modeling
description: Clarify domain language, relationships, invariants, and boundaries, then maintain the project's glossary.
license: MIT
metadata:
  source: mattpocock/skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Domain Modeling

Use this skill when the team is using vague, overloaded, or conflicting domain terms.
A domain model names concepts and rules without prescribing implementation.

## Build the model

1. Read the existing `CONTEXT.md` or equivalent glossary.
2. Extract nouns, verbs, states, actors, and relationships from the request.
3. Ask for concrete scenarios that distinguish similar concepts.
4. Define each term with its meaning, ownership, lifecycle, and important invariants.
5. Check the proposed language against the code and surface contradictions.
6. Update the glossary immediately when a term is settled.

Prefer canonical terms that make requirements and tests readable.
Do not use a familiar technical term when the business meaning differs.
Keep implementation choices out of the glossary.

## Example

If "account" could mean a person, an organization, or a billing relationship, ask which one owns the invitation and which one receives access.
Record separate terms when those concepts have different lifecycles.

## Finish

List new terms, renamed terms, relationships, invariants, and unresolved ambiguities.
Point implementation work to the glossary instead of repeating definitions elsewhere.

## Do not use for

- Designing database tables without first resolving domain meaning.
- A code review focused only on syntax or performance.
- Editing prose when the underlying terminology is already clear.
