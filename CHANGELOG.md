# Squad distro change history

This is a curated history of user-impacting changes to the Squad distro, maintained by contributors as changes land.
It is not an exhaustive repository log and does not represent a root package version or release; independently released packages keep their own generated changelogs and release histories.

## Unreleased

- Fix the per-task PR cost report to include every Drill pipeline invocation, attribute usage by provider-qualified model, render money to cents labeled provider-recorded versus estimate, and never present OpenCode Go flat-rate subscription usage as spend.
- Add a `--grimoire-output` mode to the skills registry generator that emits a schema-compliant registry for the Grimoire skills MCP from public `skills/` only, plus an optional `--grimoire-payload-dir` payload and a manual GitHub Pages workflow, leaving the legacy `skills-registry.json` unchanged.
- Fix the skills registry publishing an empty description for most entries whose `SKILL.md` declares it as a YAML block scalar; folded and literal block scalars are now read in full while a genuinely absent description still publishes empty.
- Fix the always-on sentry re-escalating a declared `paused:` (or commander-held) operator as a possible wedge whenever its pane stayed busy; the declared pause now keeps the bounded long-pause recheck cadence.
- Add away-mode supervision for a TUIOS-hosted Pi primary, using a guarded detached daemon session and a durable Pi-native follow-up handoff that never types into the terminal.
- Fix operator sessions aborting on every Pi context compaction now that the compaction-resilience extension persists its state through the supported extension API.
- Initial history scope: future user-impacting distro changes will be recorded here. Earlier history is intentionally not reconstructed.
