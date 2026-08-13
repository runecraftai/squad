# Squad M6 — sq-report — Design

**Status:** DELIVERED 2026-08-10; reviewed 2026-08-13 (post-delivery deltas: 0.1.0 baseline reset PR #16, notices trim PR #24, no legacy lavish-axi alias)
**Source:** `kunchenguid/lavish-axi` tag `lavish-axi-v0.1.48` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern (with JS specifics) — ALL DONE

1. **Vendor:** shallow clone at the tag → `/tmp/m6-dep-lavish-axi`; tracked files copied into `packages/sq-report/` (excl. `.git/ node_modules/ dist/`; incl. `lavish-editor-marketing/`, `plugin.json`, `THIRD-PARTY-NOTICES.md`, `skills/`). **Done.** Size delta measured at delivery; no pruning decision (recorded future option, RISK-M6-02).
2. **Provenance:** `vendor.json`. **Done.**
3. **Rename (names only):** per spec.md table — `bin/lavish-axi.js` → `bin/sq-report.js`; `bin` KEY → `sq-report` (output stays `dist/cli.mjs`); release-please `package-name: sq-report`; plugin.json name-encoding fields; src name literals; `skills/lavish` KEPT. **Done.** Package version now 0.1.0 (PR #16); vendor.json retains the 0.1.48 pin.
4. **Keep** pnpm@11.1.1, engines node>=22 (CI node 22 OK), JS toolchain (no tsc; `tsconfig.json` for typecheck in `check`), `THIRD-PARTY-NOTICES.md` (trimmed to minimal required attribution in PR #24). **Done.**
5. **Tests:** `pnpm build && pnpm test` (vitest, ~24 suites) green in-workspace + CI. Browser-tagged suites behaved as upstream. **Done.**
6. **Turbo lint mapping:** upstream has no `lint` script (has `format`/`format:check`); mapped per the verify-at-execute note. **Done.**

## Distro wiring (umbrella T-M6-U2/U3) — ALL DONE

- `bin/sq-bootstrap.sh`: COMMON_TOOLS entry + `install_cmd` branch (`npm install -g ./packages/sq-report && sq-report setup hooks`), floor `tool_version_at_least sq-report "$LAVISH_AXI_MIN"` with `LAVISH_AXI_MIN=0.1.0` (reset by PR #16). **Done.**
- `bin/sq-procevent-lavish.sh`: `command -v sq-report`; `sq-report poll "$real"`; register id `lavish` KEPT (protocol id, deferred). **Done.**
- `bin/sq-procevent-lib.sh` comment mentioning `lavish-axi poll` → prose, deferred (guard keep-list).
- Legacy alias `lavish-axi` → `sq-report` per OQ-M6-01 default (a): **NOT created** (review 2026-08-13) — only the mandatory `tasks-axi` alias exists.
- Tests: fakebins `lavish-axi` → `sq-report` (procevent tests etc.); prose-assertion keep-list exempt. **Done.**

## Verification — DONE

Per-tool: build+test green, pack dry-run lists `dist/cli.mjs` under bin `sq-report`, name grep on name-surfaces → 0, turbo `--filter=sq-report` green (lint mapped), bootstrap MISSING line prints the workspace install for `sq-report`, procevent smoke (`sq-report poll` on a scratch html file) works. Re-verified 2026-08-13 (guard green).
