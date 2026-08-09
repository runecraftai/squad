# Parked ideas — pi-goal-list-loop-audit

Not scheduled; captured so they survive session compaction. Add freely; promote to a goal when wanted.

## Drafter model setting (noted 2026-07-28, regression-scan contract item 6)

A dedicated **drafter model** — like `auditorModel` but for the drafting/planning path (goal interviews, draft proposal quality, task-list decomposition). Rationale: keep the session model as the cheap default worker, but get better-quality plans/contracts by routing the drafting turns to a stronger model. Would be set in `/glla` (settings menu + `key=value` headless, alongside auditorModel). Open design question: pi extensions can't easily swap the model for selected turns mid-session — needs investigation of what pi's API allows (per-turn model override vs. a drafting subagent with a fixed model, which `subagentModelOverrides` already half-covers).

## Also parked

- Naming-enforcement prompt (rig naming discipline in the continuation prompt — currently only in AGENTS.md)
- `session_start` auto-activate unit test (behavioral harness covers restore-gate branches; the auto-activate path itself is unpinned)
- Negative-grep regression checks scoped to `extensions/` only (convention, not enforced)
- Sub-goal tree — HOLD for v0.29+ (needs a real design pass, not a patch)

- **Auto-resume at `pauseResumeAt`** (parked 2026-07-29, from the v0.28.22
  wait-pause work): a wait-pause declares when it lifts (quota retry, the
  60s flake resume already self-schedule). Extend to AGENT-declared waits
  (e.g. dracon-utilities' janitor "re-check after 06:40 UTC" time-gate):
  a timer that fires /goal resume at resumeAt. Deliberate exception to the
  v0.28.21 "session loads never auto-start" rule — the resume time is
  declared at pause time, not inferred at load. Needs: timer wiring,
  ledger entry, guard against resumeAt-in-the-past storms.
