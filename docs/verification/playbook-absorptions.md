# Absorbed playbook names

This maintainer-verification record proves that five upstream playbook names remain documentation aliases only and are not selectable execution-playbook identities.

## Disposition

- `session-pickup` points to [`stuck-operator-recovery`](../../.agents/skills/stuck-operator-recovery/SKILL.md), [`session-handoff`](../../.agents/skills/session-handoff/SKILL.md), and the recovery contract in [`AGENTS.md`](../../AGENTS.md).
- `pause-safely` points to the brief contract in [`bin/sq-brief.sh`](../../bin/sq-brief.sh) and [`session-handoff`](../../.agents/skills/session-handoff/SKILL.md).
- `babysit` points to the PR lifecycle in [`AGENTS.md`](../../AGENTS.md), the delivery validation owned by drill, and merge monitoring owned by [`bin/sq-pr-check.sh`](../../bin/sq-pr-check.sh).
- `worktree-cleanup` points to [`bin/sq-teardown.sh`](../../bin/sq-teardown.sh), which retains landed-work and discard-authority checks.
- `authoring-a-skill` points to [`skill-creator`](../../.agents/skills/skill-creator/SKILL.md) for authoring and [`skill-verification`](../../.agents/skills/skill-verification/SKILL.md) for promotion validation.

These references do not add an alias, state, cleanup heuristic, review layer, or authority.

## Negative proof

On 2026-09-19, the focused `sq-brief` test exercised `--playbook <name>@1` for every absorbed name.

```text
sq-brief.sh: absorbed playbook names are refused and leave no selectable brief
```

The test is [`test_absorbed_playbook_names_are_not_selectable`](../../tests/sq-brief.test.sh), and the registry contains `bug-fix@1`, `feature@1`, `investigation@1`, `prototype@1`, and `refactoring@1` under `.agents/skills/execution-playbooks/references/`.

The focused test command is:

```sh
bash tests/sq-brief.test.sh
```

The registry inventory command is:

```sh
find .agents/skills/execution-playbooks -maxdepth 2 -type f -print | sort
```

Its expected output contains `SKILL.md` and `references/bug-fix-v1.md`, `references/feature-v1.md`, `references/investigation-v1.md`, `references/prototype-v1.md`, and `references/refactoring-v1.md`.
