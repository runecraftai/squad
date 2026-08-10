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
| gh-axi (0.1.30) | `packages/sq-gh` | `sq-gh` | `sq-gh` | — | `GH_AXI_MIN` (name kept; value bumped) |
| chrome-devtools-axi (0.1.29) | `packages/sq-browser` | `sq-browser` | `sq-browser` | — | presence check only (no floor today) |
| tasks-axi (0.2.5, vendored M2 as sq-tasks-axi) | `packages/tasks-axi` → `packages/sq-tasks` | `sq-tasks-axi` → `sq-tasks` | `sq-tasks-axi` → `sq-tasks` | `bin/sq-tasks-axi-lib.sh` → `bin/sq-tasks-lib.sh` | `SQUAD_TASKS_AXI_MIN` **stays 0.2.4** (durable contract) |
| lavish-axi (0.1.48) | `packages/sq-report` | `sq-report` | `sq-report` | — | `LAVISH_AXI_MIN` (name kept; value bumped) |
| quota-axi (0.1.20) | `packages/sq-quota` | `sq-quota` | `sq-quota` | `bin/sq-quota-axi-lib.sh` (rename = OQ-M6-04) | `SQUAD_QUOTA_AXI_MIN` (name kept; value bumped) |
| no-mistakes | **KEPT** | **KEPT** | **KEPT** | — | `NO_MISTAKES_MIN` unchanged |
| fob | **KEPT** | **KEPT** | **KEPT** | — | fob lease check unchanged |

**Rename-scope boundary (decision 3):** "names only" = directory names, package.json `name`/`bin`/`files` entries, bin entry-file filenames, `dist/` output names, release-please `package-name` fields, build-script path literals, distro call sites and floor operands that execute the tools, and file-path references to renamed files. **Deferred to roadmap-futuro-rebrand-completo-de-menco-31:** help text, TOON output, README/CHANGELOG/VISION prose, AGENTS.md/docs prose, AXI-compliant terminology, env/constant *names* (SQUAD_TASKS_AXI_MIN, GH_AXI_MIN, LAVISH_AXI_MIN, SQUAD_QUOTA_AXI_MIN, `config/backlog-backend` value `tasks-axi`, procevent source id `lavish`), and packaged-skill content prose.

## Goals

