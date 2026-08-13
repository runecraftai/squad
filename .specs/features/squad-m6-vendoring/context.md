# Squad M6 — Vendoring the AXI Toolchain — Context & Decisions

All commander decisions below are **FINAL** (3 locked rounds, 2026-08-10). They were captured before planning and are treated as locked: no re-research, no re-asking. New conflicts discovered during planning are recorded as open questions (OQ-M6-*) or risks (RISK-M6-*), never silently changed.

## Commander's Locked Decisions (M6)

| # | Decision | Detail |
| --- | --- | --- |
| CD-M6-01 | Destination | Vendor into the runecraftai/squad monorepo, `packages/` workspace, following the M2 pattern |
| CD-M6-02 | FINAL NAMES — no `-axi` anywhere (not directories, not packages, not binaries) | gh-axi → **sq-gh**; chrome-devtools-axi → **sq-browser**; tasks-axi → **sq-tasks** (RENAMES the vendored `packages/tasks-axi`: dir → `packages/sq-tasks`, pkg `sq-tasks-axi` → `sq-tasks`, bin → `sq-tasks`, lib `bin/sq-tasks-axi-lib.sh` → `bin/sq-tasks-lib.sh`; `SQUAD_TASKS_AXI_MIN` env constant is a durable contract and STAYS — it belongs to the roadmap-mention item); lavish-axi → **sq-report**; quota-axi → **sq-quota**. no-mistakes: **KEPT**. fob: **KEPT** (Squad military vocabulary) |
| CD-M6-03 | Rename scope NOW = names only (package, bin, directory) | Internal strings/mentions (help text, TOON output, README, AXI-compliant terminology, env var names) deferred to roadmap-futuro-rebrand-completo-de-menco-31; specs' roadmap sections record that, not the deep rebrand |
| CD-M6-04 | Per-tool specs | 5 tool specs (sq-gh, sq-browser, sq-tasks [rename], sq-quota, sq-report) + 1 umbrella M6 integration spec, all tlc-spec-driven |
| CD-M6-05 | Upstream sync | On-demand only ("quando der na telha"); short sync procedure in the umbrella spec |
| CD-M6-06 | Umbrella coverage | Bootstrap wiring from the workspace (build + local install vs publish), CI additions for the 4 new packages, test strategy (upstream suites green in-workspace), version-floor handling after rename, shipping the unlanded pr-review fix in `packages/pr-review/extensions/pr-review-subagent.ts` |

## Research Facts (2026-08-10, GitHub API/raw, read-only)

| Tool | Upstream repo | Tag/version | Lang | bin (upstream) | engines | deps | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| gh-axi | kunchenguid/gh-axi | gh-axi-v0.1.30 | TS | `gh-axi` → `./dist/bin/gh-axi.js` | node>=20 | @toon-format/toon, axi-sdk-js | pnpm@11.1.1, .airlock/lint.sh, release-please |
| chrome-devtools-axi | kunchenguid/chrome-devtools-axi | chrome-devtools-axi-v0.1.29 | TS | `chrome-devtools-axi` → `dist/bin/chrome-devtools-axi.js` | node>=20 | @modelcontextprotocol/sdk, @toon-format/toon, axi-sdk-js | build = `tsc && chmod +x dist/bin/...js`; 2 bin source files (entry + bridge) |
| lavish-axi | kunchenguid/lavish-axi | lavish-axi-v0.1.48 | JS | `lavish-axi` → `dist/cli.mjs` | node>=22 | @tailwindcss/browser, axi-sdk-js, chokidar, cross-spawn, daisyui, express, open, parse5 | build = `node scripts/build.js`; skills/lavish; THIRD-PARTY-NOTICES.md; repo ≈76 MB (marketing renders) |
| quota-axi | kunchenguid/quota-axi | quota-axi-v0.1.20 | TS | `quota-axi` → `./dist/bin/quota-axi.js` | node>=22.19 | @toon-format/toon, axi-sdk-js | .airlock/lint.sh, release-please |
| tasks-axi (vendored M2) | kunchenguid/tasks-axi (upstream still 0.2.5) | vendored 0.2.5 | TS | `sq-tasks-axi` → `dist/bin/sq-tasks-axi.js` | node>=20 | @toon-format/toon, axi-sdk-js | fork renamed at M2 (AD-006); no vendor.json (M2 predates the M3/M5 provenance pattern) |

