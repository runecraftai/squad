# Squad M6 — sq-quota — Design

**Status:** Ready for Execute (umbrella pattern locked; OQ-M6-04 default (a) recommended)
**Source:** `kunchenguid/quota-axi` tag `quota-axi-v0.1.20` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern

1. **Vendor:** shallow clone at the tag → `/tmp/m6-dep-quota-axi`; copy tracked files (633 blobs incl. `src/` (19), `test/` (15 suites), `scripts/build-skill.ts` + `scripts/refresh-model-kb.ts`, `.airlock/lint.sh`, release-please files, tsconfig, eslint, LICENSE, docs, skills/) into `packages/sq-quota/`; exclude `.git/ node_modules/ dist/`.
2. **Provenance:** `vendor.json`.
3. **Rename (names only):** per spec.md table. Notable points:
   - `bin/quota-axi.ts` → `bin/sq-quota.ts`; tsc emits `dist/bin/sq-quota.js`.
   - `skills/quota-axi` → `skills/sq-quota` + `files[]`.
   - release-please `package-name` → `sq-quota`; manifest `0.1.20` kept.
   - `src/version.ts` name check + `src/skill.ts` bin refs follow the new name where they encode the NAME.
4. **Keep** pnpm@11.1.1, engines node>=22.19 (CI node 22 OK), deps, `.airlock/`.
5. **Tests:** upstream `test` = `pnpm run build && vitest run` (build-first). ~15 suites (cache/cli/interpretation/models/pace/tui/version-fast-path …). Fix only environment/strictness breaks, documented.

## Distro wiring (umbrella T-M6-U2/U3)

- `bin/sq-quota-axi-lib.sh` → `bin/sq-quota-lib.sh` (OQ-M6-04 default (a)): probe `sq-quota`, `SQUAD_QUOTA_AXI_MIN=0.1.20`; source-path updates in `bin/sq-bootstrap.sh` + the `bin/sq-quota-axi-lib.sh` lane entry in `bin/sq-test-run.sh` (line ~902) + any test sourcing it.
- `bin/sq-bootstrap.sh`: COMMON_TOOLS entry, `install_cmd` branch (`npm install -g ./packages/sq-quota`), `fm_quota_axi_compatible` gate (operand `sq-quota`).
- `bin/sq-vendor-auth-probe.sh`: any `quota-axi` invocation → `sq-quota` (verify at execute; it reads quota data for the dispatch judgment).
- Legacy alias `quota-axi` → `sq-quota` per OQ-M6-01 default (a).
- Tests: fakebins `quota-axi` → `sq-quota` (e.g., `tests/sq-quota-array-dispatch-live-e2e.test.sh`, `tests/sq-vendor-auth-probe.test.sh`, `tests/sq-session-start.test.sh` presence fixtures); prose keep-list exempt.

## Verification

Per-tool: build+test green (build-first), pack dry-run lists `dist/bin/sq-quota.js`, name grep on name-surfaces → 0, turbo `--filter=sq-quota` green, `fm_quota_axi_compatible` probes `sq-quota`, bootstrap MISSING line prints the workspace install.
