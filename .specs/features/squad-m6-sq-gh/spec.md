# Squad M6 — sq-gh (ex gh-axi) — Specification

**Scope:** Medium (vendor one TS package + name rename + distro wiring)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/` (pattern, floors, guard)
**Language:** English (AD-008)

## Problem Statement

`gh-axi` (kunchenguid/gh-axi, v0.1.30 — "GitHub CLI for agents") is the agent-facing GitHub CLI the distro executes for PR merge/list (`bin/sq-pr-merge.sh`, `bin/sq-teardown.sh`) and installs from upstream npm (`sq-bootstrap.sh install_cmd`). M6 vendors it as `packages/sq-gh` (package `sq-gh`, bin `sq-gh`) with upstream tests green in-workspace and the distro executing the new name.

## Rename Table (single source of truth for this tool)

| Surface | Old (upstream) | New | MUST change | Stay (deferred) |
| --- | --- | --- | --- | --- |
| Package dir | `packages/gh-axi` | `packages/sq-gh` | ✅ | — |
| package.json `name` | `gh-axi` | `sq-gh` | ✅ | — |
| package.json `bin` | `{"gh-axi": "./dist/bin/gh-axi.js"}` | `{"sq-gh": "./dist/bin/sq-gh.js"}` | ✅ | — |
| package.json `files` | `['dist','skills/gh-axi','LICENSE','README.md']` | `skills/sq-gh` entry | ✅ | — |
| bin entry source | `bin/gh-axi.ts` | `bin/sq-gh.ts` (tsc output → `dist/bin/sq-gh.js`) | ✅ | — |
| Packaged skill dir | `skills/gh-axi/` | `skills/sq-gh/` (A-M6-01; content prose defers) | ✅ | — |
| release-please `package-name` | `gh-axi` | `sq-gh` | ✅ | — |
| src name literals | `version.ts` name check / `skill.ts` / fixtures referencing the tool name | follow new name | ✅ (where they encode the NAME) | prose defers |
| version | 0.1.30 | 0.1.30 (kept) | — | ✅ |
| engines / deps / devDeps / packageManager pnpm@11.1.1 | — | unchanged | — | ✅ |
| README / CHANGELOG / VISION / AGENTS.md / help / TOON prose | — | — | — | ✅ (roadmap-futuro-rebrand-completo-de-menco-31) |
| `.airlock/lint.sh`, `.release-please-manifest.json`, tsconfig, eslint | — | unchanged | — | ✅ |
| Floor constant `GH_AXI_MIN` | name + 0.1.29 | name stays, value 0.1.30, operand `sq-gh` | ✅ (operand+value) | constant NAME defers |

## Requirements

### REQ-SQGH-01 (P0) — Vendored at the pinned tag
**User Story:** As the team, I want gh-axi source in the monorepo with provenance.

**Acceptance Criteria:**
1. WHEN `packages/sq-gh/` is inspected THEN it SHALL contain the gh-axi v0.1.30 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json` provenance
2. WHEN `package.json` is read THEN `version` SHALL be 0.1.30

### REQ-SQGH-02 (P0) — Names renamed
**Acceptance Criteria:**
1. WHEN the rename table is applied THEN dir/name/bin/files/skill-dir/release-please name SHALL match the New column
2. WHEN `grep -rE '\bgh-axi\b' packages/sq-gh/package.json packages/sq-gh/bin packages/sq-gh/release-please-config.json` runs THEN it SHALL return 0 hits

### REQ-SQGH-03 (P0) — Tests green in-workspace
**Acceptance Criteria:**
1. WHEN `pnpm install --frozen-lockfile && pnpm build && pnpm test` runs in `packages/sq-gh` THEN it SHALL be green (upstream suite; fixes only for environment/strictness, documented)
2. WHEN `npm pack --dry-run` runs THEN `dist/bin/sq-gh.js` SHALL be listed

### REQ-SQGH-04 (P0) — Distro executes `sq-gh`
**Acceptance Criteria:**
1. WHEN `bin/sq-pr-merge.sh` and `bin/sq-teardown.sh` are read THEN they SHALL invoke `sq-gh`
2. WHEN `COMMON_TOOLS`/`install_cmd`/floor check in `bin/sq-bootstrap.sh` are read THEN they SHALL name `sq-gh` with the workspace install command and `GH_AXI_MIN=0.1.30`
3. WHEN test fakebins named `gh-axi` are swept THEN they SHALL be renamed to `sq-gh` (prose-assertion keep-list exempt)

### REQ-SQGH-05 (P0) — Turbo integration
**Acceptance Criteria:**
1. WHEN `turbo run build|test|lint --filter=sq-gh` runs from the root THEN it SHALL pass

## Traceability
REQ-SQGH-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03, REQ-M6-04. Success = all five green + umbrella guard.
