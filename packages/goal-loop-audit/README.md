# @runecraft/goal-loop-audit

Part of [Runecraft Companion](../../README.md), the multi-agent harness for the [Pi coding agent](https://pi.dev).

Inside the harness, `@runecraft/goal-loop-audit` provides the goal loop: durable goals driven to verified completion by an isolated auditor in a fresh session, plus list and metric-driven loop modes (`/goal`, `/list`, `/loop`). The harness builds its resilience layer (stall detection, backoff, escalation) on the battle-tested mechanisms of this fork.

## Install

Installed automatically as part of `@runecraft/companion`. Standalone:

    pi install npm:@runecraft/goal-loop-audit

## Docs

- Full guide, quickstart & agent matrix: [root README](../../README.md)
- Mental model / when to use this vs the other tools: [docs/architecture.md](../../docs/architecture.md)

## Relationship to upstream

Fork of `pi-goal-list-loop-audit` (DraconDev, MIT), pinned at 0.28.34 (SHA `21b6bb0abdf5c21c88c976231f312465c3900128`). Notable divergence: renamed to the `@runecraft/*` identity; otherwise behavior-compatible with the upstream test suite.

## Subagents

any subagent provider — e.g. `@tintinweb/pi-subagents` — can drive the loop's
auditor and reviewers; the package is provider-agnostic. Overlaps — pick one:
the goal loop owns durable goals and loops, other tools own their own
surfaces.

We ran both and removed pi-tasks. We ran both `goal-loop-audit` and `pi-tasks` side by side for a
period and removed `pi-tasks` — the loop covers its contract with an honest
metric and an isolated auditor.

Notifications: the loop auto-detects `notify-send`/`osascript`; `notify=off` silences; a custom `notifyCmd` overrides.
