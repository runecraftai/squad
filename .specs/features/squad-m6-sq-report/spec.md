# Squad M6 — sq-report (ex lavish-axi) — Specification

**Scope:** Medium (vendor one JS package + name rename + distro wiring)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/`
**Language:** English (AD-008)

## Problem Statement

`lavish-axi` (kunchenguid/lavish-axi, v0.1.48 — "HTML is the new markdown; the editor for your HTML artifacts") powers the procevent feedback loop (`bin/sq-procevent-lavish.sh` executes `sq-report poll`; register id `lavish` kept) and is a required bootstrap tool gated by `LAVISH_AXI_MIN`. M6 vendored it as `packages/sq-report` (package `sq-report`, bin `sq-report`) with upstream tests green in-workspace. It is the odd one out: plain JavaScript (no tsc), `node>=22`, ~76 MB repo (marketing renders), build via `node scripts/build.js`, and its packaged skill dir is already `skills/lavish` (no `-axi` → KEPT, product name defers).

## Rename Table (single source of truth for this tool)

| Surface | Old (upstream) | New | MUST change | Stay (deferred) |
| --- | --- | --- | --- | --- |
| Package dir | `packages/lavish-axi` | `packages/sq-report` | ✅ | — |
| package.json `name` | `lavish-axi` | `sq-report` | ✅ | — |
| package.json `bin` | `{"lavish-axi": "dist/cli.mjs"}` | `{"sq-report": "dist/cli.mjs"}` (output filename generic — only the bin KEY changes) | ✅ | — |
| package.json `files` | `['dist','plugin.json','skills/lavish','lavish-editor-marketing/renders/…gif','LICENSE','THIRD-PARTY-NOTICES.md','README.md']` | unchanged (no `-axi` in entries) | — | ✅ |
| bin entry source | `bin/lavish-axi.js` | `bin/sq-report.js` | ✅ | — |
| Packaged skill dir | `skills/lavish/` | **KEPT** (product name "Lavish", no `-axi`) | — | ✅ (roadmap item) |
| release-please `package-name` | `lavish-axi` | `sq-report` | ✅ | — |
| plugin.json | Chrome-extension manifest | verify: rename only NAME-encoding fields (e.g., id/name literal `lavish-axi`); display-name/version JSONPath stays | ✅ (name-encoding only) | prose defers |
| src name literals | cli.js/plugin.js/skill.js bin refs | follow new name (name-encoding only) | ✅ (names) | prose defers |
| version | 0.1.48 | **0.1.0 (clean-baseline reset, PR #16)** — vendor.json keeps upstream 0.1.48 provenance | — | ✅ |
| engines node>=22, deps (@tailwindcss/browser, axi-sdk-js, chokidar, cross-spawn, daisyui, express, open, parse5), pnpm@11.1.1, scripts (build via node), `.tool-versions`, `.prettierrc`, tsconfig (typecheck only), THIRD-PARTY-NOTICES.md | — | unchanged (manifest `".": "0.1.0"`) | — | ✅ |
| README / CHANGELOG / VISION / help prose | — | — | — | ✅ (roadmap item) |
| Floor constant `LAVISH_AXI_MIN` | name + 0.1.46 | name stays, value **0.1.0** (reset by PR #16; planned 0.1.48 bump superseded), operand `sq-report` | ✅ (operand+value) | constant NAME defers |
| Procevent source id `lavish` | — | KEPT (protocol id, deferred) | — | ✅ |

## Requirements

### REQ-SQREPORT-01 (P0) — Vendored at the pinned tag — ✅ DONE
**Acceptance Criteria (current facts):**
1. `packages/sq-report/` contains the lavish-axi v0.1.48 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json` — met (package version 0.1.0 baseline; vendor.json records upstream 0.1.48)
2. `package.json` `version` is 0.1.0 (baseline reset) and `bin` is `{"sq-report": "dist/cli.mjs"}` — met; vendor.json documents the 0.1.48 pin

### REQ-SQREPORT-02 (P0) — Names renamed — ✅ DONE
**Acceptance Criteria (current facts):**
1. dir/name/bin-key/release-please name match the New column — met
2. `grep -rE '\blavish-axi\b' packages/sq-report/package.json packages/sq-report/bin packages/sq-report/release-please-config.json` returns 0 hits — met

### REQ-SQREPORT-03 (P0) — Tests green in-workspace — ✅ DONE
**Acceptance Criteria (current facts):**
1. `pnpm install --frozen-lockfile && pnpm build && pnpm test` in `packages/sq-report` is green (vitest, ~24 JS suites; browser-tagged suites behave as upstream; CI `axi-tools` matrix) — met
2. `npm pack --dry-run` lists `dist/cli.mjs` under the `sq-report` bin — met

### REQ-SQREPORT-04 (P0) — Distro executes `sq-report` — ✅ DONE
**Acceptance Criteria (current facts):**
1. `bin/sq-procevent-lavish.sh` executes `sq-report poll` and gates on `command -v sq-report` (register id `lavish` KEPT) — met
2. `COMMON_TOOLS`/`install_cmd`/floor check in `bin/sq-bootstrap.sh` name `sq-report` with the workspace install command (`npm install -g ./packages/sq-report && sq-report setup hooks`) and `LAVISH_AXI_MIN=0.1.0` (reset by PR #16) — met
3. Test fakebins named `lavish-axi` swept → `sq-report` (prose-assertion keep-list exempt) — met

### REQ-SQREPORT-05 (P0) — Turbo integration — ✅ DONE
**Acceptance Criteria (current facts):**
1. `turbo run build|test|lint --filter=sq-report` passes from the root (upstream has no `lint` script; mapped per the design note) — met

## Traceability
REQ-SQREPORT-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03, REQ-M6-04 (floor). **Status: DONE (reviewed 2026-08-13).** Post-delivery deltas: package version and floor reset to 0.1.0 (PR #16); `skills/lavish` kept (product name); THIRD-PARTY-NOTICES trimmed to minimal attribution (PR #24); no legacy `lavish-axi` alias was created (OQ-M6-01 partial).
