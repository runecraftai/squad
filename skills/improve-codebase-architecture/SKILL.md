---
name: improve-codebase-architecture
description: Audit a codebase for shallow modules and propose focused refactors that improve locality, testability, and change leverage.
license: MIT
metadata:
  source: mattpocock/skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Improve Codebase Architecture

Use this skill when code is hard to understand, test, or change because responsibility is scattered.
Look for a small number of high-leverage improvements rather than a broad rewrite.

## Audit

1. Read the project glossary and relevant ADRs first.
2. Use recent history to find hot spots unless the user named a scope.
3. Trace the real call path through the candidate area.
4. Find modules whose interface is almost as complex as their implementation.
5. Apply the deletion test: would removing this module concentrate complexity or merely move it?
6. Note missing tests, leaky seams, duplicated decisions, and unnecessary hops.

Use these terms precisely: module, interface, depth, seam, adapter, leverage, and locality.
Treat the interface as the test surface.
Do not propose a refactor until the current friction is evidenced by code or tests.

## Report

For each candidate, provide files, observed problem, proposed deepening, locality benefit, leverage, test strategy, risk, and recommendation strength.
Include a simple before and after dependency diagram when relationships are the source of friction.
Recommend one candidate first and explain why.
Ask which candidate to explore before designing its replacement interface.

## Example

Finding: a request flow spreads authorization, parsing, and persistence across six thin wrappers.

Candidate: deepen the request-intake module behind one tested interface, leaving external adapters at the seam.

## Do not use for

- A greenfield architecture where no current friction exists.
- A formatting or naming cleanup.
- An implementation request that does not need architectural choices.
