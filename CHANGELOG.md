# Squad distro change history

This is a curated history of user-impacting changes to the Squad distro, maintained by contributors as changes land.
It is not an exhaustive repository log and does not represent a root package version or release; independently released packages keep their own generated changelogs and release histories.

## Unreleased

- Make the execution-playbook choice an explicit intake decision: `bin/sq-brief.sh` now refuses a strike or recon scaffold that passes neither `--playbook <id>@<version>` nor a one-line `--no-playbook` reason, records that decision in the brief, and still refuses both flags together, an empty reason, or an XO charter carrying `--no-playbook`.
- Add a versioned `react@1` execution playbook so a selected React brief carries the commander's FSD layering, kebab-case and named-function component convention, component-responsibility boundary, and TanStack Router/Query standard, plus a proposed oxlint rule set for deliberation, with structural completion evidence enforced by `bin/sq-playbook-validate.sh`.
- Add a `knowledge-pass` skill so a PR handoff becomes a code-grounded five-section pass (problem, rules, flow, decisions, verification) plus a one-question-at-a-time understanding check, shipped as an internal skill with a standalone public copy.
- Fix the per-task PR cost report to include every Drill pipeline invocation, attribute usage by provider-qualified model, render money to cents labeled provider-recorded versus estimate, and never present OpenCode Go flat-rate subscription usage as spend.
- Add a `--grimoire-output` mode to the skills registry generator that emits a schema-compliant registry for the Grimoire skills MCP from public `skills/` only, plus an optional `--grimoire-payload-dir` payload and a manual GitHub Pages workflow, leaving the legacy `skills-registry.json` unchanged.
- Fix the skills registry publishing an empty description for most entries whose `SKILL.md` declares it as a YAML block scalar; folded and literal block scalars are now read in full while a genuinely absent description still publishes empty.
- Fix the always-on sentry re-escalating a declared `paused:` (or commander-held) operator as a possible wedge whenever its pane stayed busy, or silently missing its first bounded recheck while a foreground long poll kept changing the pane; the declared pause now keeps the bounded long-pause recheck cadence on later polls.
- Add away-mode supervision for a TUIOS-hosted Pi primary, using a guarded detached daemon session and a durable Pi-native follow-up handoff that falls back to typing only into a composer it has read as empty.
- Fix operator sessions aborting on every Pi context compaction now that the compaction-resilience extension persists its state through the supported extension API.
- Initial history scope: future user-impacting distro changes will be recorded here. Earlier history is intentionally not reconstructed.
