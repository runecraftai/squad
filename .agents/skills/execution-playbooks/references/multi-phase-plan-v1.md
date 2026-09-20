# Execution playbook: `multi-phase-plan@1`

## Accepted brief form

This contract accepts `recon` only because the plan is a planning deliverable, not an execution or delivery authority.

## Required sequence

1. State the outcome, the real dependency edges, and the smallest independently verifiable units.
2. Give every unit an explicit verification command or observable result, and identify the handoff from planning to the existing backlog and task lifecycle.
3. Keep the plan at unit level rather than creating tasks per layer, and keep the backlog as the authoritative queue.
4. Record unresolved questions, ordering constraints, and the next safe operator action without scheduling or dispatching work.
5. Leave execution, review, tests, fixes, delivery, and merge to the existing owners.

## Required evidence

- A plan path containing the outcome, dependency graph, unit boundaries, and per-unit verification blocks.
- A proof that units are independently meaningful and are not a layer-by-layer task decomposition.
- An explicit handoff to the existing backlog without adding a field, enum, scheduler, or second queue.
- A next-action record and unresolved-question record when planning cannot safely proceed.

## Exit predicate

The plan is a self-contained deliverable with real dependencies, per-unit verification, and an explicit handoff to the existing backlog; no work is scheduled or executed by this method.

## Stop conditions

Stop when dependencies are speculative, a unit has no meaningful verification, the change is small enough for an ordinary task, or a product or authorization decision is required.

## Ownership and anti-patterns

`AGENTS.md` section 7 owns task decomposition and the backlog owns queueing; this contract only supplies planning evidence.
Do not create tasks per layer, replace the backlog, add a scheduler, infer selection heuristically, or create playbook-owned review, delivery, approval, or terminal authority.