Distro state: `git status` shows ONLY `M packages/pr-review/extensions/pr-review-subagent.ts` (the pr-review fix) — no other modifications. `bin/sq-bootstrap.sh` `COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"`; floors `GH_AXI_MIN=0.1.29`, `LAVISH_AXI_MIN=0.1.46` (bootstrap), `SQUAD_QUOTA_AXI_MIN=0.1.17` (sq-quota-axi-lib.sh), `SQUAD_TASKS_AXI_MIN=0.2.4` (sq-tasks-axi-lib.sh). CI installs the fork only (`npm install -g ./packages/tasks-axi` + `tasks-axi` alias); gh-axi/lavish-axi/quota-axi/chrome-devtools-axi are NOT installed in CI (tests stub them).

## Assumptions (delegated planning — made by the planner, NOT commander-confirmed)

| # | Assumption | Notes |
| --- | --- | --- |
| A-M6-01 | "Names only" includes packaged-skill dirs inside forks (`skills/gh-axi` → `skills/sq-gh`, etc.) and their `files[]` entries — they are directory/packaging names; the skill *content prose* defers. lavish's `skills/lavish` has no `-axi` → KEPT (product name, deferred) | Boundary per CD-M6-03 |
| A-M6-02 | release-please `package-name` fields and build-script path literals are names (change now); release-please version manifests are version state (keep values) | Packaging surface |
| A-M6-03 | Distro bin/lib call sites that *execute* the tools are name references (change now); comments/help/prose (e.g., sq-brief.sh instructions, sq-procevent-lib.sh comments, docs/) are mentions (defer) | Boundary per CD-M6-03 |
| A-M6-04 | Protocol/back-end identifiers (`config/backlog-backend=tasks-axi`, procevent source id `lavish`, floor/env constant names) are deferred contracts, not names-to-rename | SQUAD_TASKS_AXI_MIN explicitly kept by commander |
| A-M6-05 | Fork version numbers stay at the vendored upstream version (0.1.30 / 0.1.29 / 0.1.48 / 0.1.20 / 0.2.5); floors are bumped to match so the forks always satisfy them | REQ-M6-04 |
| A-M6-06 | Per-fork upstream test fixes are allowed only for environment/strictness breaks, documented (M5 precedent), never assertion-weakening | REQ-M6-01 AC3 |

## Open Questions (recorded, defaults recommended — commander confirmation at handoff)

| # | Question | Options | Recommendation |
| --- | --- | --- | --- |
| OQ-M6-01 | Legacy command aliases after bin rename: install legacy-name symlinks (`gh-axi`→`sq-gh`, …) alongside new bins in CI + bootstrap? | (a) Yes, aliases for all five renamed tools; (b) new names only, no aliases (except mandatory `tasks-axi` protocol alias) | **(a)** — keeps deferred operator prose (sq-brief "Use gh-axi…") and ecosystem scripts working until the rebrand item; mirrors the M2 `tasks-axi` alias precedent |
| OQ-M6-02 | Bootstrap install mechanics for the 4 new TS/JS tools | (a) `npm install -g ./packages/<pkg>` (prepack builds) — M2 CI pattern; (b) turbo-built bins symlinked into a tools dir (no global state); (c) real npm publish (blocked: OQ-03) | **(a)** — proven pattern, no registry dependency; publish recorded as future org-gated work |
| OQ-M6-03 | Floor policy after rename | (a) bump values to vendored versions + retarget operands to new bins; (b) keep current floor values | **(a)** — floors gate the forks exactly at what we ship |
| OQ-M6-04 | `bin/sq-quota-axi-lib.sh` filename | (a) rename → `bin/sq-quota-lib.sh` (commander explicitly renamed sq-tasks-axi-lib.sh; same rule); (b) keep until rebrand item | **(a)** — consistent with the no-`-axi`-in-names rule; sources (sq-bootstrap.sh, sq-test-run.sh lane) updated in the same sweep |
| OQ-M6-05 | CI job shape for the 4 new packages | (a) one matrix job `axi-tools` (pkg ∈ {sq-gh, sq-browser, sq-quota, sq-report}); (b) one dedicated job per package | **(a)** — 4 identical TS jobs collapse to a matrix; existing `tasks-axi` job renamed `sq-tasks` and kept |
| OQ-M6-06 | Provenance record for the sq-tasks rename | (a) add `vendor.json` during the rename (M3/M5 pattern); (b) skip (record in STATE only) | **(a)** — cheap, closes the M2 gap, one consistent provenance convention |

## Risks

| # | Risk | Severity | Mitigation |
| --- | --- | --- | --- |
| RISK-M6-01 | Root bun tolerating 4 more nested pnpm lockfiles | Medium | T-M2-04 precedent; verify hoisting after adding; exclude from bun resolution if needed |
| RISK-M6-02 | lavish-axi repo size (≈76 MB tracked, marketing renders) | Medium | Tracked-file copy only; measure delta; pruning is a recorded future option, not decided |
| RISK-M6-03 | Engine floors (node>=22 / >=22.19) for sq-report/sq-quota | Low | CI pins node 22; document requirement; bootstrap already checks node |
| RISK-M6-04 | Deferred prose references dead names until rebrand | Low | Legacy aliases (OQ-M6-01 default (a)) |
| RISK-M6-05 | M6 name-guard keep-list drift | Low | Rebrand item must retire guard exclusions when it lands |
| RISK-M6-06 | Pinned versions age between syncs | Low | On-demand sync (CD-M6-05) + floors/compat probes as tripwires |

