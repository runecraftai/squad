# Execution playbook: `design-delivery@1`

## Accepted brief form

This contract accepts `strike`.
It also accepts `recon` when the deliverable is design knowledge only and no product change is authorized; the sequence then stops at the artifacts, and any implementation is a separate, separately authorized strike.
The registry entry shipped with this version is `strike`-scoped, so a recon brief cites this contract by path instead of selecting it at scaffold.
The `kind` remains the free-form `sq-tasks` dimension; this contract does not reclassify or close that field.

## Required sequence

Run the phases in order, and leave each phase's artifact under `data/<id>/artifacts/` before starting the next.

1. Audit the existing surface and tokens, following `interface-audit`: inventory what ships, what is reused, which tokens are really in use, and where design and code diverge.
   Artifact: `01-audit.md`.
2. Define or evolve the token and component layer: state which tokens and components the new work uses, and which existing ones it changes or retires.
   Artifact: `02-token-layer.md`.
3. Specify components: each component's anatomy, states, sizes, token binding, and the code counterpart that implements it.
   Artifact: `03-components.md`.
4. Design the flow and the screens with the full state matrix: every screen with its loading, empty, error, disabled, focus, long-content, and narrow-width states.
   Artifact: `04-screens.md`, plus the design file path whenever the work uses one.
5. Run visual, accessibility, and parity QA over what phase 4 produced.
   Artifact: `05-qa.md`.
6. Produce the implementation contract with verifiable acceptance criteria, each naming the evidence that proves it.
   Artifact: `06-implementation-contract.md`.

## Required evidence

- Every phase names the artifact it leaves under `data/<id>/artifacts/`; a missing artifact means the phase did not run.
- Every design decision cites the reference it came from: an audit finding, a token path, a frame or page name, or a code file.
- QA records the exact commands it reexecuted and their result, so a later run repeats them unchanged.
- A state matrix names each state rather than asserting that states were considered.
- The implementation contract states its acceptance criteria as verifiable statements, not as intentions.

## Exit predicate

A completion artifact whose title heading contains `checklist` - for example `# design-delivery@1 checklist` - states the definition of done, and every applicable item in it is satisfied.
No delivery-ready claim is made without that artifact.

## Capability boundary

Design QA runs on tooling that is installed and exercised, never on tooling that is assumed.

- `figcraft-cli render` for the design file, following `figcraft-operations`.
- `design-review` and `accessibility-compliance` for interface and accessibility review.
- `visual-parity@1` for design-versus-implementation comparison.

Nothing here may invent Figma, a pixel-diff harness, or a research capability that is not installed.
Record an unavailable capability as a finding and stop rather than weakening the check to fit the tooling.

## Anti-patterns

Do not ship a screen without its state matrix.
Do not write a component spec without its code counterpart.
Do not call a handoff ready without acceptance criteria.
Do not declare `READY_FOR_DEVELOPMENT` while any applicable definition-of-done item is unmet.
Do not invent research, personas, or usability results.
Do not create playbook-owned review, delivery, approval, or terminal authority.

## Authority

This playbook owns no delivery, merge, or review authority: delivery mode, review, and merge stay with the existing lifecycle.
