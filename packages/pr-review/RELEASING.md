# Release operations

`@runecraft/pr-review` ships from the Squad monorepo (runecraftai/squad), not from a standalone `pi-pr-review` repository.
Releases are cut by the monorepo release-please pipeline, which is the single owner of release mechanics: the repo-root `.github/workflows/release.yml` runs one release stream per package, driven by `packages/pr-review/release-please-config.json` and `packages/pr-review/.release-please-manifest.json`, and writes `packages/pr-review/CHANGELOG.md`.
Merging the bot's release PR creates the GitHub release and tag (bare `v<version>` because `include-component-in-tag` is `false`) and publishes the package to npm with the `NPM_TOKEN` repository secret.
The `NPM_TOKEN` secret was still missing from the repository as of 2026-08-14, so no publish has happened yet; the first release requires the commander's approval and the secret.
GitHub tags, GitHub releases, workflow artifacts, and npm versions are immutable release records; never move, reuse, or replace them.

The runbook that previously lived in this file described the upstream `10ego/pi-pr-review` pipeline (nerv-ops App, npm OIDC trusted publisher, `NPM_TRUSTED_PUBLISHING_READY`/`RELEASE_AUTOMATION_ENABLED` variables, GitHub environments).
That pipeline belongs to the upstream repository and does not apply here; do not recreate it in this repository.
