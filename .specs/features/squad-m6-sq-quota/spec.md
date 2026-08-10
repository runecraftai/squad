# Squad M6 — sq-quota (ex quota-axi) — Specification

**Scope:** Medium (vendor one TS package + name rename + lib/floor/wiring sweep)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/`
**Language:** English (AD-008)

## Problem Statement

`quota-axi` (kunchenguid/quota-axi, v0.1.20 — "let agents see LLM subscription quota windows") backs the agent-owned dispatch-profile array (AGENTS.md §4) and is a required bootstrap tool gated by `SQUAD_QUOTA_AXI_MIN` (owner: `bin/sq-quota-axi-lib.sh`). M6 vendors it as `packages/sq-quota` (package `sq-quota`, bin `sq-quota`); the distro lib probes `sq-quota` and the floor is bumped to the vendored version.

## Rename Table (single source of truth for this tool)

| Surface | Old (upstream) | New | MUST change | Stay (deferred) |
| --- | --- | --- | --- | --- |
| Package dir | `packages/quota-axi` | `packages/sq-quota` | ✅ | — |
| package.json `name` | `quota-axi` | `sq-quota` | ✅ | — |
| package.json `bin` | `{"quota-axi": "./dist/bin/quota-axi.js"}` | `{"sq-quota": "./dist/bin/sq-quota.js"}` | ✅ | — |
| package.json `files` | `['dist','skills/quota-axi','LICENSE','README.md']` | `skills/sq-quota` entry | ✅ | — |
| bin entry source | `bin/quota-axi.ts` | `bin/sq-quota.ts` (tsc → `dist/bin/sq-quota.js`) | ✅ | — |
| Packaged skill dir | `skills/quota-axi/` | `skills/sq-quota/` (A-M6-01) | ✅ | — |
| release-please `package-name` | `quota-axi` | `sq-quota` | ✅ | — |
| src name literals | version.ts name check / skill.ts / model-kb refs | follow new name (name-encoding only) | ✅ (names) | prose defers |
| version | 0.1.20 | 0.1.20 (kept) | — | ✅ |
| engines node>=22.19, deps (@toon-format/toon, axi-sdk-js), pnpm@11.1.1, `.airlock/lint.sh`, `.release-please-manifest.json`, tsconfig, eslint | — | unchanged | — | ✅ |
| README / CHANGELOG / help / TOON prose | — | — | — | ✅ (roadmap item) |
| Distro lib file | `bin/sq-quota-axi-lib.sh` | `bin/sq-quota-lib.sh` (OQ-M6-04 default (a)) | ✅ (OQ) | — |
| Distro lib probe | `command -v quota-axi` + `quota-axi --version` | `command -v sq-quota` + `sq-quota --version` | ✅ | — |
| Floor constant | `SQUAD_QUOTA_AXI_MIN=0.1.17` | name stays, value 0.1.20 | ✅ (value) | constant NAME defers |

## Requirements

### REQ-SQQUOTA-01 (P0) — Vendored at the pinned tag
**Acceptance Criteria:**
1. WHEN `packages/sq-quota/` is inspected THEN it SHALL contain the quota-axi v0.1.20 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json`
2. WHEN `package.json` is read THEN `version` SHALL be 0.1.20

### REQ-SQQUOTA-02 (P0) — Names renamed
**Acceptance Criteria:**
1. WHEN the rename table is applied THEN dir/name/bin/files/skill-dir/release-please name SHALL match the New column
2. WHEN `grep -rE '\bquota-axi\b' packages/sq-quota/package.json packages/sq-quota/bin packages/sq-quota/release-please-config.json` runs THEN it SHALL return 0 hits

### REQ-SQQUOTA-03 (P0) — Tests green in-workspace
**Acceptance Criteria:**
1. WHEN `pnpm install --frozen-lockfile && pnpm build && pnpm test` runs in `packages/sq-quota` THEN it SHALL be green (note: upstream `test` script = `pnpm run build && vitest run`)
2. WHEN `npm pack --dry-run` runs THEN `dist/bin/sq-quota.js` SHALL be listed

### REQ-SQQUOTA-04 (P0) — Distro probes `sq-quota` with the new floor
**Acceptance Criteria:**
1. WHEN `bin/sq-quota-lib.sh` (ex sq-quota-axi-lib.sh) is read THEN it SHALL probe `sq-quota` and `SQUAD_QUOTA_AXI_MIN` SHALL be 0.1.20; all sourcing files (sq-bootstrap.sh, sq-test-run.sh lane) SHALL use the renamed path
2. WHEN `COMMON_TOOLS`/`install_cmd` in `bin/sq-bootstrap.sh` are read THEN they SHALL name `sq-quota` with the workspace install command
3. WHEN test fakebins named `quota-axi` are swept THEN they SHALL use `sq-quota` (prose-assertion keep-list exempt)

### REQ-SQQUOTA-05 (P0) — Turbo integration
**Acceptance Criteria:**
1. WHEN `turbo run build|test|lint --filter=sq-quota` runs from the root THEN it SHALL pass

## Traceability
REQ-SQQUOTA-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03, REQ-M6-04 (floor), OQ-M6-04. Success = all five green + umbrella guard.