- [ ] G-M6-01 — **Vendor the remaining four tools** (`gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `quota-axi`) as workspace packages with upstream test suites green in-workspace (M2/M5 precedent)
- [ ] G-M6-02 — **Complete the no-`-axi` naming convention**: all seven tools under Squad names; `packages/tasks-axi` → `packages/sq-tasks` (package `sq-tasks`, bin `sq-tasks`, lib `sq-tasks-lib.sh`)
- [ ] G-M6-03 — **Bootstrap installs from the workspace** (npm workspace build + local install; publish deferred — OQ-03 boundary), with version floors retargeted to the new bins
- [ ] G-M6-04 — **CI build+test coverage for the 4 new packages** (following the existing `tasks-axi` CI job pattern) and the `tasks-axi` job/install steps renamed
- [ ] G-M6-05 — **Ship the unlanded pr-review fix** (`pr_review_verify` TypeBox union → single Object schema + runtime validation) and record the on-demand upstream-sync procedure + deferred-rebrand roadmap pointer

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

### REQ-M6-01 (P0) — Four tools vendored as workspace packages
**User Story:** As commander, I want gh-axi, chrome-devtools-axi, lavish-axi, and quota-axi forked into the monorepo under Squad names so the whole toolchain ships from the Squad repo.

**Acceptance Criteria:**
1. WHEN `packages/` is listed THEN `sq-gh/`, `sq-browser/`, `sq-report/`, `sq-quota/` SHALL exist with upstream source at the pinned versions (gh-axi 0.1.30, chrome-devtools-axi 0.1.29, lavish-axi 0.1.48, quota-axi 0.1.20) and a provenance record (`vendor.json`) per package
2. WHEN each package's `package.json` is read THEN `name`, `bin`, and `files` SHALL use the Squad names per the normalized table
3. WHEN each package's test suite runs in-workspace THEN it SHALL be green (same pass set as upstream)
4. WHEN `turbo run build|test|lint --filter=sq-gh --filter=sq-browser --filter=sq-quota --filter=sq-report` runs THEN it SHALL pass
5. WHEN name-surfaces are grepped (per-tool tasks define the exact set) THEN no old name SHALL remain (deferred prose excepted)

### REQ-M6-02 (P0) — tasks-axi renamed to sq-tasks
**User Story:** As commander, I want the already-vendored backlog CLI fully renamed so no `-axi` name survives.

**Acceptance Criteria:**
1. WHEN `packages/` is listed THEN `packages/tasks-axi` SHALL be gone and `packages/sq-tasks/` SHALL exist
2. WHEN `packages/sq-tasks/package.json` is read THEN `name` = `sq-tasks`, `bin` = `{"sq-tasks": "dist/bin/sq-tasks.js"}`, `files` updated
3. WHEN `bin/sq-tasks-lib.sh` (ex-`bin/sq-tasks-axi-lib.sh`) is read THEN the resolver SHALL prefer `sq-tasks` and fall back to `tasks-axi`; `SQUAD_TASKS_AXI_MIN` SHALL remain 0.2.4
4. WHEN CI install steps run THEN they SHALL install `./packages/sq-tasks` and alias `tasks-axi` → `sq-tasks`
5. WHEN the fork's tests + build run THEN they SHALL be green

### REQ-M6-03 (P0) — Bootstrap installs from the workspace
**User Story:** As an operator, I want `sq-bootstrap.sh` to detect and install the whole toolchain from the Squad repo, never upstream npm.

**Acceptance Criteria:**
1. WHEN `COMMON_TOOLS` is read THEN it SHALL list `sq-gh sq-browser sq-report sq-quota sq-tasks` (plus unchanged node git gh no-mistakes fob)
2. WHEN `install_cmd` runs for each renamed tool THEN it SHALL print a workspace-local install command (npm global install of `./packages/<dir>`; legacy aliases per OQ-M6-01)
3. WHEN a tool is missing or below floor THEN `MISSING:` SHALL print with the workspace install command (no upstream URLs)

### REQ-M6-04 (P0) — Version floors retargeted
**User Story:** As commander, I want floors to gate the Squad forks.

**Acceptance Criteria:**
1. WHEN `sq-bootstrap.sh` floor checks run THEN they SHALL probe the new bin names (`sq-gh`, `sq-report`, `sq-quota`, `sq-tasks`)
2. WHEN floor values are read THEN `GH_AXI_MIN` SHALL be 0.1.30, `LAVISH_AXI_MIN` 0.1.48, `SQUAD_QUOTA_AXI_MIN` 0.1.20, `SQUAD_TASKS_AXI_MIN` 0.2.4 (unchanged)
3. WHEN `bin/sq-quota-axi-lib.sh` compatibility probe runs THEN it SHALL probe `sq-quota` (lib filename per OQ-M6-04)

### REQ-M6-05 (P0) — CI additions for the 4 new packages
**User Story:** As the team, I want CI to prove the new packages.

**Acceptance Criteria:**
1. WHEN `.github/workflows/ci.yml` is read THEN a build+test job SHALL cover sq-gh, sq-browser, sq-quota, sq-report (matrix or per-package, following the `tasks-axi` job pattern: pnpm install --frozen-lockfile + build + test + `npm pack --dry-run` bin check)
2. WHEN the existing `tasks-axi` job and install steps are read THEN they SHALL reference `packages/sq-tasks` and the `sq-tasks` bin (alias `tasks-axi` kept)
3. WHEN CI runs on the M6 branch THEN the new jobs SHALL be green (recorded at completion)

### REQ-M6-06 (P0) — pr-review fix shipped
**User Story:** As the team, I want the unlanded `pr_review_verify` schema fix in the repo.

**Acceptance Criteria:**
1. WHEN `git status` is read at M6 completion THEN `packages/pr-review/extensions/pr-review-subagent.ts` SHALL be committed with the working-tree fix (single Object schema + runtime required-field validation), not just present uncommitted
2. WHEN `bun test` runs in `packages/pr-review` THEN it SHALL be green; a subagent-spawn smoke SHALL not hit "Invalid schema for function 'pr_review_verify'"

### REQ-M6-07 (P1) — Sync-on-demand procedure + deferred-rebrand roadmap pointer
**User Story:** As the team, I want a short documented procedure for re-vendoring from upstream when the commander asks ("quando der na telha").

**Acceptance Criteria:**
1. WHEN the umbrella design.md §9 is read THEN a step-by-step sync procedure SHALL exist (pin, copy, name sweep, floor bump, provenance update, test gate)
2. WHEN the umbrella spec and ROADMAP.md are read THEN a section SHALL point at roadmap-futuro-rebrand-completo-de-menco-31 for the deep rebrand (deferred per decision 3)

## Traceability

| Requirement | Feature spec | Depends on |
| --- | --- | --- |
| REQ-M6-01 | sq-gh / sq-browser / sq-quota / sq-report specs | M2 pattern (tasks-axi), M3/M5 provenance |
| REQ-M6-02 | sq-tasks spec | M2 fork state |
| REQ-M6-03, REQ-M6-04 | umbrella design §3–§5 | REQ-M6-01, REQ-M6-02 |
| REQ-M6-05 | umbrella design §6 | REQ-M6-01, REQ-M6-02 |
| REQ-M6-06 | umbrella design §8 | M3 vendored pr-review |
| REQ-M6-07 | umbrella design §9 + ROADMAP | all of the above |

## Success Criteria (M6)

1. All seven tools live under Squad names in `packages/`; zero old tool names in name-surfaces (guard-defined, deferred prose excluded)
2. Each vendored fork's upstream test suite green in-workspace (turbo + per-package runners)
3. `sq-bootstrap.sh` detects/installs the whole toolchain from the workspace with no upstream npm URLs; floors gate the forks
4. CI green on the M6 branch including the new package jobs and the renamed tasks-axi job
5. pr-review fix committed; sync procedure + deferred-rebrand pointer recorded in ROADMAP/STATE