## Session memory note

- This is largely mechanical work once the rename tables and the umbrella wiring list are frozen (design.md §2/§4/§7) — the four tool forks share one pattern; a fast/cheap model can execute the per-tool tasks with the tables in context.
- The pr-review fix shipping (REQ-M6-06) and the sq-tasks rename (REQ-M6-02) are the two tasks that need care (schema semantics; resolver + alias + lib rename); everything else is copy → rename → green tests.

## OQ-M6 resolutions (commander approval, 2026-08-10)

All six open questions resolved by the commander with the recommended defaults:

| OQ | Resolution |
| --- | --- |
| OQ-M6-01 | (a) — legacy aliases for all five renamed tools, plus the mandatory `tasks-axi` protocol alias |
| OQ-M6-02 | (a) — `npm install -g ./packages/<pkg>` (prepack builds), M2 CI pattern |
| OQ-M6-03 | (a) — floors bumped to vendored versions, operands retargeted to new bins |
| OQ-M6-04 | (a) — `bin/sq-quota-axi-lib.sh` → `bin/sq-quota-lib.sh` in the same sweep |
| OQ-M6-05 | (a) — one `axi-tools` matrix job; `tasks-axi` CI job renamed `sq-tasks` and kept |
| OQ-M6-06 | (a) — `vendor.json` added during the sq-tasks rename |

Execution authorized by the commander ("autorizo") including: building fob/no-mistakes locally from the vendored sources as the interim install until the OQ-03 release channel publishes, and dispatching the M6 implementation through the standard strike pipeline (isolated copy, no-mistakes validation, PR for commander review).

## Post-delivery review (2026-08-13, commander decision)

M6 shipped as planned (2026-08-10, branch `fm/m6-executar-vendoring-da-toolchain-no-mo-3b`). The review below re-verifies every assumption, task, and OQ against the live repo state after the follow-on PRs landed. Historical planning records above stay intact; this section is the current-facts delta.

### Current repo state (verified 2026-08-13)

