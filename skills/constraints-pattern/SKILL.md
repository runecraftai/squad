---
name: constraints-pattern
description: >-
  Define and enforce per-project quality constraints using a CONSTRAINTS.md file.
  Establishes non-negotiable quality bars that every change must satisfy before merge.
  Use when setting up quality standards for a project, auditing whether a project meets its own bar,
  or deciding whether a change is acceptable under the project's constraints.
license: MIT
metadata:
  source: addyosmani/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
user-invocable: true
---

# Constraints Pattern

Use this skill when a project needs enforceable quality standards that every contributor follows.
A CONSTRAINTS.md file makes the quality bar explicit, reviewable, and non-negotiable.

## Create CONSTRAINTS.md

Place `CONSTRAINTS.md` at the project root.
Keep it short, specific, and testable.
Every constraint must be verifiable by a human reviewer or an automated check.

### Structure

```markdown
# Constraints

Non-negotiable quality standards for this project.
Every change must satisfy all applicable constraints before merge.

## Testing

- All new code paths have corresponding tests.
- Tests assert observable behavior, not implementation detail.
- Test distribution follows 80/15/5 (unit/integration/E2E).

## Code quality

- No function exceeds 50 lines.
- No file exceeds 300 lines without explicit justification.
- Public interfaces have doc comments.

## Security

- No secrets in source code.
- External input is validated at system boundaries.
- Destructive operations require confirmation.

## Review

- Every PR has at least one review before merge.
- Review covers correctness, complexity, security, testing, and readability.
```

### Rules

1. Every constraint must be specific enough to enforce.
2. Remove constraints the team does not actually enforce.
3. Add constraints only when a real failure justifies them.
4. Review CONSTRAINTS.md quarterly and prune stale entries.
5. Reference CONSTRAINTS.md in the project's AGENTS.md or contributing guide.

## Enforce

When reviewing a change, check it against every applicable constraint.
If a constraint is violated, flag it as a blocking finding.
If a constraint does not apply to the change type, note why and proceed.

## Do not use for

- Aspirational standards the team is not ready to enforce.
- Style preferences that belong in a linter config.
- One-time fixes that do not set a lasting precedent.
