# Squad M6 — sq-browser (ex chrome-devtools-axi) — Specification

**Scope:** Medium (vendor one TS package + name rename + distro wiring)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/`
**Language:** English (AD-008)

## Problem Statement

`chrome-devtools-axi` (kunchenguid/chrome-devtools-axi, v0.1.29 — "the most agent-ergonomic browser automation") is the browser-automation tool the distro requires at runtime (`COMMON_TOOLS`; operator guidance in `bin/sq-brief.sh` prose, deferred); `sq-bootstrap.sh install_cmd` installs it from the workspace (`packages/sq-browser`). M6 vendored it as `packages/sq-browser` (package `sq-browser`, bin `sq-browser`) with upstream tests green in-workspace.

## Rename Table (single source of truth for this tool)

| Surface | Old (upstream) | New | MUST change | Stay (deferred) |
| --- | --- | --- | --- | --- |
| Package dir | `packages/chrome-devtools-axi` | `packages/sq-browser` | ✅ | — |
| package.json `name` | `chrome-devtools-axi` | `sq-browser` | ✅ | — |
| package.json `bin` | `{"chrome-devtools-axi": "dist/bin/chrome-devtools-axi.js"}` | `{"sq-browser": "dist/bin/sq-browser.js"}` | ✅ | — |
| package.json `files` | `['dist','skills/chrome-devtools-axi','LICENSE','README.md']` | `skills/sq-browser` entry | ✅ | — |
| bin entry sources | `bin/chrome-devtools-axi.ts`, `bin/chrome-devtools-axi-bridge.ts` | `bin/sq-browser.ts`, `bin/sq-browser-bridge.ts` (tsc → `dist/bin/sq-browser*.js`) | ✅ | — |
| Build script literal | `"build": "tsc && chmod +x dist/bin/chrome-devtools-axi.js"` | chmod path → `dist/bin/sq-browser.js` | ✅ | — |
| Packaged skill dir | `skills/chrome-devtools-axi/` | `skills/sq-browser/` (A-M6-01) | ✅ | — |
| release-please `package-name` | `chrome-devtools-axi` | `sq-browser` | ✅ | — |
| src name literals | bridge-script.ts / hooks.ts / skill.ts name refs | follow new names (name-encoding only) | ✅ (names) | prose defers |
| version | 0.1.29 | **0.1.0 (clean-baseline reset, PR #16)** — vendor.json keeps upstream 0.1.29 provenance | — | ✅ |
| engines node>=20, deps (@modelcontextprotocol/sdk, @toon-format/toon, axi-sdk-js), pnpm@11.1.1, `.airlock/lint.sh`, `.release-please-manifest.json`, tsconfig | — | unchanged (manifest `".": "0.1.0"`) | — | ✅ |
| README / CHANGELOG / VISION / help / TOON prose | — | — | — | ✅ (roadmap item) |
| Floor constant | none today (presence-only detection) | keep presence-only (OQ-M6-03) | — | ✅ |

## Requirements

### REQ-SQBROWSER-01 (P0) — Vendored at the pinned tag — ✅ DONE
**Acceptance Criteria (current facts):**
1. `packages/sq-browser/` contains the chrome-devtools-axi v0.1.29 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json` — met (package version 0.1.0 baseline; vendor.json records upstream 0.1.29)
2. `package.json` `version` is 0.1.0 (baseline reset); vendor.json documents the 0.1.29 pin

### REQ-SQBROWSER-02 (P0) — Names renamed — ✅ DONE
**Acceptance Criteria (current facts):**
1. dir/name/bin/files/skill-dir/build-literal/release-please name match the New column — met
2. `grep -rE '\bchrome-devtools-axi\b' packages/sq-browser/package.json packages/sq-browser/bin packages/sq-browser/release-please-config.json` returns 0 hits — met

### REQ-SQBROWSER-03 (P0) — Tests green in-workspace — ✅ DONE
**Acceptance Criteria (current facts):**
1. `pnpm install --frozen-lockfile && pnpm build && pnpm test` in `packages/sq-browser` is green (CI `axi-tools` matrix) — met
2. `npm pack --dry-run` lists `dist/bin/sq-browser.js` — met

### REQ-SQBROWSER-04 (P0) — Distro names `sq-browser` — ✅ DONE
**Acceptance Criteria (current facts):**
1. `COMMON_TOOLS`/`install_cmd` in `bin/sq-bootstrap.sh` name `sq-browser` with the workspace install command (`npm install -g ./packages/sq-browser && sq-browser setup hooks`) — met; presence-only detection kept (no floor)
2. Test fakebins/fixtures named `chrome-devtools-axi` swept → `sq-browser` (prose-assertion keep-list exempt) — met

### REQ-SQBROWSER-05 (P0) — Turbo integration — ✅ DONE
**Acceptance Criteria (current facts):**
1. `turbo run build|test|lint --filter=sq-browser` passes from the root — met

## Traceability
REQ-SQBROWSER-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03. **Status: DONE (reviewed 2026-08-13).** Post-delivery deltas: package version reset to 0.1.0 (PR #16); packaged skill dir now `skills/sq-browser` (PR #25 scrub); no legacy `chrome-devtools-axi` alias was created (OQ-M6-01 partial).
