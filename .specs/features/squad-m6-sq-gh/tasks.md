# Squad M6 — sq-gh — Tasks

**Base:** spec.md REQ-SQGH-01..05 · design.md (this dir) · umbrella tasks T-M6-U1..U6
**Executor notes:** reference clone at `/tmp/m6-dep-gh-axi` (tag `gh-axi-v0.1.30`); never touch upstream `.git/`; run from `/home/rehem/Projects/squad/` (subshells/absolute paths).
**Safety valve:** >5 unexpected steps or new interdependencies → STOP, extend umbrella tasks.md.

## T-SQGH-01 — Vendor at the pin (REQ-SQGH-01)
- [ ] Shallow clone `kunchenguid/gh-axi` at tag `gh-axi-v0.1.30` → `/tmp/m6-dep-gh-axi`; copy tracked files into `packages/sq-gh/` (excl. `.git/ node_modules/ dist/`; keep `.airlock/`, release-please files, skills/, LICENSE)
- [ ] Write `packages/sq-gh/vendor.json` (URL, tag, sha256, date)
- [ ] **Verificar:** `git -C /home/rehem/Projects/squad status --porcelain packages/sq-gh` shows only untracked new files; `vendor.json` exists; `package.json` version == 0.1.30; no `.git` inside

## T-SQGH-02 — Name rename (REQ-SQGH-02)
- [ ] Apply the spec.md rename table: `bin/gh-axi.ts` → `bin/sq-gh.ts`; package.json `name`/`bin`/`files`; `skills/gh-axi` → `skills/sq-gh`; `release-please-config.json` package-name; src name literals (version.ts name check, skill.ts, fixtures where they encode the name)
- [ ] **Verificar:** `node -e "const p=require('./packages/sq-gh/package.json'); if(p.name!=='sq-gh'||!p.bin['sq-gh']) process.exit(1)"` (run from repo root); `grep -rE '\bgh-axi\b' packages/sq-gh/package.json packages/sq-gh/bin packages/sq-gh/release-please-config.json` → 0 hits

## T-SQGH-03 — Build + test green (REQ-SQGH-03)
- [ ] `(cd packages/sq-gh && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build && npx -y pnpm@11.1.1 run test)`
- [ ] `(cd packages/sq-gh && npm pack --dry-run 2>&1 | grep -E 'sq-gh|dist/bin')`
- [ ] **Verificar:** exit 0 both; pack lists `dist/bin/sq-gh.js`; test output = upstream pass set (fixes documented if any)

## T-SQGH-04 — Distro wiring (REQ-SQGH-04)
- [ ] `bin/sq-bootstrap.sh`: COMMON_TOOLS entry, `install_cmd` branch (`npm install -g ./packages/sq-gh && sq-gh setup hooks`), floor operand `sq-gh`, `GH_AXI_MIN=0.1.30`
- [ ] `bin/sq-pr-merge.sh` + `bin/sq-teardown.sh`: `gh-axi` → `sq-gh` invocations
- [ ] Tests: rename fakebin stubs `gh-axi` → `sq-gh` (keep prose-assertion keep-list)
- [ ] **Verificar:** `grep -rn '\bgh-axi\b' bin/ tests/` → only documented keep-list hits; `sq-bootstrap.sh install sq-gh` echoes the workspace command

## T-SQGH-05 — Turbo + guard (REQ-SQGH-05, umbrella T-M6-U6)
- [ ] `bun x turbo run build|test|lint --filter=sq-gh` from root
- [ ] **Verificar:** exit 0; umbrella name-guard (tests/sq-m6-name-guard.test.sh) includes `packages/sq-gh` and passes
