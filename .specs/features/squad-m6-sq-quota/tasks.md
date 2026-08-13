# Squad M6 — sq-quota — Tasks

**Base:** spec.md REQ-SQQUOTA-01..05 · design.md (this dir) · umbrella tasks T-M6-U1..U6
**Executor notes:** reference clone at `/tmp/m6-dep-quota-axi` (tag `quota-axi-v0.1.20`); upstream `test` builds first.
**Safety valve:** >5 unexpected steps or new interdependencies → STOP, extend umbrella tasks.md.

> **REVIEWED 2026-08-13 — all tasks DONE** (verified against the live repo; deltas: 0.1.0 baseline PR #16, no legacy quota-axi alias).

## T-SQQUOTA-01 — Vendor at the pin (REQ-SQQUOTA-01) — ✅ DONE
- [x] Shallow clone at tag → copy tracked files into `packages/sq-quota/` (excl. `.git/ node_modules/ dist/`)
- [x] Write `packages/sq-quota/vendor.json`
- [x] **Verificar:** `vendor.json` exists; no `.git` inside; package.json version 0.1.0 (baseline), vendor.json records 0.1.20

## T-SQQUOTA-02 — Name rename (REQ-SQQUOTA-02) — ✅ DONE
- [x] Apply the spec.md rename table: `bin/quota-axi.ts` → `bin/sq-quota.ts`; package.json `name`/`bin`/`files`; `skills/quota-axi` → `skills/sq-quota`; release-please package-name; src name literals
- [x] **Verificar:** `node -e "const p=require('./packages/sq-quota/package.json'); if(p.name!=='sq-quota'||!p.bin['sq-quota']) process.exit(1)"`; `grep -rE '\bquota-axi\b' packages/sq-quota/package.json packages/sq-quota/bin packages/sq-quota/release-please-config.json` → 0 hits

## T-SQQUOTA-03 — Build + test green (REQ-SQQUOTA-03) — ✅ DONE
- [x] `(cd packages/sq-quota && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build && npx -y pnpm@11.1.1 run test)`
- [x] `(cd packages/sq-quota && npm pack --dry-run 2>&1 | grep -E 'sq-quota|dist/bin')`
- [x] **Verificar:** exit 0 both; pack lists `dist/bin/sq-quota.js`; upstream pass set

## T-SQQUOTA-04 — Distro wiring (REQ-SQQUOTA-04, OQ-M6-04 (a)) — ✅ DONE
- [x] `git mv bin/sq-quota-axi-lib.sh bin/sq-quota-lib.sh`; probe `sq-quota`; `SQUAD_QUOTA_AXI_MIN=0.1.0` (reset by PR #16); sources updated (sq-bootstrap.sh source path, sq-test-run.sh lane entry, tests sourcing it)
- [x] `bin/sq-bootstrap.sh`: COMMON_TOOLS entry, `install_cmd` branch (`npm install -g ./packages/sq-quota`), `fm_quota_axi_compatible` operand `sq-quota`
- [x] `bin/sq-vendor-auth-probe.sh`: verified — no executable invocation, prose comment only (deferred keep-list)
- [x] Tests: rename fakebins/fixtures `quota-axi` → `sq-quota` (keep prose-assertion keep-list)
- [x] **Verificar:** `grep -rn '\bquota-axi\b' bin/ tests/` → only documented keep-list hits; `fm_quota_axi_compatible` resolves `sq-quota`; `sq-bootstrap.sh install sq-quota` echoes the workspace command

## T-SQQUOTA-05 — Turbo + guard (REQ-SQQUOTA-05, umbrella T-M6-U6) — ✅ DONE
- [x] `bun x turbo run build|test|lint --filter=sq-quota` from root
- [x] **Verificar:** exit 0; umbrella name-guard includes `packages/sq-quota` and passes
