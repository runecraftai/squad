# Execution playbook: `runtime-forensics@1`

## Accepted brief form

This contract accepts `recon` only.

## Required sequence

1. State the live symptom, authorized diagnostic scope, and instrumentable running process before modifying it.
2. Capture the live signal first, preserve a timeline, and reduce the observation to a smoking gun without silently changing the scenario.
3. Prove the mechanism with causal evidence and map it to a source location.
4. End with a self-contained diagnosis; a fix is outside recon and requires explicit later promotion.

## Required evidence

- Live symptom, process/surface identity, instrumentation command, and before-modification capture.
- Timeline from live signal to reduced finding and mechanism proof.
- Causal diagnosis with source location and cited runtime artifact.
- Stop record for unavailable instrumentation, unreadable artifact, unprovable mechanism, product decision, or exhausted budget.

## Exit predicate

The recon report contains a cited live diagnosis, a proven mechanism, and a source location, with no fix claimed as delivered.

## Ownership and anti-patterns

`diagnostic-reasoning` owns the causal framework; this contract adds only the live-process instrumentation discipline.
Do not modify the process before capturing the symptom, invent a forensics harness, or create playbook-owned review, delivery, approval, or terminal authority.
