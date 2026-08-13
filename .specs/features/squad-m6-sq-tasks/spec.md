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
| Lib constant | `SQUAD_TASKS_AXI_MIN=0.2.4` | **0.1.0** (reset by PR #16 clean-baseline; the durable 0.2.4 claim was superseded) | — | ✅ (constant NAME defers) |
| CI install steps | `npm install -g ./packages/tasks-axi`; alias `ln -s sq-tasks-axi tasks-axi` | `./packages/sq-tasks`; alias `ln -s sq-tasks tasks-axi` | ✅ | — |
| CI job name | `tasks-axi` job | `sq-tasks` job | ✅ | — |
| tests referencing the fork bin | `sq-tasks-axi` stubs/assertions | `sq-tasks` | ✅ (name refs) | prose assertions defer |
| version | 0.2.5 | 0.2.5 (kept) | — | ✅ |
| engines node>=20, deps (@toon-format/toon, axi-sdk-js), pnpm@11.1.1, tsconfig, eslint, `.release-please-manifest.json` | — | unchanged | — | ✅ |
| README / CHANGELOG / help / TOON prose (incl. `firstmate-backlog.md` fixture prose, skill content) | — | — | — | ✅ (roadmap item) |
| `config/backlog-backend=tasks-axi` protocol value | — | — | — | ✅ (durable protocol name, deferred) |

## Requirements

### REQ-SQTASKS-01 (P0) — Fork renamed — ✅ DONE
**Acceptance Criteria (current facts):**
1. `packages/tasks-axi` gone; `packages/sq-tasks/` exists with the same tracked files (minus the dir rename, plus `vendor.json`) — met (vendor.json added per OQ-M6-06 (a))
2. `packages/sq-tasks/package.json`: `name` = `sq-tasks`, `bin` = `{"sq-tasks": "dist/bin/sq-tasks.js"}` — met; version is the 0.1.0 baseline (PR #16)
3. `grep -rE '\bsq-tasks-axi\b' packages/sq-tasks/package.json packages/sq-tasks/bin` returns 0 hits — met

### REQ-SQTASKS-02 (P0) — Distro lib renamed with resolver intact — ✅ DONE
**Acceptance Criteria (current facts):**
1. `bin/sq-tasks-lib.sh`: `fm_tasks_axi_cmd` prefers `sq-tasks` and falls back to `tasks-axi`; `SQUAD_TASKS_AXI_MIN` is 0.1.0 (reset by PR #16) — met
2. Every file sourcing the lib points at `sq-tasks-lib.sh` (sq-bootstrap.sh, sq-public-followup.sh/-lib/-emit, sq-unit-snapshot.sh, sq-x-poll.sh, sq-backlog-handoff/-receive, sq-decision-hold, sq-remote-doctor, sq-teardown, sq-session-start, sq-test-run, + tests) — met

### REQ-SQTASKS-03 (P0) — CI renamed with the `tasks-axi` protocol alias kept — ✅ DONE
**Acceptance Criteria (current facts):**
1. `.github/workflows/ci.yml` install steps use `./packages/sq-tasks` and `ln -s "$(command -v sq-tasks)" .../tasks-axi`; the fork job is named `sq-tasks` — met
2. `tasks-axi --version` and `sq-tasks --version` on a CI-like PATH both report the installed version (0.1.0 baseline) — met

### REQ-SQTASKS-04 (P0) — Build + tests green after rename — ✅ DONE
**Acceptance Criteria (current facts):**
1. `pnpm install --frozen-lockfile && pnpm build && pnpm test` in `packages/sq-tasks` is green (429 passed / 1 skipped baseline at M2; still green via CI) — met
2. `npm pack --dry-run` lists `dist/bin/sq-tasks.js` — met

### REQ-SQTASKS-05 (P0) — Distro test references swept — ✅ DONE
**Acceptance Criteria (current facts):**
1. Tests referencing `sq-tasks-axi` swept → `sq-tasks` (name refs); prose-assertion keep-list exempt — met
2. Umbrella name-guard shows `\bsq-tasks-axi\b` absent from name-surfaces — met (guard green 2026-08-13)

## Traceability
REQ-SQTASKS-01..05 ↔ umbrella REQ-M6-02 (AC1–AC5), REQ-M6-03/04 (floors/CI), REQ-M6-06 (provenance backfill, OQ-M6-06). **Status: DONE (reviewed 2026-08-13).** Post-delivery deltas: `SQUAD_TASKS_AXI_MIN` is 0.1.0 (PR #16 reset — the durable 0.2.4 claim was superseded, and the sq-tasks `vendor.json` note saying it stays 0.2.4 is stale, owned by the rebrand item); packaged skill dir now `skills/sq-tasks` (PR #25 scrub); `config/backlog-backend=tasks-axi` protocol value unchanged (deferred).
