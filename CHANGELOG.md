# Squad distro change history

This is a curated history of user-impacting changes to the Squad distro, maintained by contributors as changes land.
It is not an exhaustive repository log and does not represent a root package version or release; independently released packages keep their own generated changelogs and release histories.

## Unreleased

- Fix the always-on sentry re-escalating a declared `paused:` (or commander-held) operator as a possible wedge whenever its pane stayed busy; the declared pause now keeps the bounded long-pause recheck cadence.
- Add away-mode supervision for a TUIOS-hosted Pi primary, using a guarded detached daemon session and a durable Pi-native follow-up handoff that never types into the terminal.
- Fix operator sessions aborting on every Pi context compaction now that the compaction-resilience extension persists its state through the supported extension API.
- Initial history scope: future user-impacting distro changes will be recorded here. Earlier history is intentionally not reconstructed.
