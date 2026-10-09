# Execution playbook: `plan-execute@1`

## Accepted brief form

This contract accepts `strike` only, and it applies when the resolved worker lane is an execution-class model: a lower-context lane that carries out a plan instead of designing one.
The brief must carry a complete `## Execution plan` section, materialized from the planning artifact - the TLC `data/<plan>/tasks/T0X.md` contract when one exists - and `bin/sq-plan-validate.sh` structurally validates it before dispatch.
The planner owns the design; the executing worker receives the plan, not the sources it was derived from.

## Required sequence

1. Accept a brief whose `## Execution plan` section is complete. The section must carry these five labels, each written as a label line followed by its list entries: `Files to touch` (at least one path-like entry, i.e. real file paths), `Ordered steps` (steps numbered, e.g. `1.`), `Acceptance criteria`, `Verification commands` (a command to run), and `Out of scope` (an explicit out-of-scope statement).
2. Execute the plan as written; do not redesign, re-scope, or re-plan the change.
3. Follow `tlc-implement` for the implementation method and write the checklist under `data/<id>/artifacts/`.
4. Stop with `blocked:` when the plan is incomplete, internally contradictory, or contradicted by the code, naming the exact gap rather than filling it by inference.
5. Report acceptance evidence and the verification command result; leave review, fixes, delivery, and merge to the existing owners.

## Required evidence

- The brief's materialized `## Execution plan` section, with every required field present and non-empty.
- A checklist under `data/<id>/artifacts/` recording the plan fields as realized: files touched as planned, steps executed, acceptance met, and the verification command run.
- A `blocked:` report naming the missing or contradictory plan element when execution cannot proceed safely.

## Exit predicate

Every planned file and step is realized or explicitly reported, acceptance criteria are met, and the planned verification command has been run with its result recorded.

## Stop conditions

Stop when the plan is incomplete or internally contradictory, when a step contradicts the current code, when an unplanned design decision would be required, or when the change would materially exceed the materialized plan.

## Ownership and anti-patterns

The planner (with the commander) owns design, and `AGENTS.md` section 7 plus `execution-playbooks` own selection; this contract only carries the materialized plan into execution.
Do not redesign the change, silently widen scope, edit or defer the plan instead of executing it, or create playbook-owned review, delivery, approval, or terminal authority.
