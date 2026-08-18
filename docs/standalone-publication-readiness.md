# Standalone publication readiness

Prep state for releasing the standalone-candidate packages so they are usable
without Squad. npm packages publish under the `@runecraft` npm scope; the Go
binaries ship as compiled GitHub Releases. A live publish is commander-gated and
out of scope for this change; this document records the dry-run validation.

## npm candidates

| Package | Version | Dry-run | Docs decoupled | Blockers |
| --- | --- | --- | --- | --- |
| `@runecraft/pr-review` | 0.2.0 | OK (`npm pack --dry-run`) | yes | none |
| `@runecraft/sq-tasks` | 0.1.1 | OK | yes | none |
| `@runecraft/report` | 0.1.1 | OK | yes | none |
| `@runecraft/sq-gh` | 0.1.1 | OK | yes | none |
| `@runecraft/sq-browser` | 0.1.1 | OK | yes | none |
| `@runecraft/sq-quota` | 0.1.1 | OK | yes | none |
| `@runecraft/operation-board` | 0.1.0 | OK (`npm pack --dry-run`) | yes | none |

Six of the seven npm candidates are already published at their current
versions, so `npm publish --dry-run` reports "cannot publish over previously
published versions" (expected and benign); the new
`@runecraft/operation-board` 0.1.0 has no published version yet.
`npm pack --dry-run` validates each tarball cleanly — bin entrypoint
resolving to a shipped file (the bash script itself for the script-only
sq-board; dist + bin for the rest) + README (+ LICENSE where applicable)
present. `pr-review` is a source-only Pi extension package
whose `scripts/verify-package-contents.mjs` enforces a deliberately minimal
files policy that excludes LICENSE; kept as-is.

Manifest audit found all seven candidates correct (names, versions, bin →
dist or shipped file, files whitelist, no `private` flag); no manifest changes
were needed. READMEs
are decoupled from Squad-internal framing while keeping the AXI/TOON output
conventions and the `@runecraft` brand.

## GitHub-Releases candidates

`drill` and `fob` are distributed as compiled per-OS/arch binaries attached to
tagged GitHub releases, not npm. Release wiring lives in the active root
workflows `.github/workflows/release-drill.yml` and
`.github/workflows/release-fob.yml`: release-please creates the tag (drill's
release stays a draft until assets attach), the build matrix compiles and
uploads per-OS/arch archives plus checksums, and drill's finalize publishes the
draft once every asset job succeeds. drill macOS binaries are Developer ID
signed in CI.

## Next step (commander-gated)

The live npm publish is the commander-gated next step. The six already-published
packages each require a version bump (their current versions are already
published), while the new `@runecraft/operation-board` 0.1.0 can publish at its
current version. The real telemetry/Team ID values are required before any live
Go release ships.
