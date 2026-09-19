# Execution playbook: `investigation@1`

## Accepted brief form

This contract accepts `recon` only.

## Required sequence

1. State the investigation question and authorized scope before gathering evidence.
2. Load `diagnostic-reasoning` for bug-adjacent investigation and preserve its causal boundary without restating that skill.
3. Record observed facts separately from inferences and attach a source or artifact to every claim.
4. Record unavailable sources, uncertainty, and the practical implication of each material gap.
5. End with a self-contained report and pass `decision-hold-lifecycle` before declaring the investigation complete.

Squad has no routed `how` or `why` skill mechanism.
This contract therefore inlines the upstream evidence discipline rather than claiming those routes, and it remains narrower than upstream where those routes would provide additional depth.

## Required evidence

- Investigation question, authorized scope, and observed end-user or operator behavior.
- A facts section distinct from an inferences section.
- Source or artifact citations for claims, with unreachable sources recorded as explicit gaps.
- Uncertainty inventory and practical implication.
- Self-contained report with the `decision-hold-lifecycle` completion result.

## Exit predicate

The recon report is autonomous, every material claim is sourced or explicitly uncertain, and the decision-hold completion gate passes.

## Stop conditions

Stop when scope exceeds authorization, a commander decision is required, or evidence is insufficient and the uncertainty could change the conclusion.

## Anti-patterns

Do not turn investigation into an implementation task.
Do not merge facts and inferences into one narrative.
Do not treat an uncited claim as established evidence.
Do not claim `how` or `why` routing that Squad cannot perform.
Do not add a second reviewer, verifier, state machine, backlog field, or delivery authority.
