# Squad M6 — sq-browser — Design

**Status:** Ready for Execute (umbrella pattern locked)
**Source:** `kunchenguid/chrome-devtools-axi` tag `chrome-devtools-axi-v0.1.29` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern

1. **Vendor:** shallow clone at the tag → `/tmp/m6-dep-chrome-devtools-axi`; copy tracked files (90 blobs: `bin/` (2 entry files), `src/` (16), `test/` (23 suites), `scripts/build-skill.ts`, `.airlock/lint.sh`, release-please files, `.claude/skills` symlink, tsconfig, LICENSE, docs) into `packages/sq-browser/`; exclude `.git/ node_modules/ dist/`. Preserve the `.claude/skills` symlink if present.
2. **Provenance:** `vendor.json`.
3. **Rename (names only):** per spec.md table. Notable points:
   - TWO bin source files: `bin/chrome-devtools-axi.ts` → `bin/sq-browser.ts` and `bin/chrome-devtools-axi-bridge.ts` → `bin/sq-browser-bridge.ts`; any src reference to the bridge path literal follows (e.g., `src/bridge-script.ts` embedding the bridge file path).
   - Build script chmod literal: `"build": "tsc && chmod +x dist/bin/chrome-devtools-axi.js"` → `dist/bin/sq-browser.js`.
   - `skills/chrome-devtools-axi` → `skills/sq-browser` + `files[]` entry.
   - release-please `package-name` → `sq-browser`; manifest version `0.1.29` kept.
4. **Keep** `@modelcontextprotocol/sdk` dependency (it is the MCP server surface — a dependency, not a name to rename), pnpm@11.1.1, engines node>=20.
5. **Tests:** vitest (~23 suites incl. devtools/emulate/interaction/pages/keychain-isolation). Fix only environment/strictness breaks, documented.

## Distro wiring (umbrella T-M6-U2/U3)

- `bin/sq-bootstrap.sh`: COMMON_TOOLS entry + `install_cmd` (`npm install -g ./packages/sq-browser && sq-browser setup hooks`); presence-only detection (no floor today — OQ-M6-03).
- No bin script shells out to it today (operator guidance lives in `bin/sq-brief.sh` prose → deferred).
- Legacy alias `chrome-devtools-axi` → `sq-browser` per OQ-M6-01 default (a).
- Tests: fakebins/fixtures `chrome-devtools-axi` → `sq-browser` (e.g., harness/on/doctor tests that assert tool presence); prose assertions deferred (keep-list).

## Verification

Per-tool: build+test green, pack dry-run lists `dist/bin/sq-browser.js`, name grep on name-surfaces → 0, turbo `--filter=sq-browser` green, bootstrap MISSING line prints the workspace install for `sq-browser`.
