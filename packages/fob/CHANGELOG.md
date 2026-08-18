# Changelog

## [0.1.2](https://github.com/runecraftai/squad/compare/fob-v0.1.1...fob-v0.1.2) (2026-08-18)


### Features

* **release:** standalone publication prep for npm and Go binary packages ([#68](https://github.com/runecraftai/squad/issues/68)) ([0288fec](https://github.com/runecraftai/squad/commit/0288fec3ba69b4ea82f330551815fb51c2a67ae0))

## [0.1.1](https://github.com/runecraftai/squad/compare/fob-v0.1.0...fob-v0.1.1) (2026-08-14)


### Features

* **fob:** build vendored fob from source instead of downloading a pinned release ([#26](https://github.com/runecraftai/squad/issues/26)) ([371ae46](https://github.com/runecraftai/squad/commit/371ae46205224c7358edca73084053be99c7812a))
* **packages:** publish npm packages under the [@runecraft](https://github.com/runecraft) scope ([#49](https://github.com/runecraftai/squad/issues/49)) ([ed8a36c](https://github.com/runecraftai/squad/commit/ed8a36cf4fdcf38402ab11ebbcdf6c3e3437128e))
* **release:** wire per-package release-please with npm publish and changelogs ([#39](https://github.com/runecraftai/squad/issues/39)) ([58232bc](https://github.com/runecraftai/squad/commit/58232bca0d6eb5c4cd3ab44fe0de95be393c7464))


### Bug Fixes

* **fob:** suppress built-in updater for non-semver builds ([#27](https://github.com/runecraftai/squad/issues/27)) ([aa87f23](https://github.com/runecraftai/squad/commit/aa87f23fe2be4cbb01e0c939932bc7d13b2df286))
* root .gitignore anchored (/config/ etc.) — generic config/ rule swallowed packages/*/internal/config (16 files never committed); restored fob + no-mistakes internal/config ([507ef99](https://github.com/runecraftai/squad/commit/507ef9984f86b17f396c56ba28da81ebf565e00a))

## 0.1.0 (2026-08-14)

### Features

* **fob:** build fob from source at install time, reporting an accurate version from the source tree ([#26](https://github.com/runecraftai/squad/issues/26)) ([371ae46](https://github.com/runecraftai/squad/commit/371ae46205224c7358edca73084053be99c7812a))

### Bug Fixes

* **fob:** suppress built-in updater for non-semver builds ([#27](https://github.com/runecraftai/squad/issues/27)) ([aa87f23](https://github.com/runecraftai/squad/commit/aa87f23fe2be4cbb01e0c939932bc7d13b2df286))
* root .gitignore anchored (/config/ etc.) — generic config/ rule swallowed packages/*/internal/config (16 files never committed); restored fob + no-mistakes internal/config ([507ef99](https://github.com/runecraftai/squad/commit/507ef9984f86b17f396c56ba28da81ebf565e00a))
