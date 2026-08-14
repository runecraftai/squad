# Changelog

## 0.1.0 (2026-08-14)

### Features

* **fob:** build vendored fob from source instead of downloading a pinned release ([#26](https://github.com/runecraftai/squad/issues/26)) ([371ae46](https://github.com/runecraftai/squad/commit/371ae46205224c7358edca73084053be99c7812a))

### Bug Fixes

* **fob:** suppress built-in updater for non-semver builds ([#27](https://github.com/runecraftai/squad/issues/27)) ([aa87f23](https://github.com/runecraftai/squad/commit/aa87f23fe2be4cbb01e0c939932bc7d13b2df286))
* root .gitignore anchored (/config/ etc.) — generic config/ rule swallowed packages/*/internal/config (16 files never committed); restored fob + no-mistakes internal/config ([507ef99](https://github.com/runecraftai/squad/commit/507ef9984f86b17f396c56ba28da81ebf565e00a))

