# Task cost observability

`bin/sq-cost.sh report <task-id>` renders a pull-request-ready usage report.

Pass `--json` to `report`, or to `task <task-id> --json`, for machine consumption.
The JSON contains agent, session, model, token, timestamp, provider-cost, estimate-basis, and subscription fields only.

Pi sessions are attributable only when the task metadata records a window and a `pi` or `pi-signed` harness, and the session header `cwd` exactly equals the recorded task worktree.
This exact rule excludes the primary session, other tasks, and sessions from another base.
Retried attempts and validation sessions are included when they use that same recorded worktree.
When no attributable session exists, the report says why instead of fabricating zero usage.

Provider-recorded costs are preferred.
List-price calculations are labeled estimates.
OpenCode Go usage is labeled flat-rate subscription usage and is not presented as token spend.

`sq-cost.sh publish <task-id> <pr-url>` publishes one marked comment through `sq-gh`.
The command updates that comment on later runs rather than creating duplicates.
`sq-pr-check.sh` calls this hook after recording the canonical PR and arming its monitor because the hook survives generated PR bodies.
Client-visible projects identified in `data/projects.md` are guarded from publication in code.
A client-visible registry line may opt in explicitly with `+cost-report` when its PR policy permits the report.

The report never reads or publishes prompt, response, tool, or secret content.
The focused executable coverage is in `tests/sq-cost.test.sh`.
