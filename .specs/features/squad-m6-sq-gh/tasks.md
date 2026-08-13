# Squad M6 — sq-gh — Tasks

**Base:** spec.md REQ-SQGH-01..05 · design.md (this dir) · umbrella tasks T-M6-U1..U6
**Executor notes:** reference clone at `/tmp/m6-dep-gh-axi` (tag `gh-axi-v0.1.30`); never touch upstream `.git/`; run from `/home/rehem/Projects/squad/` (subshells/absolute paths).
**Safety valve:** >5 unexpected steps or new interdependencies → STOP, extend umbrella tasks.md.

> **REVIEWED 2026-08-13 — all tasks DONE** (verified against the live repo; deltas: 0.1.0 baseline PR #16, no legacy gh-axi alias).

## T-SQGH-01 — Vendor at the pin (REQ-SQGH-01) — ✅ DONE
- [x] Shallow clone `kunchenguid/gh-axi` at tag `gh-axi-v0.1.30` → `/tmp/m6-dep-gh-axi`; copy tracked files into `packages/sq-gh/` (excl. `.git/ node_modules/ dist/`)
- [x] Write `packages/sq-gh/vendor.json` (URL, tag, sha256, date)
- [x] **Verificar:** `vendor.json` exists; no `.git` inside; package.json version is 0.1.0 (baseline reset); vendor.json records upstream 0.1.30

## T-SQGH-02 — Name rename (REQ-SQGH-02) — ✅ DONE
- [x] Apply the spec.md rename table: `bin/gh-axi.ts` → `bin/sq-gh.ts`; package.json `name`/`bin`/`files`; `skills/gh-axi` → `skills/sq-gh`; `release-please-config.json` package-name; src name literals
- [x] **Verificar:** `node -e "const p=require('./packages/sq-gh/package.json'); if(p.name!=='sq-gh'||!p.bin['sq-gh']) process.exit(1)"`; `grep -rE '\bgh-axi\b' packages/sq-gh/package.json packages/sq-gh/bin packages/sq-gh/release-please-config.json` → 0 hits

## T-SQGH-03 — Build + test green (REQ-SQGH-03) — ✅ DONE
- [x] `(cd packages/sq-gh && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build && npx -y pnpm@11.1.1 run test)`
- [x] `(cd packages/sq-gh && npm pack --dry-run 2>&1 | grep -E 'sq-gh|dist/bin')`
- [x] **Verificar:** exit 0 both; pack lists `dist/bin/sq-gh.js`; test output = upstream pass set

## T-SQGH-04 — Distro wiring (REQ-SQGH-04) — ✅ DONE
- [x] `bin/sq-bootstrap.sh`: COMMON_TOOLS entry, `install_cmd` branch (`npm install -g ./packages/sq-gh && sq-gh setup hooks`), floor operand `sq-gh`, `GH_AXI_MIN=0.1.0` (reset by PR #16)
- [x] `bin/sq-pr-merge.sh` + `bin/sq-teardown.sh`: `gh-axi` → `sq-gh` invocations
- [x] Tests: rename fakebin stubs `gh-axi` → `sq-gh` (keep prose-assertion keep-list)
- [x] **Verificar:** `grep -rn '\bgh-axi\b' bin/ tests/` → only documented keep-list hits; `sq-bootstrap.sh install sq-gh` echoes the workspace command

## T-SQGH-05 — Turbo + guard (REQ-SQGH-05, umbrella T-M6-U6) — ✅ DONE
- [x] `bun x turbo run build|test|lint --filter=sq-gh` from root
- [x] **Verificar:** exit 0; umbrella name-guard (tests/sq-m6-name-guard.test.sh) includes `packages/sq-gh` and passes
