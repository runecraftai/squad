# Squad M6 — sq-report — Tasks

**Base:** spec.md REQ-SQREPORT-01..05 · design.md (this dir) · umbrella tasks T-M6-U1..U6
**Executor notes:** reference clone at `/tmp/m6-dep-lavish-axi` (tag `lavish-axi-v0.1.48`); JS toolchain (no tsc); node>=22; measure repo-size delta (RISK-M6-02).
**Safety valve:** >5 unexpected steps or new interdependencies → STOP, extend umbrella tasks.md.

## T-SQREPORT-01 — Vendor at the pin (REQ-SQREPORT-01)
- [ ] Shallow clone at tag → copy tracked files into `packages/sq-report/` (excl. `.git/ node_modules/ dist/`; keep `lavish-editor-marketing/`, `plugin.json`, `THIRD-PARTY-NOTICES.md`, `skills/`)
- [ ] Write `packages/sq-report/vendor.json`; record repo-size delta in the task log
- [ ] **Verificar:** `package.json` version == 0.1.48; `vendor.json` exists; no `.git` inside; `git -C /home/rehem/Projects/squad status --porcelain packages/sq-report` = untracked new files only

## T-SQREPORT-02 — Name rename (REQ-SQREPORT-02)
- [ ] Apply the spec.md rename table: `bin/lavish-axi.js` → `bin/sq-report.js`; package.json `name` + `bin` KEY (`{"sq-report": "dist/cli.mjs"}`); release-please package-name; plugin.json name-encoding fields (verify); src name literals (cli.js/plugin.js/skill.js bin refs) where they encode the name; `skills/lavish` KEPT
- [ ] **Verificar:** `node -e "const p=require('./packages/sq-report/package.json'); if(p.name!=='sq-report'||!p.bin['sq-report']) process.exit(1)"`; `grep -rE '\blavish-axi\b' packages/sq-report/package.json packages/sq-report/bin packages/sq-report/release-please-config.json` → 0 hits

## T-SQREPORT-03 — Build + test green (REQ-SQREPORT-03)
- [ ] `(cd packages/sq-report && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build && npx -y pnpm@11.1.1 run test)`
- [ ] `(cd packages/sq-report && npm pack --dry-run 2>&1 | grep -E 'sq-report|dist/cli.mjs')`
- [ ] **Verificar:** exit 0 both; pack lists `dist/cli.mjs` (bin `sq-report`); upstream pass set (fixes documented if any; browser-tagged suites behave as upstream CI)

## T-SQREPORT-04 — Distro wiring (REQ-SQREPORT-04)
- [ ] `bin/sq-bootstrap.sh`: COMMON_TOOLS entry + `install_cmd` branch (`npm install -g ./packages/sq-report` + `sq-report setup hooks` only if the subcommand exists — verify), floor operand `sq-report`, `LAVISH_AXI_MIN=0.1.48`
- [ ] `bin/sq-procevent-lavish.sh`: `command -v sq-report`, `sq-report poll` (register id `lavish` KEPT)
- [ ] Tests: rename fakebins/fixtures `lavish-axi` → `sq-report` (keep prose-assertion keep-list)
- [ ] **Verificar:** `grep -rn '\blavish-axi\b' bin/ tests/` → only documented keep-list hits; `sq-bootstrap.sh install sq-report` echoes the workspace command; procevent smoke works against a scratch html file

## T-SQREPORT-05 — Turbo + guard (REQ-SQREPORT-05, umbrella T-M6-U6)
- [ ] Map turbo lint for this package (upstream has no `lint` script; use `format:check` or declare none) in `packages/sq-report/package.json` scripts — verify at execute
- [ ] `bun x turbo run build|test|lint --filter=sq-report` from root
- [ ] **Verificar:** exit 0; umbrella name-guard includes `packages/sq-report` and passes
