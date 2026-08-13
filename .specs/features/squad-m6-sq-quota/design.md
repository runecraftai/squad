# Squad M6 — sq-quota — Design

**Status:** DELIVERED 2026-08-10; reviewed 2026-08-13 (post-delivery deltas: 0.1.0 baseline reset PR #16, no legacy quota-axi alias, skill dir scrubbed PR #25)
**Source:** `kunchenguid/quota-axi` tag `quota-axi-v0.1.20` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern — ALL DONE

1. **Vendor:** shallow clone at the tag → `/tmp/m6-dep-quota-axi`; tracked files copied into `packages/sq-quota/` (excl. `.git/ node_modules/ dist/`). **Done.**
2. **Provenance:** `vendor.json`. **Done.**
3. **Rename (names only):** per spec.md table — `bin/sq-quota.ts`, package.json name/bin/files, `skills/sq-quota`, release-please `package-name: sq-quota`, src name literals. **Done.** Package version now 0.1.0 (PR #16); vendor.json retains the 0.1.20 pin.
4. **Keep** pnpm@11.1.1, engines node>=22.19 (CI node 22 OK), deps, `.airlock/`. **Done.**
5. **Tests:** upstream `test` = `pnpm run build && vitest run` (build-first), ~15 suites, green in-workspace + CI. **Done.**

## Distro wiring (umbrella T-M6-U2/U3) — ALL DONE

- `bin/sq-quota-axi-lib.sh` → `bin/sq-quota-lib.sh` (OQ-M6-04 (a)): probes `sq-quota`, `SQUAD_QUOTA_AXI_MIN=0.1.0`; source-path updates in `bin/sq-bootstrap.sh` + the sq-test-run.sh lane. **Done.**
- `bin/sq-bootstrap.sh`: COMMON_TOOLS entry, `install_cmd` branch (`npm install -g ./packages/sq-quota`), `fm_quota_axi_compatible` gate (operand `sq-quota`). **Done.**
- `bin/sq-vendor-auth-probe.sh`: no executable `quota-axi` invocation — only a prose comment (deferred, guard keep-list). **Verified.**
- Legacy alias `quota-axi` → `sq-quota` per OQ-M6-01 default (a): **NOT created** (review 2026-08-13) — only the mandatory `tasks-axi` alias exists.
- Tests: fakebins `quota-axi` → `sq-quota` (e.g., `tests/sq-quota-array-dispatch-live-e2e.test.sh`, `tests/sq-vendor-auth-probe.test.sh`, `tests/sq-session-start.test.sh` presence fixtures); prose keep-list exempt. **Done.**

## Verification — DONE

Per-tool: build+test green (build-first), pack dry-run lists `dist/bin/sq-quota.js`, name grep on name-surfaces → 0, turbo `--filter=sq-quota` green, `fm_quota_axi_compatible` probes `sq-quota`, bootstrap MISSING line prints the workspace install. Re-verified 2026-08-13 (guard green).
