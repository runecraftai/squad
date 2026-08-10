# Squad M6 — Vendoring the AXI Toolchain — Tasks

**Base:** umbrella spec.md REQ-M6-01..07 · design.md §1–§11 · context.md CD-M6-01..06, OQ-M6-01..06 (defaults recommended) · per-tool specs/tasks
**Executor notes:** never write to the upstream reference clones; run everything in `/home/rehem/Projects/squad/`; the ONLY pre-existing working-tree change is the pr-review fix — do not touch it until T-M6-U5; resolve OQ-M6-01..06 with the recommended default and record the pick in context.md, do not block. Reference clones at `/tmp/m6-dep-*` (fresh shallow clones at the pinned tags; delete nothing from /tmp).
**Safety valve:** if any task reveals >5 unexpected steps or new interdependencies, STOP and extend this file (Tasks phase re-entry).

---

## Phase 0 — Ordering

```
T-M6-U1 (workspace + provenance scaffold)
   ├── T-SQGH-01..05, T-SQBROWSER-01..05, T-SQQUOTA-01..05, T-SQREPORT-01..05   (parallel, per-tool)
   ├── T-SQTASKS-01..06   (rename of the vendored fork — serial with the above only via U2/U3)
T-M6-U2 (bootstrap wiring) ← needs all tool renames + resolver renames
T-M6-U3 (distro call-site + test sweep) ← needs U2
T-M6-U4 (CI additions) ← needs U2/U3
T-M6-U5 (pr-review fix)  — independent, may run first
T-M6-U6 (guard + full verification) ← everything
T-M6-U7 (ROADMAP/STATE records)
```

---

## T-M6-U1 — Workspace registration + provenance scaffold (REQ-M6-01 AC1/AC4)

- [ ] Add the 4 new package dirs (per-tool tasks create them); verify root `bun install` tolerates the 5 nested `pnpm-lock.yaml` files (sq-tasks + 4 new) — adjust exclusion if needed (T-M2-04 precedent)
- [ ] Write `vendor.json` per new package (source URL, pinned tag, sha256 of package.json + source tree, extraction date) — M3/M5 pattern; add one for `packages/sq-tasks` during the rename (OQ-M6-06 default (a))
- [ ] **Verificar:** `bun install` at root exits 0; each new package has `vendor.json`; `turbo run build --filter=<pkg>` per new package exits 0

## T-M6-U2 — Bootstrap wiring (REQ-M6-03, REQ-M6-04)

- [ ] `bin/sq-bootstrap.sh`: `COMMON_TOOLS` → `node git gh no-mistakes sq-gh sq-browser sq-report sq-quota sq-tasks`; `install_cmd` branches → workspace-local installs per design.md §3 (OQ-M6-02 default (a)); floor checks probe the new bins; `GH_AXI_MIN=0.1.30`, `LAVISH_AXI_MIN=0.1.48`; source path `. "$SCRIPT_DIR/sq-quota-axi-lib.sh"` (or renamed lib per OQ-M6-04)
- [ ] `bin/sq-quota-axi-lib.sh`: `SQUAD_QUOTA_AXI_MIN=0.1.20`; probe `sq-quota` (filename per OQ-M6-04 default (a))
- [ ] `bin/sq-tasks-lib.sh` (renamed from sq-tasks-axi-lib.sh): resolver `fm_tasks_axi_cmd` prefers `sq-tasks` → `tasks-axi`; `SQUAD_TASKS_AXI_MIN=0.2.4` unchanged; update all sourcing files (sq-bootstrap.sh, sq-public-followup.sh/-lib/-emit, sq-unit-snapshot.sh, sq-x-poll.sh)
- [ ] Legacy aliases per OQ-M6-01 default (a) wired into `install_cmd` output + CI (T-M6-U4)
- [ ] **Verificar:** `sq-bootstrap.sh` in a throwaway `SQUAD_HOME` prints correct `MISSING:` lines with workspace install commands for each renamed tool and no upstream npm URLs; `tool_version_at_least` / `fm_*_compatible` probes resolve against `sq-*` names

## T-M6-U3 — Distro call-site + test sweep (REQ-M6-01 AC5, REQ-M6-02)

