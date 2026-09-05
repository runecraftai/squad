---
name: planning-and-task-breakdown
description: Break a clear feature plan into small dependency-ordered tasks with acceptance criteria and verification steps.
license: MIT
metadata:
  source: addyosmani/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Planning and Task Breakdown

Use this skill when work feels too large, dependencies are unclear, or multiple workers may contribute.
Produce tasks that can each be implemented and verified in one focused session.

## Plan

1. Read the approved specification and relevant project conventions.
2. Map dependencies from foundations to user-visible behavior.
3. Slice vertically so each task leaves a working path.
4. Give every task a description, acceptance criteria, verification, dependencies, files, and scope estimate.
5. Add checkpoints after meaningful groups of tasks.
6. Identify safe parallel work and true serialization points.

Prefer small tasks touching roughly one to five files.
Break a task when it has several independent outcomes or requires more than one session.
Order by dependency, not by convenience.

## Output

Use the project's existing planning format.
If none exists, write `tasks/plan.md` and `tasks/todo.md` without overwriting incomplete work from another initiative.
Keep the plan as an index and keep detailed requirements in their authoritative specification.

## Example

Weak task: "Build authentication."

Strong task: "User can register with a validated email and password; verify with the registration test and API contract test; depends on the user model."

## Do not use for

- A single-file change with obvious scope.
- Replacing a project tracker or closing another plan's tasks.
- Resolving product decisions that have not yet been made.
