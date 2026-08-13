# Squad M6 — sq-tasks — Tasks

**Base:** spec.md REQ-SQTASKS-01..05 · design.md (this dir) · umbrella tasks T-M6-U1..U6
**Executor notes:** this is the rename of the M2 fork — never re-import from upstream; work from the local tree with `git mv`.
**Safety valve:** >5 unexpected steps or new interdependencies → STOP, extend umbrella tasks.md.

> **REVIEWED 2026-08-13 — all tasks DONE** (verified against the live repo; delta: `SQUAD_TASKS_AXI_MIN` reset to 0.1.0 by PR #16).

## T-SQTASKS-01 — Fork renamed (REQ-SQTASKS-01) — ✅ DONE
- [x] `git mv packages/tasks-axi packages/sq-tasks`; update `package.json` (name `sq-tasks`, bin map → `dist/bin/sq-tasks.js`, `files` → `skills/sq-tasks`); `git mv bin/sq-tasks-axi.ts bin/sq-tasks.ts`; `git mv skills/tasks-axi skills/sq-tasks`; release-please package-name → `sq-tasks`; src name literals → `sq-tasks`
- [x] Add `packages/sq-tasks/vendor.json` per OQ-M6-06 (a)
- [x] **Verificar:** `ls packages/` has `sq-tasks` and no `tasks-axi`; `node -e "const p=require('./packages/sq-tasks/package.json'); if(p.name!=='sq-tasks'||!p.bin['sq-tasks']) process.exit(1)"`; `grep -rE '\bsq-tasks-axi\b' packages/sq-tasks/package.json packages/sq-tasks/bin` → 0 hits; tracked file count == 77 + vendor.json

## T-SQTASKS-02 — Lib rename + resolver (REQ-SQTASKS-02) — ✅ DONE
- [x] `git mv bin/sq-tasks-axi-lib.sh bin/sq-tasks-lib.sh`; resolver `fm_tasks_axi_cmd` prefers `sq-tasks` → fallback `tasks-axi`; `SQUAD_TASKS_AXI_MIN=0.1.0` (reset by PR #16); header/name references in the lib updated
- [x] Update source paths in: sq-bootstrap.sh, sq-public-followup.sh/-lib/-emit, sq-unit-snapshot.sh, sq-x-poll.sh, sq-backlog-handoff/-receive, sq-decision-hold, sq-remote-doctor, sq-teardown, sq-session-start, sq-test-run
- [x] **Verificar:** `grep -rln 'sq-tasks-axi-lib' bin/ tests/` → 0 hits; `grep -rn 'sq-tasks-lib' bin/` lists all sources; `SQUAD_TASKS_AXI_MIN` is 0.1.0; resolver probe with fake `sq-tasks` on PATH returns `sq-tasks`

## T-SQTASKS-03 — CI renamed (REQ-SQTASKS-03) — ✅ DONE
- [x] `.github/workflows/ci.yml`: job `tasks-axi` → `sq-tasks`; install steps `./packages/sq-tasks`; alias `ln -s "$(command -v sq-tasks)" "$(dirname "$(command -v sq-tasks)")/tasks-axi"`; comments updated
- [x] **Verificar:** `grep -n 'packages/tasks-axi\|sq-tasks-axi' .github/workflows/ci.yml` → 0 hits; `sq-tasks` and `tasks-axi` both resolvable after the install step (smoke)

## T-SQTASKS-04 — Build + tests green (REQ-SQTASKS-04) — ✅ DONE
- [x] `(cd packages/sq-tasks && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build && npx -y pnpm@11.1.1 run test)`
- [x] `(cd packages/sq-tasks && npm pack --dry-run 2>&1 | grep -E 'sq-tasks|dist/bin')`
- [x] **Verificar:** exit 0; pack lists `dist/bin/sq-tasks.js`; vitest ≈ 429 passed / 1 skipped (M2 baseline)

## T-SQTASKS-05 — Distro test sweep + guard (REQ-SQTASKS-05) — ✅ DONE
- [x] Sweep tests referencing `sq-tasks-axi` → `sq-tasks` (name refs; keep prose-assertion keep-list)
- [x] Re-run the M2 gate-unlocked regression batch (sq-decision-hold-lifecycle, sq-public-followup, sq-backend conformance, sq-backend-orca/zellij recon teardowns) with the renamed fork installed — green at delivery
- [x] **Verificar:** `grep -rn '\bsq-tasks-axi\b' tests/ bin/` → only documented keep-list hits; regression batch green; umbrella name-guard passes for `packages/sq-tasks`
