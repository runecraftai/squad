# Execution playbook: `eval@1`

## Accepted brief form

This contract accepts `recon` only because an evaluation produces evidence and a recommendation, not a code-delivery or promotion authority.

## Required sequence

1. Define the baseline, candidate variant, cases, metric, rubric, and decision threshold before observing candidate results.
2. Sanitize candidate-visible environments and paths, use neutral directory names, and remove evaluation cues from prompts and other candidate-visible inputs.
3. Use blinded cases or a blinded judge when applicable, and prevent candidates from eliciting the evaluation chain, hidden rubric, peer outputs, or judge instructions.
4. Capture each candidate result, metric calculation, blind-integrity check, and synthesis with enough identity to reproduce the experiment.
5. Record a promote-or-reject recommendation with cited evidence, while leaving promotion, review, tests, fixes, delivery, and production authority to `skill-verification` and the existing delivery owners.

## Required evidence

- Baseline and variant identity, case set, metric, rubric, and decision rule.
- Sanitized candidate-visible paths and neutral directory names, with no evaluation cue in the candidate-visible prompt or environment.
- Blinded cases or judge when applicable, plus a chain-elicitation prevention check and any compromise record.
- Per-candidate outputs, metric results, synthesis, and a recommendation to promote or reject.
- An explicit statement that the evaluated change does not enter production through the evaluation itself.

## Exit predicate

The experiment is reproducible, its blind protocol is intact or its compromise is recorded as a stop, and the evidence supports a recommendation without granting the evaluation promotion authority.

## Stop conditions

Stop when the baseline or rubric is ambiguous, the blind is compromised, candidate-visible paths reveal evaluation cues, chain elicitation succeeds, results are not comparable, or a product or promotion decision is required.

## Ownership and anti-patterns

`skill-verification` owns observation and promotion validation, while this contract owns only the experiment method and evidence boundary.
Do not evaluate a concrete skill without authorization, let the evaluated change promote itself, expose hidden evaluation cues, create a second verifier, or create playbook-owned review, delivery, approval, or terminal authority.
