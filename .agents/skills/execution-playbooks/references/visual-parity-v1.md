# Execution playbook: `visual-parity@1`

## Accepted brief forms

This contract accepts `recon` when the deliverable is a visual-parity report and `strike` when it validates an already authorized change.
The `kind` remains the free-form `sq-tasks` dimension; this contract does not reclassify or close that field.

## Required sequence

1. Identify the same surface, viewport, data, and state for the prior reference and the posterior capture.
2. Capture or cite the reference and posterior artifacts with repeatable commands and stable names.
3. Compare the paired artifacts, name every material divergence, and record the decision or validation result.
4. For recon, stop at the report and do not implement; for strike, leave review, tests, fixes, delivery, and merge to the existing lifecycle.

## Required evidence

- Prior and posterior reference paths with surface, viewport, data, and state identity.
- Reexecuted comparison command and named divergence list, including an explicit no-diff result when applicable.
- Stop record when the baseline is wrong, the surface or state is incompatible, the comparison capability is unavailable, a product decision is required, or the budget is exhausted.
- A report predicate for recon or an authorized-change validation predicate for strike.

## Exit predicate

The paired comparison is reexecutable on the same controlled surface and its named divergences support the applicable recon report or strike validation result.

## Capability boundary

Squad has browser automation through `sq-browser`, but this contract does not invent a visual-regression harness or claim pixel-diff automation that is not present.
If the plan requires an unavailable image-diff capability, record that as a finding and stop rather than silently weakening the comparison.

## Anti-patterns

Do not compare different viewports, data, states, or surfaces.
Do not treat a plausible screenshot as proof without a repeatable comparison.
Do not create playbook-owned review, delivery, approval, or terminal authority.
