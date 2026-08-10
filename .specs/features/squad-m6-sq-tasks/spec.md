# Squad M6 — sq-tasks (rename of vendored tasks-axi / sq-tasks-axi) — Specification

**Scope:** Medium (rename of an already-vendored TS package + distro lib/alias/wiring sweep)
**Prereq:** M2 fork state (`packages/tasks-axi`, name `sq-tasks-axi`, bin `sq-tasks-axi`, lib `bin/sq-tasks-axi-lib.sh`) · umbrella `.specs/features/squad-m6-vendoring/`
**Language:** English (AD-008)

## Problem Statement

The M2 fork of tasks-axi (v0.2.5) lives at `packages/tasks-axi` under the interim Squad name `sq-tasks-axi`. The commander's final naming convention bans `-axi` everywhere: the fork becomes `packages/sq-tasks` (package `sq-tasks`, bin `sq-tasks`), and Squad's own backlog lib `bin/sq-tasks-axi-lib.sh` becomes `bin/sq-tasks-lib.sh`. The `SQUAD_TASKS_AXI_MIN` env constant is a durable contract and STAYS (it belongs to the roadmap-mention item). Rename scope is names only (CD-M6-03); internal prose defers to roadmap-futuro-rebrand-completo-de-menco-31.

## Rename Table (single source of truth for this tool)

| Surface | Old (M2 fork) | New | MUST change | Stay (deferred) |
| --- | --- | --- | --- | --- |
| Package dir | `packages/tasks-axi/` | `packages/sq-tasks/` | ✅ | — |
| package.json `name` | `sq-tasks-axi` | `sq-tasks` | ✅ | — |
| package.json `bin` | `{"sq-tasks-axi": "dist/bin/sq-tasks-axi.js"}` | `{"sq-tasks": "dist/bin/sq-tasks.js"}` | ✅ | — |
| package.json `files` | `['dist/**/*.js','skills/tasks-axi','LICENSE','README.md']` | `skills/sq-tasks` entry | ✅ | — |
| bin entry source | `bin/sq-tasks-axi.ts` | `bin/sq-tasks.ts` (tsc → `dist/bin/sq-tasks.js`) | ✅ | — |
| Packaged skill dir | `skills/tasks-axi/` | `skills/sq-tasks/` (A-M6-01; content prose defers) | ✅ | — |
| release-please `package-name` | (verify at execute: `tasks-axi` or `sq-tasks-axi`) | `sq-tasks` | ✅ | — |
| `src/version.ts` name check + fixtures encoding the bin name | `sq-tasks-axi` | `sq-tasks` | ✅ (name-encoding) | prose defers |
| Distro lib | `bin/sq-tasks-axi-lib.sh` | `bin/sq-tasks-lib.sh` (commander-mandated) | ✅ | — |
| Lib resolver `fm_tasks_axi_cmd` | prefer `sq-tasks-axi`, fallback `tasks-axi` | prefer `sq-tasks`, fallback `tasks-axi` | ✅ | — |
| Lib constant | `SQUAD_TASKS_AXI_MIN=0.2.4` | **unchanged 0.2.4** (durable contract) | — | ✅ |
| CI install steps | `npm install -g ./packages/tasks-axi`; alias `ln -s sq-tasks-axi tasks-axi` | `./packages/sq-tasks`; alias `ln -s sq-tasks tasks-axi` | ✅ | — |
| CI job name | `tasks-axi` job | `sq-tasks` job | ✅ | — |
| tests referencing the fork bin | `sq-tasks-axi` stubs/assertions | `sq-tasks` | ✅ (name refs) | prose assertions defer |
| version | 0.2.5 | 0.2.5 (kept) | — | ✅ |
| engines node>=20, deps (@toon-format/toon, axi-sdk-js), pnpm@11.1.1, tsconfig, eslint, `.release-please-manifest.json` | — | unchanged | — | ✅ |
| README / CHANGELOG / help / TOON prose (incl. `firstmate-backlog.md` fixture prose, skill content) | — | — | — | ✅ (roadmap item) |
| `config/backlog-backend=tasks-axi` protocol value | — | — | — | ✅ (durable protocol name, deferred) |

## Requirements

### REQ-SQTASKS-01 (P0) — Fork renamed
**Acceptance Criteria:**
1. WHEN `packages/` is listed THEN `packages/tasks-axi` SHALL be gone and `packages/sq-tasks/` SHALL exist with the same 77 tracked files (minus the dir rename, plus `vendor.json` if OQ-M6-06 (a))
2. WHEN `packages/sq-tasks/package.json` is read THEN `name` = `sq-tasks` and `bin` = `{"sq-tasks": "dist/bin/sq-tasks.js"}`
3. WHEN `grep -rE '\bsq-tasks-axi\b' packages/sq-tasks/package.json packages/sq-tasks/bin` runs THEN it SHALL return 0 hits

### REQ-SQTASKS-02 (P0) — Distro lib renamed with resolver intact
**Acceptance Criteria:**
1. WHEN `bin/sq-tasks-lib.sh` is read THEN `fm_tasks_axi_cmd` SHALL prefer `sq-tasks` and fall back to `tasks-axi`; `SQUAD_TASKS_AXI_MIN` SHALL be 0.2.4
2. WHEN every file sourcing the lib is read (sq-bootstrap.sh, sq-public-followup.sh/-lib/-emit, sq-unit-snapshot.sh, sq-x-poll.sh, + any test) THEN the source path SHALL point at `sq-tasks-lib.sh`

### REQ-SQTASKS-03 (P0) — CI renamed with the `tasks-axi` protocol alias kept
**Acceptance Criteria:**
1. WHEN `.github/workflows/ci.yml` is read THEN install steps SHALL use `./packages/sq-tasks` and `ln -s "$(command -v sq-tasks)" .../tasks-axi`; the fork job SHALL be named `sq-tasks`
2. WHEN `tasks-axi --version` and `sq-tasks --version` run on a CI-like PATH THEN both SHALL report 0.2.5

### REQ-SQTASKS-04 (P0) — Build + tests green after rename
**Acceptance Criteria:**
1. WHEN `pnpm install --frozen-lockfile && pnpm build && pnpm test` runs in `packages/sq-tasks` THEN it SHALL be green (429 passed / 1 skipped at M2)
2. WHEN `npm pack --dry-run` runs THEN `dist/bin/sq-tasks.js` SHALL be listed

### REQ-SQTASKS-05 (P0) — Distro test references swept
**Acceptance Criteria:**
1. WHEN tests referencing `sq-tasks-axi` are swept THEN they SHALL reference `sq-tasks` (name refs); prose-assertion keep-list exempt
2. WHEN the umbrella name-guard runs THEN `\bsq-tasks-axi\b` SHALL be absent from name-surfaces

## Traceability
REQ-SQTASKS-01..05 ↔ umbrella REQ-M6-02 (AC1–AC5), REQ-M6-03/04 (floors/CI), REQ-M6-06 (provenance backfill, OQ-M6-06). Success = all five green + umbrella guard.
