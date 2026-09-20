# Execution playbook: `perf@1`

## Accepted brief form

This contract accepts `strike` only.

## Required sequence

1. State the measured surface, reproducible baseline command, environment, and budget before changing code.
2. Capture a baseline profile or trace and record its artifact identity and stability across repeated runs.
3. State one hypothesis grounded in the baseline and make the smallest authorized change that tests it.
4. Repeat the identical measurement command on the same surface and compare numeric results with relevant regression checks.
5. Leave review, fixes, tests, delivery, and merge to the existing strike lifecycle and drill owner.

## Required evidence

- Reproducible baseline command, environment, surface, and repeated baseline measurements.
- Baseline profile or trace with a path or artifact identity.
- Trace-grounded hypothesis and smallest-change record.
- Before/after numeric comparison using the identical command and a relevant regression check.
- Stop or reclassify record when the measurement is incompatible, the baseline is unstable, or a product decision is required.

## Exit predicate

The same measurement on the same surface shows an accepted numeric comparison with no relevant regression, and the existing delivery path remains authoritative.

## Stop conditions

Stop when the measurement is incompatible, the baseline is unstable, no hypothesis survives the evidence, the budget is exhausted, or a product decision is required.

## Ownership and anti-patterns

`diagnostic-reasoning` owns causal reasoning where diagnosis is needed, and drill owns review, tests, fixes, and delivery.
Do not invent a profiling tool, global improvement threshold, automatic classifier, second verifier, or playbook-owned authority.
Do not compare different commands, surfaces, environments, or unstable baselines as if they were one measurement.
