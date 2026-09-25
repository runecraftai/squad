# Changelog

## [0.1.7](https://github.com/runecraftai/squad/compare/drill-v0.1.6...drill-v0.1.7) (2026-09-25)


### Features

* **daemon:** include run id in run-start telemetry event ([#219](https://github.com/runecraftai/squad/issues/219)) ([a3b5f90](https://github.com/runecraftai/squad/commit/a3b5f908e59012a8850b85a2b428b240a187ba6b))
* **drill:** add --specialized-review opt-in for observe-mode shadow batch ([#216](https://github.com/runecraftai/squad/issues/216)) ([47aded4](https://github.com/runecraftai/squad/commit/47aded4a97d90b381d10e0ca988136c6a634b30b))
* **drill:** add standalone read-only review ([b00fe8b](https://github.com/runecraftai/squad/commit/b00fe8bb2b58161b5bc9d63a16a709ed69795c38))
* **drill:** standalone read-only review surface for local diffs and PRs ([d3896a2](https://github.com/runecraftai/squad/commit/d3896a2b7cd56cfe66ad77f0c5274214cfe2bd1c))
* **pipeline:** add session-free consolidator for specialized review findings ([#214](https://github.com/runecraftai/squad/issues/214)) ([081a1be](https://github.com/runecraftai/squad/commit/081a1be563bff6f25cfe73073bff21271bf9671f))
* **pipeline:** implement parallel specialist review lenses with isolated worktree enforcement ([#213](https://github.com/runecraftai/squad/issues/213)) ([ff8d284](https://github.com/runecraftai/squad/commit/ff8d28404d541d7d1c0399847ff5411c3919e812))
* **pipeline:** specialized review R4 — operational telemetry, TUI/AXI visibility, safe retry, and attribution ([#215](https://github.com/runecraftai/squad/issues/215)) ([90a49ee](https://github.com/runecraftai/squad/commit/90a49ee06714ee526daa6a40355b00cafb543bf7))
* **review:** specialized review topology config and immutable round snapshot ([#211](https://github.com/runecraftai/squad/issues/211)) ([2194982](https://github.com/runecraftai/squad/commit/219498277ae70f6514c73de3999876a95cd055d8))

## [0.1.6](https://github.com/runecraftai/squad/compare/drill-v0.1.5...drill-v0.1.6) (2026-09-23)


### Features

* **skills:** adopt skills catalog with new skills, lockfile integrity, and CDN distribution ([#197](https://github.com/runecraftai/squad/issues/197)) ([e099ea0](https://github.com/runecraftai/squad/commit/e099ea05d578deaa3be1be7bafd81474cc140856))


### Bug Fixes

* **drill:** persist recovery counter and make guard placement symmetric ([#177](https://github.com/runecraftai/squad/issues/177)) ([91be79e](https://github.com/runecraftai/squad/commit/91be79e9eae8b15266ca24792d049762b6ac2243))
* **pipeline:** enforce fix-round limit to prevent review/fix loop non-convergence ([#173](https://github.com/runecraftai/squad/issues/173)) ([2299770](https://github.com/runecraftai/squad/commit/22997709918229e2f4813701da74b28f9e89dbf7))

## [0.1.5](https://github.com/runecraftai/squad/compare/drill-v0.1.4...drill-v0.1.5) (2026-09-08)


### Features

* **drill:** add skill verification gate ([#130](https://github.com/runecraftai/squad/issues/130)) ([09bcc67](https://github.com/runecraftai/squad/commit/09bcc67a0b0e9761c1ef35226a442de2f2298b1e))

## [0.1.4](https://github.com/runecraftai/squad/compare/drill-v0.1.3...drill-v0.1.4) (2026-09-04)


### Bug Fixes

* **drill:** resolve multiple JSON code fences instead of failing ([9750679](https://github.com/runecraftai/squad/commit/97506792b5e0bb4aa9f4a2c1f14b18557e6578a6))
* **drill:** resolve multiple JSON code fences instead of failing ([68f5a3c](https://github.com/runecraftai/squad/commit/68f5a3c1f509f780d1db38a73bfe2b7dc75381a2))

## [0.1.3](https://github.com/runecraftai/squad/compare/drill-v0.1.2...drill-v0.1.3) (2026-08-24)


### Bug Fixes

* emit offline rows for tasks with missing tmux windows ([07cee8b](https://github.com/runecraftai/squad/commit/07cee8b39a9e8c8f47c2759705f6b1ae9af6659a))
* **sq-report:** restore kind-specific header titles ([#92](https://github.com/runecraftai/squad/issues/92)) ([9b020ff](https://github.com/runecraftai/squad/commit/9b020ff970541d12064317647fc9c4e744ba5fdd))

## [0.1.2](https://github.com/runecraftai/squad/compare/drill-v0.1.1...drill-v0.1.2) (2026-08-18)


### Features

* **release:** standalone publication prep for npm and Go binary packages ([#68](https://github.com/runecraftai/squad/issues/68)) ([0288fec](https://github.com/runecraftai/squad/commit/0288fec3ba69b4ea82f330551815fb51c2a67ae0))


### Bug Fixes

* **drill:** replace stale NO MISTAKES banners with DRILL ASCII art ([#61](https://github.com/runecraftai/squad/issues/61)) ([a88ab08](https://github.com/runecraftai/squad/commit/a88ab08a2f472ccec5ba540c10a9c7ae3975376e))

## [0.1.1](https://github.com/runecraftai/squad/compare/drill-v0.1.0...drill-v0.1.1) (2026-08-14)


### Features

* **drill:** rename no-mistakes validation pipeline to drill ([#8](https://github.com/runecraftai/squad/issues/8)) ([7a4b094](https://github.com/runecraftai/squad/commit/7a4b094415ae6b4030e38161d6d39f0a9bca306e))
* **drill:** session reuse for opencode and pi fixer loops ([#34](https://github.com/runecraftai/squad/issues/34)) ([1eb6619](https://github.com/runecraftai/squad/commit/1eb6619ca9d579d5f133304b8a916561ba549a69))
* **packages:** publish npm packages under the [@runecraft](https://github.com/runecraft) scope ([#49](https://github.com/runecraftai/squad/issues/49)) ([ed8a36c](https://github.com/runecraftai/squad/commit/ed8a36cf4fdcf38402ab11ebbcdf6c3e3437128e))
* **release:** wire per-package release-please with npm publish and changelogs ([#39](https://github.com/runecraftai/squad/issues/39)) ([58232bc](https://github.com/runecraftai/squad/commit/58232bca0d6eb5c4cd3ab44fe0de95be393c7464))


### Bug Fixes

* **drill:** correct buildinfo ldflags, drop legacy demo media, add flow diagram ([#15](https://github.com/runecraftai/squad/issues/15)) ([d23e1f4](https://github.com/runecraftai/squad/commit/d23e1f4d6df929b546268b911b8189ea93f5bf28))
* **drill:** tolerate prose and unclosed fences in pi agent output parsing ([#9](https://github.com/runecraftai/squad/issues/9)) ([14f3a2b](https://github.com/runecraftai/squad/commit/14f3a2bb6400680e2b0af5124952c12781b46da9))
* **drill:** treat prose-only fix rounds as summaries instead of losing fixes ([#35](https://github.com/runecraftai/squad/issues/35)) ([84182c4](https://github.com/runecraftai/squad/commit/84182c427e3d94e4c4028a225d8441d4eb2787e7))

## 0.1.0 (2026-08-14)

### Features

* **drill:** rename no-mistakes validation pipeline to drill ([#8](https://github.com/runecraftai/squad/issues/8)) ([7a4b094](https://github.com/runecraftai/squad/commit/7a4b094415ae6b4030e38161d6d39f0a9bca306e))
* **drill:** session reuse for opencode and pi fixer loops ([#34](https://github.com/runecraftai/squad/issues/34)) ([1eb6619](https://github.com/runecraftai/squad/commit/1eb6619ca9d579d5f133304b8a916561ba549a69))

### Bug Fixes

* **drill:** correct buildinfo ldflags, drop legacy demo media, add flow diagram ([#15](https://github.com/runecraftai/squad/issues/15)) ([d23e1f4](https://github.com/runecraftai/squad/commit/d23e1f4d6df929b546268b911b8189ea93f5bf28))
* **drill:** tolerate prose and unclosed fences in pi agent output parsing ([#9](https://github.com/runecraftai/squad/issues/9)) ([14f3a2b](https://github.com/runecraftai/squad/commit/14f3a2bb6400680e2b0af5124952c12781b46da9))
* **drill:** treat prose-only fix rounds as summaries instead of losing fixes ([#35](https://github.com/runecraftai/squad/issues/35)) ([84182c4](https://github.com/runecraftai/squad/commit/84182c427e3d94e4c4028a225d8441d4eb2787e7))
