# Execution playbook: `multi-phase-plan@2`

This version adds the split-or-keep rule to `multi-phase-plan@1`.
Every other section keeps that version's text, and briefs that selected `@1` keep their meaning.

## Accepted brief form

This contract accepts `recon` only because the plan is a planning deliverable, not an execution or delivery authority.

## Required sequence

1. State the outcome, the real dependency edges, and the smallest independently verifiable units.
2. Give every unit an explicit verification command or observable result, and identify the handoff from planning to the existing backlog and task lifecycle.
3. Keep the plan at unit level rather than creating tasks per layer, and keep the backlog as the authoritative queue.
4. Record unresolved questions, ordering constraints, and the next safe operator action without scheduling or dispatching work.
5. Leave execution, review, tests, fixes, delivery, and merge to the existing owners.

## Split-or-keep rule

Decide, for each proposed delivery boundary, whether it becomes a separate stage or stays inside one task, and record that decision with its reason.
Split a delivery only when each stage is independently usable, compatible with the code and data it leaves behind, and verifiable on its own.
A cut or removal also justifies its own stage when it has its own window, acceptance, and reversal, such as retiring a legacy path after its replacement is proven.
Keep the work in one task when splitting would leave a broken intermediate state, or would only repeat review and CI without a separate window, acceptance, or reversal.
For every unit that changes data, state its reversal or recovery path explicitly.
Say that `git revert` restores neither the data nor external effects such as sent messages, emitted events, published artifacts, or an applied migration.
A preparation step counts as reversible only when that unit demonstrates it, never because it is preparation.
Two readings are wrong: this rule does not mean every delivery is four pull requests, and it does not mean every preparation step is reversible.
The split decision adds no field, enum, scheduler, or second queue; it is recorded in the plan this contract already requires.

## Required evidence

- A plan path containing the outcome, dependency graph, unit boundaries, and per-unit verification blocks.
- A proof that units are independently meaningful and are not a layer-by-layer task decomposition.
- An explicit handoff to the existing backlog without adding a field, enum, scheduler, or second queue.
- A next-action record and unresolved-question record when planning cannot safely proceed.
- The split-or-keep decision and its reason for every proposed delivery boundary, plus the reversal or recovery statement for every data-changing unit.

## Exit predicate

The plan is a self-contained deliverable with real dependencies, per-unit verification, and an explicit handoff to the existing backlog; no work is scheduled or executed by this method.

## Stop conditions

Stop when dependencies are speculative, a unit has no meaningful verification, the change is small enough for an ordinary task, or a product or authorization decision is required.

## Ownership and anti-patterns

`AGENTS.md` section 7 owns task decomposition and the backlog owns queueing; this contract only supplies planning evidence.
Do not create tasks per layer, replace the backlog, add a scheduler, infer selection heuristically, or create playbook-owned review, delivery, approval, or terminal authority.