- `packages/` = `drill fob pr-review sq-browser sq-gh sq-quota sq-report sq-tasks` — all five Squad-named tools vendored, `packages/tasks-axi` gone, `packages/no-mistakes` gone (renamed to `drill`), `packages/goal-loop-audit` gone (cut per commander decision 2026-08-10).
- **0.1.0 baseline reset (PR #16, 2026-08-11):** every workspace package (incl. the five sq-* forks and pr-review) was reset to a clean `0.1.0` version; CHANGELOGs dropped; `.release-please-manifest.json` and sq-report `plugin.json` zeroed. `vendor.json` provenance still records the upstream pinned version (0.1.30 / 0.1.29 / 0.1.48 / 0.1.20 / 0.2.5) — package.json version and provenance version are intentionally different now.
- **Floors reset to 0.1.0:** `GH_AXI_MIN=0.1.0`, `LAVISH_AXI_MIN=0.1.0` (sq-bootstrap.sh), `SQUAD_QUOTA_AXI_MIN=0.1.0` (sq-quota-lib.sh), `SQUAD_TASKS_AXI_MIN=0.1.0` (sq-tasks-lib.sh). The planned bump to vendored versions (OQ-M6-03 (a)) and the "durable 0.2.4" SQUAD_TASKS_AXI_MIN claim are superseded by the PR #16 reset; the sq-tasks `vendor.json` note originally claiming "SQUAD_TASKS_AXI_MIN stays 0.2.4" was corrected in this review to the 0.1.0 baseline fact.
- **no-mistakes renamed to drill (PR #8, 2026-08-10):** `packages/no-mistakes` → `packages/drill`, `.no-mistakes.yaml` → `.drill.yaml`, `bin/sq-nm-run-lib.sh` → `bin/sq-drill-run-lib.sh`, `no-mistakes-required.yml` → `drill-required.yml`; `COMMON_TOOLS="node git gh drill sq-gh sq-browser sq-report sq-quota sq-tasks"`; `DRILL_MIN=1.31.2`. The root `.no-mistakes.yaml` survived the PR #8 rename untouched since M1 with zero consumers (no Go source, script, or workflow reads it; the M6 name guard does not scan root dotfiles) and was removed as an orphan on 2026-08-13 — the root `.drill.yaml` alone is the active config, and the guard/docs do not need the leftover file.
- **pr-review is maintained, not vendored (PR #16):** dropped `vendor.json` and upstream identity fields (repository/homepage/bugs, README upstream section); version 0.1.0; docs/pr-review.md reads "Squad maintains @runecraft/pr-review (0.1.0)". The `pr_review_verify` fix is committed (single Object schema + runtime required-field validation) with its regression test green; the package suite is 250 pass / 2 fail — the two failures are README-content assertions that drifted when the READMEs were beautified (PR #11), unrelated to the schema fix.
- **SQUAD_HOME → SQUAD_BASE (PR #22, 2026-08-13):** env contract renamed with a permanent read shim; this repo's session-start now runs from the new base.
- **fob built from source (PR #26, 2026-08-13):** `bin/sq-install-fob.sh ~/.local/bin` builds the vendored `packages/fob`; the OQ-03 release-channel 404 no longer blocks the local install.
- **Skills scrub (PR #25, 2026-08-13):** packaged skill dirs renamed to the Squad names (`sq-gh/skills/sq-gh`, `sq-browser/skills/sq-browser`, `sq-quota/skills/sq-quota`, `sq-tasks/skills/sq-tasks`; `sq-report/skills/lavish` kept as the product name). `skills/` public dir holds only `debrief`; `.agents/skills/` holds the 19 agent-loaded internal skills.
- **Name guard:** `tests/sq-m6-name-guard.test.sh` exists and passes; its keep-list now retires every packages/ hit (incl. the former sq-browser bridge log-prefix pin) and documents the remaining deferred-prose keep-list (sq-brief.sh "Use gh-axi…", etc.).
- **CI:** `axi-tools` matrix job (sq-gh, sq-browser, sq-quota, sq-report) exists; `tasks-axi` job renamed `sq-tasks`; install steps use `./packages/sq-tasks` and the `tasks-axi` protocol alias only.

### OQ-M6-01..06 re-stated with current facts

| OQ | Planned resolution | Current fact |
| --- | --- | --- |
| OQ-M6-01 | (a) — aliases for all five renamed tools + mandatory `tasks-axi` alias | **Partially landed.** Only the mandatory `tasks-axi` → `sq-tasks` protocol alias exists (CI + resolver fallback). The four optional legacy aliases (`gh-axi`→`sq-gh`, `chrome-devtools-axi`→`sq-browser`, `lavish-axi`→`sq-report`, `quota-axi`→`sq-quota`) were NOT created. Deferred prose that names the old tools (sq-brief.sh, comments) stays in the guard keep-list; the rebrand item must retire it or the prose must be updated. |
| OQ-M6-02 | (a) — `npm install -g ./packages/<pkg>` | **Landed.** install_cmd branches install from the workspace; drill stays on its OQ-03 release placeholder. |
| OQ-M6-03 | (a) — floors bumped to vendored versions | **Superseded by PR #16.** All four floors are 0.1.0 now (the clean-baseline reset), operands are the new bins. |
| OQ-M6-04 | (a) — `bin/sq-quota-axi-lib.sh` → `bin/sq-quota-lib.sh` | **Landed.** `bin/sq-quota-lib.sh` probes `sq-quota`; sources (sq-bootstrap.sh, sq-test-run.sh lane) updated. |
| OQ-M6-05 | (a) — one `axi-tools` matrix job; `tasks-axi` job renamed `sq-tasks` | **Landed.** Matrix job present; sq-tasks job + protocol alias present. |
| OQ-M6-06 | (a) — `vendor.json` during the sq-tasks rename | **Landed.** `packages/sq-tasks/vendor.json` present (upstream tag v0.2.5 provenance). |

### Risks re-scored

- RISK-M6-04 (deferred prose references dead names) — **materialized for the four tools:** no legacy aliases exist, so deferred prose naming `gh-axi`/`chrome-devtools-axi`/`lavish-axi`/`quota-axi` points at names that are not on PATH. Mitigation: the rebrand item (roadmap-futuro-rebrand-completo-de-menco-31) is the owner; until then operators follow the sq-* names. The `tasks-axi` protocol alias is unaffected (mandatory, kept).
- RISK-M6-05 (guard keep-list drift) — partially retired by PR #25; the remaining keep-list is the bin/ and tests/ deferred-prose set documented in the guard file itself.
- RISK-M6-02 (lavish/sq-report repo size) — the marketing renders shipped in the tracked copy; no pruning decision made (recorded future option).
- RISK-M6-01/M6-03/M6-06 — no adverse findings; root bun tolerates the nested pnpm lockfiles, CI pins node 22, on-demand sync procedure stands (design.md §9).
