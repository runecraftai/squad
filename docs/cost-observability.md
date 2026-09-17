# Task cost observability

`bin/sq-cost.sh report <task-id>` renders a pull-request-ready usage report.

Pass `--json` to `report`, or to `task <task-id> --json`, for machine consumption.
The JSON contains agent, session, model, token, timestamp, provider-cost, estimate-basis, and subscription fields only.
Markdown output renders token counts as humanized strings (e.g. `2.6 billion`).
Raw integer values are preserved only in the JSON output.

Recorded harness identifiers (`pi`, `pi-signed`, `claude`, `codex`, `opencode`, `grok`, `kimi`, `muse`) are mapped to product labels in the Markdown report.
Unrecognized identifiers fall back to a title-cased form.

The humanized-count and agent-label patterns are based on [LangWatch](https://github.com/langwatch/langwatch) (Apache-2.0 License).

Pi sessions are attributable only when the recorded harness is `pi` or `pi-signed` and the session header `cwd` exactly equals one of the execution workspaces recorded in the task's `.exec` sidecar.
The sidecar retains each distinct workspace assigned across retries.
Squad's Pi launch extension writes a `squad-task-attribution` custom session entry whose `taskId` must equal the reported task ID exactly.
Identity-bound sessions are used across all attempts, including sessions before the current attempt window.
For legacy sessions without any task-attribution entry, the session header timestamp must fall within the execution attempt window (`exec_started_at` through `exec_last_activity`); a session carrying another task's identity never uses this fallback.
When no execution workspace is recorded, the meta-file `worktree` is used as a fallback.
When the execution window is missing or invalid (non-numeric timestamps, or end before start), attribution is refused unless exact task-identity sessions are available.
This rule excludes the primary session, other tasks, and sessions from another base without widening a pooled workspace's time range.
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
