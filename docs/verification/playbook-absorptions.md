# Absorbed playbook names

This maintainer-verification record proves that five upstream playbook names remain documentation aliases only and are not selectable execution-playbook identities.

## Disposition

- `session-pickup` points to [`stuck-operator-recovery`](../../.agents/skills/stuck-operator-recovery/SKILL.md), [`session-handoff`](../../.agents/skills/session-handoff/SKILL.md), and the recovery contract in [`AGENTS.md`](../../AGENTS.md).
- `pause-safely` points to the brief contract in [`bin/sq-brief.sh`](../../bin/sq-brief.sh) and [`session-handoff`](../../.agents/skills/session-handoff/SKILL.md).
- `babysit` points to the PR lifecycle in [`AGENTS.md`](../../AGENTS.md), the delivery validation owned by drill, and merge monitoring owned by [`bin/sq-pr-check.sh`](../../bin/sq-pr-check.sh).
- `worktree-cleanup` points to [`bin/sq-teardown.sh`](../../bin/sq-teardown.sh), which retains landed-work and discard-authority checks.
- `authoring-a-skill` points to [`skill-forge`](../../.agents/skills/skill-forge/SKILL.md) for authoring and [`skill-verification`](../../.agents/skills/skill-verification/SKILL.md) for promotion validation.

These references do not add an alias, state, cleanup heuristic, review layer, or authority.

## Negative proof

On 2026-09-19, the focused `sq-brief` test exercised `--playbook <name>@1` for every absorbed name.

```text
sq-brief.sh: absorbed playbook names are refused and leave no selectable brief
```

The test is [`test_absorbed_playbook_names_are_not_selectable`](../../tests/sq-brief.test.sh), and the registry contains wave-1 contracts `bug-fix@1`, `feature@1`, `investigation@1`, `prototype@1`, `refactoring@1` plus wave-2 contracts `perf@1`, `hillclimb@1`, `runtime-forensics@1`, `trace-forensics@1`, and `visual-parity@1` plus planning/evaluation methods `multi-phase-plan@1` and `eval@1` under `.agents/skills/execution-playbooks/references/`.

The focused test command is:

```sh
bash tests/sq-brief.test.sh
```

The registry inventory command is:

```sh
find .agents/skills/execution-playbooks -maxdepth 2 -type f -print | sort
```

Its expected output contains `SKILL.md` and the reference files for all twelve selectable execution playbook contracts.

## Deferred and auxiliary policy

`orchestrate` is rejected because Commander, XO, backlog, and supervision already own programme coordination.

`autopilot-full` and `autopilot-stack` are deferred until a real multi-PR programme demonstrates that commander merge approval is the measured bottleneck and `yolo` cannot cover it.
They cannot auto-merge, bypass drill, or turn standing autonomy into destructive authority.

`autonomous-run` is deferred until a real task requires a verifiable terminal predicate, budget, stop conditions, duplicate prevention, and a cycle the current supervision cannot conduct.

The three auxiliary topologies are not execution playbook identities or dispatch owners.
`arena` competes on one problem and selects one base, `swarm` covers distinct slices, and `interrogate` independently attacks one artifact with deduplication and judgment.
For PR or diff surfaces, `interrogate` points to the read-only Drill surface documented in [`docs/pr-review.md`](../pr-review.md), and separate reviews are limited to requested or knowledge-only review deliverables.

The catalog remains 22 playbooks because these topology names and the four refused or deferred names are not selectable identities.
