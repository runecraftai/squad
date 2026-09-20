# Execution playbook: `refactoring@1`

## Accepted brief form

This contract accepts `strike` only.

## Required sequence

1. Capture the existing behavior before changing structure.
2. Name the invariants and target shape that constrain the transformation.
3. Subtract before adding and keep each transformation bounded.
4. Prove equivalence on the real artifact with characterization and focused tests.
5. If any observable behavior changes, stop and reclassify the work as a feature.
6. Leave review, fixes, tests, delivery, and merge to the existing strike lifecycle and drill owner.

## Required evidence

- Characterization test or equivalent capture from before the change.
- Named invariants and target shape.
- Bounded transformation record.
- Equivalence proof on the real artifact.
- Focused test command and result, including the observable-behavior reclassification check.

## Exit predicate

The real artifact preserves observable behavior, the named invariants hold, and equivalence is proven by the focused evidence.

## Stop conditions

Stop and reclassify as `feature@1` if observable behavior changes, or stop when equivalence cannot be proven or a commander decision is required.

## Anti-patterns

Do not smuggle a behavior change into a refactoring.
Do not add replacement structure before removing the bounded target where subtraction is possible.
Do not create playbook-owned review, delivery, approval, or terminal authority.
