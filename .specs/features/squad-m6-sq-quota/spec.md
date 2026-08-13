# Squad M6 — sq-quota (ex quota-axi) — Specification

**Scope:** Medium (vendor one TS package + name rename + lib/floor/wiring sweep)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/`
**Language:** English (AD-008)

## Problem Statement

`quota-axi` (kunchenguid/quota-axi, v0.1.20 — "let agents see LLM subscription quota windows") backs the agent-owned dispatch-profile array (AGENTS.md §4) and is a required bootstrap tool gated by `SQUAD_QUOTA_AXI_MIN` (owner: `bin/sq-quota-lib.sh`, ex-`sq-quota-axi-lib.sh`). M6 vendored it as `packages/sq-quota` (package `sq-quota`, bin `sq-quota`); the distro lib probes `sq-quota` and the floor is the 0.1.0 clean-baseline reset (PR #16 — the planned bump to the vendored version was superseded).

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
| version | 0.1.20 | **0.1.0 (clean-baseline reset, PR #16)** — vendor.json keeps upstream 0.1.20 provenance | — | ✅ |
| engines node>=22.19, deps (@toon-format/toon, axi-sdk-js), pnpm@11.1.1, `.airlock/lint.sh`, `.release-please-manifest.json`, tsconfig, eslint | — | unchanged (manifest `".": "0.1.0"`) | — | ✅ |
| README / CHANGELOG / help / TOON prose | — | — | — | ✅ (roadmap item) |
| Distro lib file | `bin/sq-quota-axi-lib.sh` | `bin/sq-quota-lib.sh` (OQ-M6-04 (a)) | ✅ (OQ) | — |
| Distro lib probe | `command -v quota-axi` + `quota-axi --version` | `command -v sq-quota` + `sq-quota --version` | ✅ | — |
| Floor constant | `SQUAD_QUOTA_AXI_MIN=0.1.17` | name stays, value **0.1.0** (reset by PR #16; planned 0.1.20 bump superseded) | ✅ (value) | constant NAME defers |

## Requirements

### REQ-SQQUOTA-01 (P0) — Vendored at the pinned tag — ✅ DONE
**Acceptance Criteria (current facts):**
1. `packages/sq-quota/` contains the quota-axi v0.1.20 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json` — met (package version 0.1.0 baseline; vendor.json records upstream 0.1.20)
2. `package.json` `version` is 0.1.0 (baseline reset); vendor.json documents the 0.1.20 pin

### REQ-SQQUOTA-02 (P0) — Names renamed — ✅ DONE
**Acceptance Criteria (current facts):**
1. dir/name/bin/files/skill-dir/release-please name match the New column — met
2. `grep -rE '\bquota-axi\b' packages/sq-quota/package.json packages/sq-quota/bin packages/sq-quota/release-please-config.json` returns 0 hits — met

### REQ-SQQUOTA-03 (P0) — Tests green in-workspace — ✅ DONE
**Acceptance Criteria (current facts):**
1. `pnpm install --frozen-lockfile && pnpm build && pnpm test` in `packages/sq-quota` is green (build-first test script; CI `axi-tools` matrix) — met
2. `npm pack --dry-run` lists `dist/bin/sq-quota.js` — met

### REQ-SQQUOTA-04 (P0) — Distro probes `sq-quota` with the new floor — ✅ DONE
**Acceptance Criteria (current facts):**
1. `bin/sq-quota-lib.sh` (ex sq-quota-axi-lib.sh) probes `sq-quota` and `SQUAD_QUOTA_AXI_MIN=0.1.0` (reset by PR #16); sourcing files (sq-bootstrap.sh, sq-test-run.sh lane) use the renamed path — met
2. `COMMON_TOOLS`/`install_cmd` in `bin/sq-bootstrap.sh` name `sq-quota` with the workspace install command — met
3. Test fakebins named `quota-axi` swept → `sq-quota` (prose-assertion keep-list exempt) — met

### REQ-SQQUOTA-05 (P0) — Turbo integration — ✅ DONE
**Acceptance Criteria (current facts):**
1. `turbo run build|test|lint --filter=sq-quota` passes from the root — met

## Traceability
REQ-SQQUOTA-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03, REQ-M6-04 (floor), OQ-M6-04. **Status: DONE (reviewed 2026-08-13).** Post-delivery deltas: package version and floor reset to 0.1.0 (PR #16); `bin/sq-quota-lib.sh` rename landed (OQ-M6-04 (a)); packaged skill dir now `skills/sq-quota` (PR #25 scrub); no legacy `quota-axi` alias was created (OQ-M6-01 partial).
