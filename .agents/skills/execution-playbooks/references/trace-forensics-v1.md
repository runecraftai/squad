# Execution playbook: `trace-forensics@1`

## Accepted brief form

This contract accepts `recon` only.

## Required sequence

1. State the question and identify one captured artifact by path, format, hash, scenario, and capture context before analysis.
2. Load the captured artifact without silently recapturing a different scenario and transform it into a queryable form.
3. Narrow the cause using evidence in that trace and map the conclusion to a source location.
4. End with a self-contained diagnosis; a fix is outside recon and requires explicit later promotion.

## Required evidence

- Captured artifact path, format, hash, scenario, and capture context.
- Queryable transformation command and artifact identity preserved through analysis.
- Each material conclusion linked to a trace event, query, or named evidence range.
- Source mapping and stop record for unknown format, unavailable symbols, incompatible artifact, unprovable cause, product decision, or exhausted budget.

## Exit predicate

The recon report cites an immutable captured artifact, derives its diagnosis from trace evidence, and resolves the source location without silent recapture.

## Ownership and anti-patterns

`diagnostic-reasoning` owns causal reasoning; this contract owns only captured-artifact identity and trace evidence linkage.
Do not invent a universal trace tool, substitute a different capture, or create playbook-owned review, delivery, approval, or terminal authority.
