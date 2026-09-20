# Execution playbook: `feature@1`

## Accepted brief form

This contract accepts `strike` only.

## Required sequence

1. State the behavior contract and the authorized surface before implementation.
2. Name the data shape, callers, boundaries, and relevant integration points.
3. Implement a vertical slice that reaches the real surface rather than stopping at an isolated compilation result.
4. Add focused tests and exercise the behavior on the real surface.
5. Leave review, fixes, tests, delivery, and merge to the existing strike lifecycle and drill owner.

## Required evidence

- Behavior contract with expected and rejected behavior.
- Named data shape, callers, boundaries, and integration points.
- Vertical implementation exercised on the real surface.
- Focused test command and result.
- Real-surface proof; compilation alone is not sufficient.

## Exit predicate

The requested behavior is exercised on the real surface with focused tests, and the existing delivery path remains the authority for review, fixes, tests, and delivery.

## Stop conditions

Stop when the surface is unreachable, the design requires a commander decision, or the requested behavior cannot be kept within the authorized scope.

## Anti-patterns

Do not turn a feature into a recon report.
Do not use compilation as the only proof.
Do not create playbook-owned review, delivery, approval, or terminal authority.
