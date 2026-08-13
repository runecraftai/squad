# Squad M6 — Vendoring the AXI Toolchain — Specification

**Scope:** Large (multi-component: 4 new vendored packages + 1 rename + bootstrap/CI/wiring + pr-review fix + umbrella integration)
**Prereq:** M0–M5 done; org `runecraftai/squad` live (OQ-03 resolved); only expected working-tree change = the unlanded pr-review fix in `packages/pr-review/extensions/pr-review-subagent.ts`
**Language:** English (AD-008)
**Depends on:** `.specs/features/squad-inception/{spec,context,design,tasks}.md` (M2 vendoring pattern, AD-006 fork naming, AD-007 publication paths)

## Problem Statement

The Squad distro requires seven kunchenguid-ecosystem tools at runtime. Three were vendored in M2 (`fob`, `no-mistakes`, `tasks-axi` as `sq-tasks-axi`). Four remain installed from upstream npm (`gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `quota-axi`), which keeps upstream identity in the distro's toolchain and contradicts the M0–M5 "o produto será nosso" posture (AD-002). M6 vendors the remaining four into the monorepo and completes the commander's final naming convention: **no `-axi` anywhere** — not directories, not packages, not binaries. The already-vendored `packages/tasks-axi` (`sq-tasks-axi`) is renamed to `packages/sq-tasks` (`sq-tasks`). The distro's bootstrap installs the whole toolchain from the workspace; CI grows build+test coverage for the new packages; the unlanded `pr_review_verify` schema fix ships; and a short on-demand upstream-sync procedure is recorded.

## Commander's Final Locked Decisions (verbatim, 2026-08-10)

> 1. Vendor into the runecraftai/squad monorepo (packages/ workspace, following the M2 pattern).
> 2. FINAL NAMES — no "-axi" anywhere (not directories, not packages, not binaries): gh-axi -> sq-gh; chrome-devtools-axi -> sq-browser; tasks-axi -> sq-tasks (this RENAMES the already-vendored packages/tasks-axi: directory -> packages/sq-tasks, package name sq-tasks-axi -> sq-tasks, bin sq-tasks-axi -> sq-tasks, and Squad's own lib bin/sq-tasks-axi-lib.sh -> sq-tasks-lib.sh; the SQUAD_TASKS_AXI_MIN env constant is a durable contract and stays — it belongs to the roadmap-mention item); lavish-axi -> sq-report; quota-axi -> sq-quota. no-mistakes: KEPT (final commander decision). fob: KEPT (already Squad military vocabulary).
> 3. Rename scope NOW: names only (package, bin, directory). Internal strings/mentions (help text, TOON output, README, AXI-compliant terminology, env var names) are deferred to the roadmap item roadmap-futuro-rebrand-completo-de-menco-31 — the specs' roadmap sections must record that, not plan the deep rebrand.
> 4. Each tool gets its OWN tlc-spec-driven spec: 5 tool specs (sq-gh, sq-browser, sq-tasks [the rename], sq-quota, sq-report) + 1 umbrella M6 integration spec.
> 5. Upstream sync: on-demand only ("quando der na telha") — include a short sync procedure in the umbrella spec.
> 6. The umbrella spec must also cover: bootstrap wiring so installs come from the workspace (how each tool is built/installed: npm workspace build + local install vs publish), CI additions for the 4 new packages (build+test, following existing package CI jobs), test strategy (upstream test suites must stay green in-workspace, like the M2-M5 vendored packages), version-floor handling after rename, and shipping the already-applied local fix in packages/pr-review/extensions/pr-review-subagent.ts.

### Normalized naming table (single source of truth)

| Upstream tool | Package dir | Package name | Bin | Squad lib | Floor constant |
| --- | --- | --- | --- | --- | --- |
| gh-axi (0.1.30) | `packages/sq-gh` | `sq-gh` | `sq-gh` | — | `GH_AXI_MIN` (name kept; value now 0.1.0 after PR #16) |
| chrome-devtools-axi (0.1.29) | `packages/sq-browser` | `sq-browser` | `sq-browser` | — | presence check only (no floor today) |
| tasks-axi (0.2.5, vendored M2 as sq-tasks-axi) | `packages/tasks-axi` → `packages/sq-tasks` | `sq-tasks-axi` → `sq-tasks` | `sq-tasks-axi` → `sq-tasks` | `bin/sq-tasks-axi-lib.sh` → `bin/sq-tasks-lib.sh` | `SQUAD_TASKS_AXI_MIN` (name kept; value now 0.1.0 after PR #16 — the planned durable 0.2.4 was superseded) |
| lavish-axi (0.1.48) | `packages/sq-report` | `sq-report` | `sq-report` | — | `LAVISH_AXI_MIN` (name kept; value now 0.1.0 after PR #16) |
| quota-axi (0.1.20) | `packages/sq-quota` | `sq-quota` | `sq-quota` | `bin/sq-quota-axi-lib.sh` → `bin/sq-quota-lib.sh` (OQ-M6-04) | `SQUAD_QUOTA_AXI_MIN` (name kept; value now 0.1.0 after PR #16) |
| no-mistakes → drill | `packages/no-mistakes` → `packages/drill` | `no-mistakes` → `drill` | `no-mistakes` → `drill` | `bin/sq-nm-run-lib.sh` → `bin/sq-drill-run-lib.sh` | `NO_MISTAKES_MIN` → `DRILL_MIN=1.31.2` (PR #8) |
| fob | `packages/fob` | `fob` | `fob` | — | fob lease check unchanged; built from source via `bin/sq-install-fob.sh` (PR #26) |

**Post-delivery note (PR #16, 2026-08-11):** all fork package versions and the four AXI floors were reset to the clean **0.1.0** baseline; `vendor.json` retains the upstream pinned versions (0.1.30 / 0.1.29 / 0.1.48 / 0.1.20 / 0.2.5). The planned floor bumps in the original table were superseded.

**Rename-scope boundary (decision 3):** "names only" = directory names, package.json `name`/`bin`/`files` entries, bin entry-file filenames, `dist/` output names, release-please `package-name` fields, build-script path literals, distro call sites and floor operands that execute the tools, and file-path references to renamed files. **Deferred to roadmap-futuro-rebrand-completo-de-menco-31:** help text, TOON output, README/CHANGELOG/VISION prose, AGENTS.md/docs prose, AXI-compliant terminology, env/constant *names* (SQUAD_TASKS_AXI_MIN, GH_AXI_MIN, LAVISH_AXI_MIN, SQUAD_QUOTA_AXI_MIN, `config/backlog-backend` value `tasks-axi`, procevent source id `lavish`), and packaged-skill content prose.

## Goals

- [x] G-M6-01 — **Vendor the remaining four tools** (`gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `quota-axi`) as workspace packages with upstream test suites green in-workspace (M2/M5 precedent) — delivered; suites run in CI (`axi-tools` matrix job)
- [x] G-M6-02 — **Complete the no-`-axi` naming convention**: all seven tools under Squad names; `packages/tasks-axi` → `packages/sq-tasks` (package `sq-tasks`, bin `sq-tasks`, lib `sq-tasks-lib.sh`) — delivered
- [x] G-M6-03 — **Bootstrap installs from the workspace** (npm workspace build + local install; publish deferred — OQ-03 boundary), with version floors retargeted to the new bins — delivered (floors later reset to 0.1.0 baseline, see review note)
- [x] G-M6-04 — **CI build+test coverage for the 4 new packages** (following the existing `tasks-axi` CI job pattern) and the `tasks-axi` job/install steps renamed — delivered (`axi-tools` matrix job + `sq-tasks` job)
- [x] G-M6-05 — **Ship the unlanded pr-review fix** (`pr_review_verify` TypeBox union → single Object schema + runtime validation) and record the on-demand upstream-sync procedure + deferred-rebrand roadmap pointer — delivered (fix committed; pr-review later re-classified maintained, PR #16)

> **Review status (2026-08-13):** M6 delivered 2026-08-10; post-delivery PRs reset every package to a 0.1.0 baseline and floors to 0.1.0 (PR #16), renamed no-mistakes to drill (PR #8), cut goal-loop-audit (commander decision 2026-08-10), scrubbed packaged-skill dirs to sq-* names (PR #25), and switched to the drill validation pipeline. All REQ-M6-* items are DONE in the repo; the acceptance criteria below are updated to the current facts.

## Out of Scope (recorded here, planned in roadmap-futuro-rebrand-completo-de-menco-31)

| Item | Why deferred |
| --- | --- |
| Internal prose/strings in vendored forks (help, TOON, README, CHANGELOG, VISION, AGENTS.md, skill content, AXI terminology) | Commander decision 3 — roadmap item |
| Distro prose mentions (`docs/`, `AGENTS.md`, `bin/sq-brief.sh` operator instructions, `bin/sq-procevent-lib.sh` comments) | Same |
| Renaming floor/env constants (`SQUAD_TASKS_AXI_MIN`, `GH_AXI_MIN`, `LAVISH_AXI_MIN`, `SQUAD_QUOTA_AXI_MIN`), `config/backlog-backend=tasks-axi` protocol value, procevent `lavish` source id | Same (durable contracts; SQUAD_TASKS_AXI_MIN explicitly kept by commander) |
| Real npm publish of the 4 new forks | Org-gated (OQ-03); local install is the M6 path; publish recorded as future |
| fob/no-mistakes release-channel 404 | OQ-03 boundary; unchanged in M6 |

## Requirement IDs

Prefix: `REQ-M6-*` (umbrella integration), `REQ-SQGH-*`, `REQ-SQBROWSER-*`, `REQ-SQTASKS-*`, `REQ-SQQUOTA-*`, `REQ-SQREPORT-*` (per-tool specs). Priority: P0 = gate, P1 = required for M6.

### REQ-M6-01 (P0) — Four tools vendored as workspace packages — ✅ DONE
**User Story:** As commander, I want gh-axi, chrome-devtools-axi, lavish-axi, and quota-axi forked into the monorepo under Squad names so the whole toolchain ships from the Squad repo.

**Acceptance Criteria (current facts):**
1. `packages/` lists `sq-gh/`, `sq-browser/`, `sq-report/`, `sq-quota/` with the pinned upstream sources and a `vendor.json` per package — met
2. Each package's `package.json` `name`/`bin`/`files` use the Squad names per the normalized table — met
3. Each package's test suite runs in-workspace and is green (CI `axi-tools` matrix job runs install+build+test+pack dry-run) — met
4. `turbo run build|test|lint --filter=sq-gh ...` passes from the root — met
5. Name-surface greps find no old names (deferred prose excepted; guard `tests/sq-m6-name-guard.test.sh` green) — met
6. Package versions are the 0.1.0 clean baseline (PR #16 reset), not the upstream pinned versions; `vendor.json` retains upstream provenance

### REQ-M6-02 (P0) — tasks-axi renamed to sq-tasks — ✅ DONE
**User Story:** As commander, I want the already-vendored backlog CLI fully renamed so no `-axi` name survives.

**Acceptance Criteria (current facts):**
1. `packages/tasks-axi` gone; `packages/sq-tasks/` exists — met
2. `packages/sq-tasks/package.json`: `name` = `sq-tasks`, `bin` = `{"sq-tasks": "dist/bin/sq-tasks.js"}` — met
3. `bin/sq-tasks-lib.sh` resolver prefers `sq-tasks` and falls back to `tasks-axi`; `SQUAD_TASKS_AXI_MIN` is 0.1.0 (reset by PR #16; the durable 0.2.4 claim was superseded) — met, with the floor change noted
4. CI install steps install `./packages/sq-tasks` and alias `tasks-axi` → `sq-tasks` — met
5. The fork's tests + build run green in-workspace — met

### REQ-M6-03 (P0) — Bootstrap installs from the workspace — ✅ DONE
**User Story:** As an operator, I want `sq-bootstrap.sh` to detect and install the whole toolchain from the Squad repo, never upstream npm.

**Acceptance Criteria (current facts):**
1. `COMMON_TOOLS` = `node git gh drill sq-gh sq-browser sq-report sq-quota sq-tasks` (drill replaced no-mistakes after PR #8) — met
2. `install_cmd` prints a workspace-local install command per renamed tool (`npm install -g ./packages/<dir>`; legacy aliases per OQ-M6-01 — only the mandatory `tasks-axi` alias was implemented) — met, with the alias scope noted
3. Missing/below-floor tools print `MISSING:` with the workspace install command (no upstream npm URLs for the forks) — met

### REQ-M6-04 (P0) — Version floors retargeted — ✅ DONE (values reset by PR #16)
**User Story:** As commander, I want floors to gate the Squad forks.

**Acceptance Criteria (current facts):**
1. `sq-bootstrap.sh` floor checks probe the new bin names (`sq-gh`, `sq-report`, `sq-quota`, `sq-tasks`) — met
2. Floor values are all 0.1.0 now (`GH_AXI_MIN`, `LAVISH_AXI_MIN`, `SQUAD_QUOTA_AXI_MIN`, `SQUAD_TASKS_AXI_MIN`) — the planned bumps (0.1.30/0.1.48/0.1.20, keep 0.2.4) were superseded by the clean-baseline reset (PR #16)
3. `bin/sq-quota-lib.sh` (ex sq-quota-axi-lib.sh) probes `sq-quota` — met

### REQ-M6-05 (P0) — CI additions for the 4 new packages — ✅ DONE
**User Story:** As the team, I want CI to prove the new packages.

**Acceptance Criteria (current facts):**
1. `.github/workflows/ci.yml` has a build+test job covering sq-gh, sq-browser, sq-quota, sq-report (`axi-tools` matrix: pnpm 11.1.1 + node 22 + install/build/test + `npm pack --dry-run` bin check) — met
2. The existing `tasks-axi` job/install steps reference `packages/sq-tasks` and the `sq-tasks` bin with the `tasks-axi` alias kept — met
3. New jobs green on the M6 branch (recorded at completion) — met

### REQ-M6-06 (P0) — pr-review fix shipped — ✅ DONE
**User Story:** As the team, I want the unlanded `pr_review_verify` schema fix in the repo.

**Acceptance Criteria (current facts):**
1. `packages/pr-review/extensions/pr-review-subagent.ts` is committed with the working-tree fix (single Object schema + runtime required-field validation) — met (committed in the M6 branch; pr-review later re-classified maintained, PR #16)
2. `bun test` in `packages/pr-review`: 250 pass / 2 fail — the two failures are README-content assertions that drifted during the PR #11 README beautification and are unrelated to the schema fix; the schema-fix regression test passes ("registers a single top-level object schema and enforces run's required fields at runtime") — met with the residual noted

### REQ-M6-07 (P1) — Sync-on-demand procedure + deferred-rebrand roadmap pointer — ✅ DONE
**User Story:** As the team, I want a short documented procedure for re-vendoring from upstream when the commander asks ("quando der na telha").

**Acceptance Criteria (current facts):**
1. Umbrella design.md §9 has the step-by-step sync procedure (pin, copy, name sweep, floor bump, provenance update, test gate) — met
2. Umbrella spec and ROADMAP.md point at roadmap-futuro-rebrand-completo-de-menco-31 for the deep rebrand (deferred per decision 3) — met; the rebrand item also owns the stale `SQUAD_TASKS_AXI_MIN` note and the four missing legacy aliases

## Traceability

| Requirement | Feature spec | Depends on |
| --- | --- | --- |
| REQ-M6-01 | sq-gh / sq-browser / sq-quota / sq-report specs | M2 pattern (tasks-axi), M3/M5 provenance |
| REQ-M6-02 | sq-tasks spec | M2 fork state |
| REQ-M6-03, REQ-M6-04 | umbrella design §3–§5 | REQ-M6-01, REQ-M6-02 |
| REQ-M6-05 | umbrella design §6 | REQ-M6-01, REQ-M6-02 |
| REQ-M6-06 | umbrella design §8 | M3 vendored pr-review |
| REQ-M6-07 | umbrella design §9 + ROADMAP | all of the above |

## Success Criteria (M6) — all met; current-fact corrections in [brackets]

1. All seven tools live under Squad names in `packages/`; zero old tool names in name-surfaces (guard-defined, deferred prose excluded) — met
2. Each vendored fork's upstream test suite green in-workspace (turbo + per-package runners; CI `axi-tools` matrix) — met [package versions are the 0.1.0 baseline]
3. `sq-bootstrap.sh` detects/installs the whole toolchain from the workspace with no upstream npm URLs; floors gate the forks — met [floors 0.1.0 after PR #16; drill on the OQ-03 release placeholder]
4. CI green on the M6 branch including the new package jobs and the renamed tasks-axi job — met
5. pr-review fix committed; sync procedure + deferred-rebrand pointer recorded in ROADMAP/STATE — met
