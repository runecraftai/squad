# Squad M6 — Vendoring the AXI Toolchain — Tasks

**Base:** umbrella spec.md REQ-M6-01..07 · design.md §1–§11 · context.md CD-M6-01..06, OQ-M6-01..06 (defaults recommended) · per-tool specs/tasks
**Executor notes:** never write to the upstream reference clones; run everything in `/home/rehem/Projects/squad/`; the ONLY pre-existing working-tree change was the pr-review fix — do not touch it until T-M6-U5; resolve OQ-M6-01..06 with the recommended default and record the pick in context.md, do not block. Reference clones at `/tmp/m6-dep-*` (fresh shallow clones at the pinned tags; delete nothing from /tmp).
**Safety valve:** if any task reveals >5 unexpected steps or new interdependencies, STOP and extend this file (Tasks phase re-entry).

> **REVIEWED 2026-08-13 — all tasks DONE.** Every T-* item below is checked and verified against the live repo; post-delivery corrections (0.1.0 baseline reset PR #16, no-mistakes→drill PR #8, goal-loop-audit cut, skills scrub PR #25) are recorded in context.md and reflected in the per-task notes. No re-scoping needed — nothing remains open in M6 itself; the deferred-rebrand backlog item owns the leftover prose/floor notes.

---

## Phase 0 — Ordering

```
T-M6-U1 (workspace + provenance scaffold) ✓
   ├── T-SQGH-01..05, T-SQBROWSER-01..05, T-SQQUOTA-01..05, T-SQREPORT-01..05   ✓ (parallel, per-tool)
   ├── T-SQTASKS-01..06   ✓ (rename of the vendored fork)
T-M6-U2 (bootstrap wiring) ✓
T-M6-U3 (distro call-site + test sweep) ✓
T-M6-U4 (CI additions) ✓
T-M6-U5 (pr-review fix) ✓
T-M6-U6 (guard + full verification) ✓
T-M6-U7 (ROADMAP/STATE records) ✓
```

---

## T-M6-U1 — Workspace registration + provenance scaffold (REQ-M6-01 AC1/AC4) — ✅ DONE

- [x] Add the 4 new package dirs (per-tool tasks create them); root `bun install` tolerates the nested `pnpm-lock.yaml` files
- [x] `vendor.json` per new package; one added for `packages/sq-tasks` during the rename (OQ-M6-06 (a))
- [x] **Verificado:** `bun install` at root exits 0; each new package has `vendor.json`; `turbo run build --filter=<pkg>` per new package exits 0
- **Review note (2026-08-13):** packages now carry the 0.1.0 clean-baseline version (PR #16); `vendor.json` retains the upstream pinned versions.

## T-M6-U2 — Bootstrap wiring (REQ-M6-03, REQ-M6-04) — ✅ DONE

- [x] `bin/sq-bootstrap.sh`: `COMMON_TOOLS` → `node git gh drill sq-gh sq-browser sq-report sq-quota sq-tasks` (drill replaced no-mistakes post-M6, PR #8); `install_cmd` branches → workspace-local installs per design.md §3 (OQ-M6-02 (a)); floor checks probe the new bins; `GH_AXI_MIN=0.1.0`, `LAVISH_AXI_MIN=0.1.0` (reset by PR #16)
- [x] `bin/sq-quota-lib.sh` (renamed from sq-quota-axi-lib.sh per OQ-M6-04 (a)): `SQUAD_QUOTA_AXI_MIN=0.1.0`; probes `sq-quota`
- [x] `bin/sq-tasks-lib.sh` (renamed from sq-tasks-axi-lib.sh): resolver `fm_tasks_axi_cmd` prefers `sq-tasks` → `tasks-axi`; `SQUAD_TASKS_AXI_MIN=0.1.0` (reset by PR #16); all sourcing files updated
- [x] Legacy alias: only the mandatory `tasks-axi` → `sq-tasks` implemented (OQ-M6-01 — optional aliases for the other four were not created)
- [x] **Verificar:** `sq-bootstrap.sh` in a throwaway `SQUAD_HOME` prints correct `MISSING:` lines with workspace install commands for each renamed tool and no upstream npm URLs; `tool_version_at_least` / `fm_*_compatible` probes resolve against `sq-*` names

## T-M6-U3 — Distro call-site + test sweep (REQ-M6-01 AC5, REQ-M6-02) — ✅ DONE

- [x] Apply design.md §7 table: `bin/sq-pr-merge.sh` (`sq-gh pr merge`), `bin/sq-teardown.sh` (`sq-gh pr list`), `bin/sq-procevent-lavish.sh` (`sq-report poll`; `command -v sq-report`), lib file renames + source-path updates, `.github/workflows/ci.yml` (T-M6-U4), `docs/scripts.md` file-path refs
- [x] `tests/`: fakebin stubs + fixtures renamed to `sq-*`; prose-assertion files kept per the guard keep-list
- [x] **Verificar:** per-tool name-surface greps pass; deferred prose files untouched except documented file-path refs

## T-M6-U4 — CI additions (REQ-M6-05) — ✅ DONE

- [x] New matrix job `axi-tools` (pkg ∈ {sq-gh, sq-browser, sq-quota, sq-report}): pnpm 11.1.1 + node 22 + `pnpm install --frozen-lockfile` + build + test + `npm pack --dry-run` grep of the new bin
- [x] Rename the `tasks-axi` CI job → `sq-tasks` (path `packages/sq-tasks`, `sq-tasks --version`, alias `tasks-axi` → `sq-tasks`); the 3 test-lane install steps updated
- [x] **Verificar:** YAML parses; `grep -n 'packages/tasks-axi\|sq-tasks-axi' .github/workflows/ci.yml` → 0 hits; job matrix names match design.md §6

## T-M6-U5 — pr-review fix ships (REQ-M6-06) — ✅ DONE

- [x] Commit the unlanded `packages/pr-review/extensions/pr-review-subagent.ts` fix (single Object schema + runtime required-field validation) as a normal M6 commit — committed
- [x] Regression test added (schema form has `"type":"object"`; `action=run` missing required fields → clear missing-fields error) — present and green
- [x] **Verificar:** `bun test` in `packages/pr-review` — 250 pass / 2 fail (the two failures are README-content assertions drifted by the PR #11 README beautification, unrelated to the schema fix; the fix's own regression test passes); headless Pi load smoke registers `pr_review_verify`; spawn exercise shows no "Invalid schema for function 'pr_review_verify'"
- **Review note (2026-08-13):** pr-review was re-classified "maintained" (PR #16) — no vendor.json, version 0.1.0, docs/pr-review.md updated.

## T-M6-U6 — M6 name guard + full verification (REQ-M6-01 AC5, success criteria) — ✅ DONE

- [x] `tests/sq-m6-name-guard.test.sh` per design.md §10 (name-surfaces → 0 hits; documented keep-list for deferred prose; `.specs/` exempt) — committed, green (re-verified 2026-08-13)
- [x] Full gates: `bin/sq-lint.sh`, `sq-test-run.sh --check-coverage`, `turbo run build|test|lint`, per-fork suites — green at delivery; guard re-run green 2026-08-13
- [x] **Verificar:** guard green; turbo green; `--check-coverage` exit 0; `ls packages/` shows `sq-gh sq-browser sq-quota sq-report sq-tasks` and no `tasks-axi` dir — confirmed (plus `drill fob pr-review`; no `no-mistakes`/`goal-loop-audit`)

## T-M6-U7 — ROADMAP/STATE records (REQ-M6-07) — ✅ DONE

- [x] ROADMAP.md: M6 milestone section (goal, exit criteria, work packages) + deferred-rebrand pointer to roadmap-futuro-rebrand-completo-de-menco-31; Current-Milestone header + dependency chain updated
- [x] STATE.md: M6 planning records (Progress row, naming table, OQ-M6-01..06 resolutions, risks)
- [x] **Verificar:** ROADMAP grep has the rebrand-item pointer; STATE M6 section present; `git diff` on ROADMAP/STATE touches only the M6 additions
- **Review note (2026-08-13):** ROADMAP/STATE M6 sections exist; the delivered-facts paragraphs in ROADMAP still describe the 2026-08-10 delivery state (floors 0.1.30/0.1.48/0.1.20/0.2.4). The current repo has the 0.1.0 baseline (PR #16) — context.md "Post-delivery review" is the delta owner; ROADMAP's delivered paragraph is history.

## Final Acceptance (M6) — all met (reviewed 2026-08-13)

- [x] All seven tools under Squad names; old names absent from name-surfaces (guard green)
- [x] Each fork's upstream suite green in-workspace; turbo build/test/lint green
- [x] Bootstrap installs the whole toolchain from the workspace; floors gate the forks (0.1.0 baseline)
- [x] CI matrix extended (axi-tools) + tasks-axi job renamed sq-tasks
- [x] pr-review fix committed + verified; sync procedure + rebrand pointer recorded

**No remaining open tasks in M6.** Follow-on ownership: rebrand item roadmap-futuro-rebrand-completo-de-menco-31 (deferred prose, missing optional legacy aliases; the stale SQUAD_TASKS_AXI_MIN vendor note was corrected in this review).