- [ ] Apply design.md §7 table: `bin/sq-pr-merge.sh` (`sq-gh pr merge`), `bin/sq-teardown.sh` (`sq-gh pr list`), `bin/sq-procevent-lavish.sh` (`sq-report poll`; `command -v sq-report`), `bin/sq-vendor-auth-probe.sh` (quota-axi invocation → `sq-quota`), lib file renames + source-path updates, `.github/workflows/ci.yml` (T-M6-U4), `docs/scripts.md` file-path refs
- [ ] `tests/`: fakebin stubs + fixtures named `gh-axi|chrome-devtools-axi|lavish-axi|quota-axi|sq-tasks-axi` → new names; KEEP prose-assertion files per the guard keep-list (RISK-M6-05)
- [ ] **Verificar:** per-tool name-surface greps (per-tool tasks) pass; deferred prose files untouched (`git diff --stat` on `bin/sq-brief.sh`, `AGENTS.md`, `docs/` = 0 lines except documented file-path refs)

## T-M6-U4 — CI additions (REQ-M6-05)

- [ ] New matrix job `axi-tools` (pkg ∈ {sq-gh, sq-browser, sq-quota, sq-report}): pnpm 11.1.1 + node 22 + `pnpm install --frozen-lockfile` + build + test + `npm pack --dry-run` grep of the new bin
- [ ] Rename the `tasks-axi` CI job → `sq-tasks` (path `packages/sq-tasks`, `sq-tasks --version`, alias `tasks-axi` → `sq-tasks`); update the 3 test-lane install steps (path + alias `ln -s "$(command -v sq-tasks)" "$(dirname "$(command -v sq-tasks)")/tasks-axi"`)
- [ ] **Verificar:** YAML parses; `grep -n 'packages/tasks-axi\|sq-tasks-axi' .github/workflows/ci.yml` → 0 hits; job matrix names match design.md §6

## T-M6-U5 — pr-review fix ships (REQ-M6-06)

- [ ] Commit the unlanded `packages/pr-review/extensions/pr-review-subagent.ts` fix (single Object schema + runtime required-field validation) as a normal M6 commit — no edits to the fix itself
- [ ] Recommended: add a small regression test (schema form has `"type":"object"`; `action=run` missing required fields → clear missing-fields error)
- [ ] **Verificar:** `bun test` in `packages/pr-review` green (252 upstream); headless Pi load smoke registers `pr_review_verify`; one spawn exercise (list + run-missing-fields) shows no "Invalid schema for function 'pr_review_verify'"

## T-M6-U6 — M6 name guard + full verification (REQ-M6-01 AC5, success criteria)

- [ ] Write `tests/sq-m6-name-guard.test.sh` per design.md §10 (name-surfaces → 0 hits; documented keep-list for deferred prose; `.specs/` exempt)
- [ ] Full gates: `bin/sq-lint.sh`, `sq-test-run.sh --check-coverage`, `turbo run build|test|lint` (all packages incl. the 4 new + sq-tasks), per-fork suites
- [ ] **Verificar:** guard green; turbo green; `--check-coverage` exit 0; `ls packages/` shows `sq-gh sq-browser sq-quota sq-report sq-tasks` and no `tasks-axi` dir

## T-M6-U7 — ROADMAP/STATE records (REQ-M6-07)

- [ ] ROADMAP.md: M6 milestone section (goal, exit criteria, work packages) + deferred-rebrand pointer to roadmap-futuro-rebrand-completo-de-menco-31; update Current-Milestone header + dependency chain (M0→M1→{M2,M3}→M4 · M5∥M4 → M6)
- [ ] STATE.md: M6 planning records only (Progress row, naming table, OQ-M6-01..06 resolutions, risks) — never alter M0–M5 records
- [ ] **Verificar:** ROADMAP grep has the rebrand-item pointer; STATE M6 section present; `git diff` on ROADMAP/STATE touches only the M6 additions

## Final Acceptance (M6)

- [ ] All seven tools under Squad names; old names absent from name-surfaces (guard)
- [ ] Each fork's upstream suite green in-workspace; turbo build/test/lint green
- [ ] Bootstrap installs the whole toolchain from the workspace; floors gate the forks
- [ ] CI matrix extended (axi-tools) + tasks-axi job renamed sq-tasks
- [ ] pr-review fix committed + verified; sync procedure + rebrand pointer recorded
