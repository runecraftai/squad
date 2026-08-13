# Squad M6 — sq-gh (ex gh-axi) — Specification

**Scope:** Medium (vendor one TS package + name rename + distro wiring)
**Prereq:** umbrella `.specs/features/squad-m6-vendoring/` (pattern, floors, guard)
**Language:** English (AD-008)

## Problem Statement

`gh-axi` (kunchenguid/gh-axi, v0.1.30 — "GitHub CLI for agents") is the agent-facing GitHub CLI the distro executes for PR merge/list (`bin/sq-pr-merge.sh`, `bin/sq-teardown.sh`); `sq-bootstrap.sh install_cmd` installs it from the workspace (`packages/sq-gh`). M6 vendored it as `packages/sq-gh` (package `sq-gh`, bin `sq-gh`) with upstream tests green in-workspace and the distro executing the new name.

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
| version | 0.1.30 | **0.1.0 (clean-baseline reset, PR #16)** — vendor.json keeps upstream 0.1.30 provenance | — | ✅ |
| engines / deps / devDeps / packageManager pnpm@11.1.1 | — | unchanged | — | ✅ |
| README / CHANGELOG / VISION / AGENTS.md / help / TOON prose | — | — | — | ✅ (roadmap-futuro-rebrand-completo-de-menco-31) |
| `.airlock/lint.sh`, `.release-please-manifest.json`, tsconfig, eslint | — | unchanged (manifest `".": "0.1.0"`) | — | ✅ |
| Floor constant `GH_AXI_MIN` | name + 0.1.29 | name stays, value **0.1.0** (reset by PR #16; the planned 0.1.30 bump was superseded), operand `sq-gh` | ✅ (operand+value) | constant NAME defers |

## Requirements

### REQ-SQGH-01 (P0) — Vendored at the pinned tag — ✅ DONE
**User Story:** As the team, I want gh-axi source in the monorepo with provenance.

**Acceptance Criteria (current facts):**
1. `packages/sq-gh/` contains the gh-axi v0.1.30 tracked tree (excl. `.git`, `node_modules`, `dist`) with `vendor.json` provenance — met (package version is the 0.1.0 baseline; vendor.json records upstream 0.1.30)
2. `package.json` `version` is 0.1.0 (baseline reset) — vendor.json `version` 0.1.30 documents the upstream pin

### REQ-SQGH-02 (P0) — Names renamed — ✅ DONE
**Acceptance Criteria (current facts):**
1. dir/name/bin/files/skill-dir/release-please name match the New column — met
2. `grep -rE '\bgh-axi\b' packages/sq-gh/package.json packages/sq-gh/bin packages/sq-gh/release-please-config.json` returns 0 hits — met

### REQ-SQGH-03 (P0) — Tests green in-workspace — ✅ DONE
**Acceptance Criteria (current facts):**
1. `pnpm install --frozen-lockfile && pnpm build && pnpm test` in `packages/sq-gh` is green (CI `axi-tools` matrix) — met
2. `npm pack --dry-run` lists `dist/bin/sq-gh.js` — met

### REQ-SQGH-04 (P0) — Distro executes `sq-gh` — ✅ DONE
**Acceptance Criteria (current facts):**
1. `bin/sq-pr-merge.sh` and `bin/sq-teardown.sh` invoke `sq-gh` — met
2. `COMMON_TOOLS`/`install_cmd`/floor check in `bin/sq-bootstrap.sh` name `sq-gh` with the workspace install command and `GH_AXI_MIN=0.1.0` — met (floor value reset by PR #16)
3. Test fakebins named `gh-axi` swept → `sq-gh` (prose-assertion keep-list exempt) — met

### REQ-SQGH-05 (P0) — Turbo integration — ✅ DONE
**Acceptance Criteria (current facts):**
1. `turbo run build|test|lint --filter=sq-gh` passes from the root — met

## Traceability
REQ-SQGH-01..05 ↔ umbrella REQ-M6-01 (AC1–AC4), REQ-M6-03, REQ-M6-04. **Status: DONE (reviewed 2026-08-13).** Post-delivery deltas: package version and floor reset to 0.1.0 (PR #16); packaged skill dir now `skills/sq-gh` (PR #25 scrub); no legacy `gh-axi` alias was created (OQ-M6-01 partial — only `tasks-axi`).
