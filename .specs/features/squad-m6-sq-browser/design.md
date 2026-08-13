# Squad M6 — sq-browser — Design

**Status:** DELIVERED 2026-08-10; reviewed 2026-08-13 (post-delivery deltas: 0.1.0 baseline reset PR #16, no legacy chrome-devtools-axi alias, skill dir scrubbed PR #25)
**Source:** `kunchenguid/chrome-devtools-axi` tag `chrome-devtools-axi-v0.1.29` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern — ALL DONE

1. **Vendor:** shallow clone at the tag → `/tmp/m6-dep-chrome-devtools-axi`; tracked files copied into `packages/sq-browser/` (excl. `.git/ node_modules/ dist/`; `.claude/skills` symlink preserved). **Done.**
2. **Provenance:** `vendor.json`. **Done.**
3. **Rename (names only):** per spec.md table — TWO bin entry files (`bin/sq-browser.ts`, `bin/sq-browser-bridge.ts`), build-script chmod literal → `dist/bin/sq-browser.js`, `skills/sq-browser` + `files[]`, release-please `package-name: sq-browser`, src name literals. **Done.** Package version now 0.1.0 (PR #16); vendor.json retains the 0.1.29 pin.
4. **Keep** `@modelcontextprotocol/sdk` dependency (MCP server surface), pnpm@11.1.1, engines node>=20. **Done.**
5. **Tests:** vitest (~23 suites incl. devtools/emulate/interaction/pages/keychain-isolation) green in-workspace + CI. **Done.**

## Distro wiring (umbrella T-M6-U2/U3) — ALL DONE

- `bin/sq-bootstrap.sh`: COMMON_TOOLS entry + `install_cmd` (`npm install -g ./packages/sq-browser && sq-browser setup hooks`); presence-only detection (no floor today — OQ-M6-03). **Done.**
- No bin script shells out to it today (operator guidance lives in `bin/sq-brief.sh` prose → deferred).
- Legacy alias `chrome-devtools-axi` → `sq-browser` per OQ-M6-01 default (a): **NOT created** (review 2026-08-13) — only the mandatory `tasks-axi` alias exists.
- Tests: fakebins/fixtures `chrome-devtools-axi` → `sq-browser`; prose assertions deferred (keep-list). **Done.**

## Verification — DONE

Per-tool: build+test green, pack dry-run lists `dist/bin/sq-browser.js`, name grep on name-surfaces → 0, turbo `--filter=sq-browser` green, bootstrap MISSING line prints the workspace install for `sq-browser`. Re-verified 2026-08-13 (guard green).
