---
name: modular-decomposition
description: >-
  Decompose a monolithic codebase into well-defined modules using proven splitting patterns.
  Use when a codebase is too large, tightly coupled, or hard to change because responsibilities
  are tangled across too many files.
license: MIT
metadata:
  source: tech-leads-club/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
user-invocable: true
---

# Modular Decomposition

Use this skill when the codebase is a monolith that resists change.
Apply a structured decomposition pipeline to split it into focused, independently testable modules.

## Patterns

Choose the pattern that fits the dominant coupling:

1. **Split by responsibility** - separate distinct business capabilities into their own modules.
2. **Split by layer** - separate data access, business logic, and presentation.
3. **Split by change frequency** - isolate volatile code from stable code.
4. **Split by team ownership** - give each team a clear module boundary.
5. **Extract shared infrastructure** - pull cross-cutting concerns into a dedicated module.

## Pipeline

1. **Map** - identify the major responsibility clusters and their dependencies.
2. **Classify** - choose a splitting pattern based on the dominant coupling type.
3. **Isolate** - extract the first module behind a clean interface.
4. **Verify** - ensure the extracted module is independently testable and the remaining code still works.
5. **Iterate** - repeat for the next highest-friction cluster.

## Rules

- Extract one module at a time and verify before the next extraction.
- Never split a module that is already cohesive and well-tested.
- Prefer interface extraction over code movement.
- Keep the dependency graph acyclic at the module level.

## Report

For each decomposition step, provide:
- The responsibility cluster being extracted.
- The pattern chosen and why.
- The new module boundary and interface.
- The verification that the split is correct.
- What remains to be decomposed.

## Do not use for

- Small, already-modular codebases.
- Cosmetic reorganization that does not change coupling.
- Decomposition without a verification strategy.
