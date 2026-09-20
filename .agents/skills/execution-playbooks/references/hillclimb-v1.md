# Execution playbook: `hillclimb@1`

## Accepted brief form

This contract accepts `strike` only.

## Required sequence

1. State the concrete target, metric, measurement command, baseline, and budget.
2. Run one cycle at a time: record one hypothesis, make one bounded alteration, and run one comparable measurement.
3. Record the metric comparison and the keep, reject, or revert decision for that cycle.
4. Create one commit for each accepted gain; reject an alteration without measurable gain and do not present it as progress.
5. Leave review, fixes, tests, delivery, and merge to the existing strike lifecycle and drill owner.

## Required evidence

- Concrete target, metric, baseline, comparable command, and budget.
- Per-cycle hypothesis, single alteration, measurement, numeric comparison, and decision record.
- One accepted-gain commit per retained improvement, with no-gain alterations rejected or reverted.
- Relevant regression checks and a record of incompatible measurement, unstable baseline, product decision, or exhausted budget stops.

## Exit predicate

The target has a recorded metric result, every retained alteration has a recorded accepted gain and its own commit, and no incompatible or unstable measurement was treated as progress.

## Stop conditions

Stop when the measurement is incompatible, the baseline is unstable, the budget is exhausted, no gain is measured, or a product decision is required.
A no-gain cycle is rejected rather than accepted as a successful iteration.

## Ownership and anti-patterns

This contract is deliberately separate from `perf@1`: perf is a bounded correction, while hillclimb is a sequence of accepted metric cycles.
The P3 matrix recorded hillclimb as defer, but the P5 decision record explicitly authorizes this contract; this contract does not settle or alter that matrix.
Do not create a parallel optimizer, reviewer, verifier, state machine, backlog, terminal, or merge authority.
