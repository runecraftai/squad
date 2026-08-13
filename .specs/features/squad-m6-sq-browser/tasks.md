# Squad M6 — sq-browser — Tasks

**Base:** spec.md REQ-SQBROWSER-01..05 · design.md (this dir) · umbrella tasks T-M6-U1..U6
**Executor notes:** reference clone at `/tmp/m6-dep-chrome-devtools-axi` (tag `chrome-devtools-axi-v0.1.29`).
**Safety valve:** >5 unexpected steps or new interdependencies → STOP, extend umbrella tasks.md.

> **REVIEWED 2026-08-13 — all tasks DONE** (verified against the live repo; deltas: 0.1.0 baseline PR #16, no legacy chrome-devtools-axi alias).

## T-SQBROWSER-01 — Vendor at the pin (REQ-SQBROWSER-01) — ✅ DONE
- [x] Shallow clone at tag → copy tracked files into `packages/sq-browser/` (excl. `.git/ node_modules/ dist/`; preserve symlinks)
- [x] Write `packages/sq-browser/vendor.json`
- [x] **Verificar:** `vendor.json` exists; no `.git` inside; symlinks resolve; package.json version 0.1.0 (baseline), vendor.json records 0.1.29

## T-SQBROWSER-02 — Name rename (REQ-SQBROWSER-02) — ✅ DONE
- [x] Apply the spec.md rename table: both bin entry files, package.json `name`/`bin`/`files`, build-script chmod literal, `skills/chrome-devtools-axi` → `skills/sq-browser`, release-please package-name, src name literals
- [x] **Verificar:** `node -e "const p=require('./packages/sq-browser/package.json'); if(p.name!=='sq-browser'||!p.bin['sq-browser']) process.exit(1)"`; `grep -rE '\bchrome-devtools-axi\b' packages/sq-browser/package.json packages/sq-browser/bin packages/sq-browser/release-please-config.json` → 0 hits

## T-SQBROWSER-03 — Build + test green (REQ-SQBROWSER-03) — ✅ DONE
- [x] `(cd packages/sq-browser && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build && npx -y pnpm@11.1.1 run test)`
- [x] `(cd packages/sq-browser && npm pack --dry-run 2>&1 | grep -E 'sq-browser|dist/bin')`
- [x] **Verificar:** exit 0 both; pack lists `dist/bin/sq-browser.js`; upstream pass set

## T-SQBROWSER-04 — Distro wiring (REQ-SQBROWSER-04) — ✅ DONE
- [x] `bin/sq-bootstrap.sh`: COMMON_TOOLS entry + `install_cmd` branch (`npm install -g ./packages/sq-browser && sq-browser setup hooks`)
- [x] Tests: rename fakebins/fixtures `chrome-devtools-axi` → `sq-browser` (keep prose-assertion keep-list)
- [x] **Verificar:** `grep -rn '\bchrome-devtools-axi\b' bin/ tests/` → only documented keep-list hits; `sq-bootstrap.sh install sq-browser` echoes the workspace command

## T-SQBROWSER-05 — Turbo + guard (REQ-SQBROWSER-05, umbrella T-M6-U6) — ✅ DONE
- [x] `bun x turbo run build|test|lint --filter=sq-browser` from root
- [x] **Verificar:** exit 0; umbrella name-guard includes `packages/sq-browser` and passes
