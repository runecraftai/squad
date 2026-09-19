# Execution playbook: `bug-fix@1`

## Required sequence

1. Load and follow `diagnostic-reasoning` before changing code.
2. Reproduce the reported failure on the original surface before applying a fix.
3. Use binary-search hypothesis testing to separate competing causes and record the observation that could refute the causal explanation.
4. Use `tlc-implement` during construction, keeping the smallest behavior-focused change and staging commits by coherent step.
5. Add a regression test that fails for the reproduced bug and passes for the fix.
6. Run the relevant suite and keep it green.
7. Re-exercise the original surface after the fix with the original reproduction.

## Required evidence

- Reproduction before fix: command, input, environment or state, observed failure, and timestamp or commit context.
- Causal explanation with refutable evidence: the hypothesis, binary-search observations, and an observation that could refute it.
- Regression test: test path or command, the pre-fix failure, and the post-fix pass.
- Relevant suite: exact command and passing output.
- Original surface re-exercised: the same entry point, inputs, state, and expected post-fix result.

## Exit predicate

The original reproduction passes, the regression test passes, the relevant suite is green, and the original surface is re-exercised with matching entry point, inputs, and state.

## Stop conditions

Stop and report when the failure cannot be reproduced, a product decision is required, or the cause is outside the authorized scope.

## Allowed variations

The binary-search and regression-test tools may vary with the repository, but every variation must preserve the evidence named above and explain its mapping to the original surface.

## Anti-patterns

Do not change code before recording a reproduction.
Do not present a narrative cause without refutable observation.
Do not reuse one generic proof for multiple evidence criteria.
Do not treat a passing suite as proof that the original surface was re-exercised.
Do not add a second reviewer, verifier, state machine, backlog field, or delivery authority.

## Completion handoff

Before sending the implementation to drill or another delivery path, run `bin/sq-playbook-validate.sh <task-id>` and resolve every reported absence or incompatibility.
This validator checks structural evidence only and does not perform review, tests, fixes, push, PR, or merge.
