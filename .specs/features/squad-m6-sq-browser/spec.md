# Squad M6 — sq-browser (ex chrome-devtools-axi) — Specification

**Scope:** Medium (vendor one TS package + name rename + distro wiring)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/`
**Language:** English (AD-008)

## Problem Statement

`chrome-devtools-axi` (kunchenguid/chrome-devtools-axi, v0.1.29 — "the most agent-ergonomic browser automation") is the browser-automation tool the distro requires at runtime (`COMMON_TOOLS`; operator guidance in `bin/sq-brief.sh` prose, deferred) and installs from upstream npm (`sq-bootstrap.sh install_cmd`). M6 vendors it as `packages/sq-browser` (package `sq-browser`, bin `sq-browser`) with upstream tests green in-workspace.

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
| version | 0.1.29 | 0.1.29 (kept) | — | ✅ |
| engines node>=20, deps (@modelcontextprotocol/sdk, @toon-format/toon, axi-sdk-js), pnpm@11.1.1, `.airlock/lint.sh`, `.release-please-manifest.json`, tsconfig | — | unchanged | — | ✅ |
| README / CHANGELOG / VISION / help / TOON prose | — | — | — | ✅ (roadmap item) |
| Floor constant | none today (presence-only detection) | keep presence-only (OQ-M6-03) | — | ✅ |

## Requirements

### REQ-SQBROWSER-01 (P0) — Vendored at the pinned tag
**Acceptance Criteria:**
1. WHEN `packages/sq-browser/` is inspected THEN it SHALL contain the chrome-devtools-axi v0.1.29 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json`
2. WHEN `package.json` is read THEN `version` SHALL be 0.1.29

### REQ-SQBROWSER-02 (P0) — Names renamed
**Acceptance Criteria:**
1. WHEN the rename table is applied THEN dir/name/bin/files/skill-dir/build-literal/release-please name SHALL match the New column
2. WHEN `grep -rE '\bchrome-devtools-axi\b' packages/sq-browser/package.json packages/sq-browser/bin packages/sq-browser/release-please-config.json` runs THEN it SHALL return 0 hits

### REQ-SQBROWSER-03 (P0) — Tests green in-workspace
**Acceptance Criteria:**
1. WHEN `pnpm install --frozen-lockfile && pnpm build && pnpm test` runs in `packages/sq-browser` THEN it SHALL be green (fixes only for environment/strictness, documented)
2. WHEN `npm pack --dry-run` runs THEN `dist/bin/sq-browser.js` SHALL be listed

### REQ-SQBROWSER-04 (P0) — Distro names `sq-browser`
**Acceptance Criteria:**
1. WHEN `COMMON_TOOLS`/`install_cmd` in `bin/sq-bootstrap.sh` are read THEN they SHALL name `sq-browser` with the workspace install command (`npm install -g ./packages/sq-browser && sq-browser setup hooks`)
2. WHEN test fakebins/fixtures named `chrome-devtools-axi` are swept THEN they SHALL use `sq-browser` (prose-assertion keep-list exempt)

### REQ-SQBROWSER-05 (P0) — Turbo integration
**Acceptance Criteria:**
1. WHEN `turbo run build|test|lint --filter=sq-browser` runs from the root THEN it SHALL pass

## Traceability
REQ-SQBROWSER-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03. Success = all five green + umbrella guard.
