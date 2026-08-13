# Squad M6 — sq-report — Tasks

**Base:** spec.md REQ-SQREPORT-01..05 · design.md (this dir) · umbrella tasks T-M6-U1..U6
**Executor notes:** reference clone at `/tmp/m6-dep-lavish-axi` (tag `lavish-axi-v0.1.48`); JS toolchain (no tsc); node>=22; measure repo-size delta (RISK-M6-02).
**Safety valve:** >5 unexpected steps or new interdependencies → STOP, extend umbrella tasks.md.

> **REVIEWED 2026-08-13 — all tasks DONE** (verified against the live repo; deltas: 0.1.0 baseline PR #16, notices trim PR #24, no legacy lavish-axi alias).

## T-SQREPORT-01 — Vendor at the pin (REQ-SQREPORT-01) — ✅ DONE
- [x] Shallow clone at tag → copy tracked files into `packages/sq-report/` (excl. `.git/ node_modules/ dist/`; keep `lavish-editor-marketing/`, `plugin.json`, `THIRD-PARTY-NOTICES.md`, `skills/`)
- [x] Write `packages/sq-report/vendor.json`; record repo-size delta in the task log
- [x] **Verificar:** `vendor.json` exists; no `.git` inside; package.json version 0.1.0 (baseline), vendor.json records 0.1.48

## T-SQREPORT-02 — Name rename (REQ-SQREPORT-02) — ✅ DONE
- [x] Apply the spec.md rename table: `bin/lavish-axi.js` → `bin/sq-report.js`; package.json `name` + `bin` KEY (`{"sq-report": "dist/cli.mjs"}`); release-please package-name; plugin.json name-encoding fields (verified); src name literals; `skills/lavish` KEPT
- [x] **Verificar:** `node -e "const p=require('./packages/sq-report/package.json'); if(p.name!=='sq-report'||!p.bin['sq-report']) process.exit(1)"`; `grep -rE '\blavish-axi\b' packages/sq-report/package.json packages/sq-report/bin packages/sq-report/release-please-config.json` → 0 hits

## T-SQREPORT-03 — Build + test green (REQ-SQREPORT-03) — ✅ DONE
- [x] `(cd packages/sq-report && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build && npx -y pnpm@11.1.1 run test)`
- [x] `(cd packages/sq-report && npm pack --dry-run 2>&1 | grep -E 'sq-report|dist/cli.mjs')`
- [x] **Verificar:** exit 0 both; pack lists `dist/cli.mjs` (bin `sq-report`); upstream pass set; browser-tagged suites behave as upstream CI

## T-SQREPORT-04 — Distro wiring (REQ-SQREPORT-04) — ✅ DONE
- [x] `bin/sq-bootstrap.sh`: COMMON_TOOLS entry + `install_cmd` branch (`npm install -g ./packages/sq-report` + `sq-report setup hooks` — subcommand verified), floor operand `sq-report`, `LAVISH_AXI_MIN=0.1.0` (reset by PR #16)
- [x] `bin/sq-procevent-lavish.sh`: `command -v sq-report`, `sq-report poll` (register id `lavish` KEPT)
- [x] Tests: rename fakebins/fixtures `lavish-axi` → `sq-report` (keep prose-assertion keep-list)
- [x] **Verificar:** `grep -rn '\blavish-axi\b' bin/ tests/` → only documented keep-list hits; `sq-bootstrap.sh install sq-report` echoes the workspace command; procevent smoke works against a scratch html file

## T-SQREPORT-05 — Turbo + guard (REQ-SQREPORT-05, umbrella T-M6-U6) — ✅ DONE
- [x] Map turbo lint for this package (upstream has no `lint` script; `format:check` mapping verified at execute)
- [x] `bun x turbo run build|test|lint --filter=sq-report` from root
- [x] **Verificar:** exit 0; umbrella name-guard includes `packages/sq-report` and passes
