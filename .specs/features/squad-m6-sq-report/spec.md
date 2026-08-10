# Squad M6 — sq-report (ex lavish-axi) — Specification

**Scope:** Medium (vendor one JS package + name rename + distro wiring)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/`
**Language:** English (AD-008)

## Problem Statement

`lavish-axi` (kunchenguid/lavish-axi, v0.1.48 — "HTML is the new markdown; the editor for your HTML artifacts") powers the procevent feedback loop (`bin/sq-procevent-lavish.sh` executes `lavish-axi poll`) and is a required bootstrap tool gated by `LAVISH_AXI_MIN`. M6 vendors it as `packages/sq-report` (package `sq-report`, bin `sq-report`) with upstream tests green in-workspace. It is the odd one out: plain JavaScript (no tsc), `node>=22`, ~76 MB repo (marketing renders), build via `node scripts/build.js`, and its packaged skill dir is already `skills/lavish` (no `-axi` → KEPT, product name defers).

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
| version | 0.1.48 | 0.1.48 (kept) | — | ✅ |
| engines node>=22, deps (@tailwindcss/browser, axi-sdk-js, chokidar, cross-spawn, daisyui, express, open, parse5), pnpm@11.1.1, scripts (build via node), `.tool-versions`, `.prettierrc`, tsconfig (typecheck only), THIRD-PARTY-NOTICES.md | — | unchanged | — | ✅ |
| README / CHANGELOG / VISION / help prose | — | — | — | ✅ (roadmap item) |
| Floor constant `LAVISH_AXI_MIN` | name + 0.1.46 | name stays, value 0.1.48, operand `sq-report` | ✅ (operand+value) | constant NAME defers |
| Procevent source id `lavish` | — | KEPT (protocol id, deferred) | — | ✅ |

## Requirements

### REQ-SQREPORT-01 (P0) — Vendored at the pinned tag
**Acceptance Criteria:**
1. WHEN `packages/sq-report/` is inspected THEN it SHALL contain the lavish-axi v0.1.48 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json`
2. WHEN `package.json` is read THEN `version` SHALL be 0.1.48 and `bin` SHALL be `{"sq-report": "dist/cli.mjs"}`

### REQ-SQREPORT-02 (P0) — Names renamed
**Acceptance Criteria:**
1. WHEN the rename table is applied THEN dir/name/bin-key/release-please name SHALL match the New column
2. WHEN `grep -rE '\blavish-axi\b' packages/sq-report/package.json packages/sq-report/bin packages/sq-report/release-please-config.json` runs THEN it SHALL return 0 hits

### REQ-SQREPORT-03 (P0) — Tests green in-workspace
**Acceptance Criteria:**
1. WHEN `pnpm install --frozen-lockfile && pnpm build && pnpm test` runs in `packages/sq-report` THEN it SHALL be green (vitest, ~24 JS suites; browser-tagged suites behave as upstream)
2. WHEN `npm pack --dry-run` runs THEN `dist/cli.mjs` SHALL be listed under the `sq-report` bin

### REQ-SQREPORT-04 (P0) — Distro executes `sq-report`
**Acceptance Criteria:**
1. WHEN `bin/sq-procevent-lavish.sh` is read THEN it SHALL execute `sq-report poll` and gate on `command -v sq-report` (register id `lavish` KEPT)
2. WHEN `COMMON_TOOLS`/`install_cmd`/floor check in `bin/sq-bootstrap.sh` are read THEN they SHALL name `sq-report` with the workspace install command (`npm install -g ./packages/sq-report && sq-report setup hooks` — verify the hooks subcommand exists upstream; else drop the second half) and `LAVISH_AXI_MIN=0.1.48`
3. WHEN test fakebins named `lavish-axi` are swept THEN they SHALL use `sq-report` (prose-assertion keep-list exempt)

### REQ-SQREPORT-05 (P0) — Turbo integration
**Acceptance Criteria:**
1. WHEN `turbo run build|test|lint --filter=sq-report` runs from the root THEN it SHALL pass (upstream has no `lint` script — verify and map to `format:check` or skip in the turbo task set)

## Traceability
REQ-SQREPORT-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03, REQ-M6-04 (floor). Success = all five green + umbrella guard.
