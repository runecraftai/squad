---
name: codebase-design
description: >-
  Apply deep module design vocabulary to evaluate and improve codebase architecture.
  Use when reasoning about module boundaries, interface depth, abstraction quality,
  dependency direction, or architectural leverage in an existing codebase.
license: MIT
metadata:
  source: mattpocock/skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
user-invocable: true
---

# Codebase Design

Use this skill when the codebase has shallow modules, tangled dependencies, or unclear boundaries.
Apply precise design vocabulary to diagnose problems and propose focused improvements.

## Terms

Use these terms precisely.
Each names a distinct design concept; do not use them interchangeably.

- **Module** - a unit of code with a defined interface and internal implementation.
- **Interface** - the public surface a module exposes; the contract consumers depend on.
- **Depth** - the ratio of interface simplicity to implementation complexity.
  A deep module has a simple interface hiding significant behavior.
- **Seam** - a point where behavior can be changed without modifying the surrounding code.
- **Adapter** - a thin translation layer between two modules with different interfaces.
- **Leverage** - the ratio of benefit to effort; a high-leverage change improves many things at small cost.
- **Locality** - related code lives together; unrelated code is separated.

## Audit

1. Identify the modules in the scope under review.
2. For each module, assess its depth: is the interface almost as complex as the implementation?
3. Check dependency direction: do details depend on abstractions, or vice versa?
4. Find seams where behavior could be swapped, tested, or extended independently.
5. Look for leaky abstractions: internal details escaping through the public interface.
6. Apply the deletion test: would removing this module concentrate complexity or merely move it?

## Report

For each candidate improvement, provide:
- The module and its current interface.
- The observed design problem (shallow, leaky, tangled, misplaced).
- The proposed change with interface sketch.
- The expected benefit (testability, locality, leverage).
- The risk and confidence level.

Recommend one improvement first and explain why it has the highest leverage.
Ask which candidate to explore before designing its replacement interface.

## Do not use for

- Greenfield projects with no existing friction.
- Naming or formatting cleanups.
- Implementation requests that do not require architectural choices.
