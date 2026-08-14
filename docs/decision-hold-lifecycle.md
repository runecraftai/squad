# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/sq-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved commander decisions.
The command runs sq-tasks in the active `SQUAD_BASE`, so the existing backlog remains the only durable work database and an XO-owned decision stays in the XO base.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `commander` backlog item when absent and invokes `sq-tasks hold <id> --reason <reason> --kind commander` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against sq-tasks before recording completion.
For an open keyed status decision, it appends a `commander-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/sq-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the commander has answered it.

Recon teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit commander-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through sq-tasks, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Structured read surfaces

`bin/sq-unit-snapshot.sh` parses canonical sq-tasks `(hold: ...)` and `(hold-kind: commander)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked commander hold as actionable.
Its XO-base summary classifies an actionable commander hold as `commander_decision` and preserves blocked commander holds as queued work in the owning base.

`bin/sq-sitrep-snapshot.sh` projects actionable commander holds into `decisions_open` and leaves blocked commander holds in ordinary queued gates.
It excludes completed kind `commander` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-base projection verification date: 2026-07-22.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Sitrep snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers sq-tasks' quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/sq-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced recon teardown always requires durable inventory verification
ok - commander holds are idempotent, distinct, teardown-safe, Sitrep-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and XO-home commander holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/sq-unit-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable commander-held transfer closes the duplicate live status decision
ok - snapshot parses sq-tasks rows and respects operational overrides

$ bash tests/sq-sitrep-snapshot.test.sh
ok - a completed recon with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Commander's Call
ok - mixed XO roles, partial state, and commander readiness project independently
ok - main and XO commander actionability use the same blocker readiness

$ bash tests/sq-brief.test.sh
ok - sq-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/sq-teardown.test.sh
all teardown safety cases passed

$ bin/sq-lint.sh
sq-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
