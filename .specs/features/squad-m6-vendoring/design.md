# Squad M6 — Vendoring the AXI Toolchain — Design

**Status:** DELIVERED 2026-08-10; reviewed against the live repo 2026-08-13 (post-delivery PRs corrected below — see context.md "Post-delivery review")
**Sources (researched 2026-08-10 via GitHub API/raw, read-only):** `kunchenguid/{gh-axi,chrome-devtools-axi,lavish-axi,quota-axi}` at `main`; local `packages/tasks-axi` (vendored fork), `packages/pr-review`, `bin/sq-bootstrap.sh`, `bin/sq-tasks-axi-lib.sh`, `bin/sq-quota-axi-lib.sh`, `.github/workflows/ci.yml`

---

## 1. Target Workspace Layout

```
packages/
├── fob/  pr-review/  drill/      # fob kept; pr-review kept (re-classified maintained, PR #16); no-mistakes renamed to drill (PR #8); goal-loop-audit cut (commander decision 2026-08-10)
├── sq-gh/        # ex gh-axi v0.1.30       (TS, pnpm@11.1.1, node>=20) — now 0.1.0 baseline
├── sq-browser/   # ex chrome-devtools-axi v0.1.29 (TS, pnpm@11.1.1, node>=20, @modelcontextprotocol/sdk) — now 0.1.0 baseline
├── sq-quota/     # ex quota-axi v0.1.20     (TS, pnpm@11.1.1, node>=22.19) — now 0.1.0 baseline
├── sq-report/    # ex lavish-axi v0.1.48    (JS, pnpm@11.1.1, node>=22, scripts/build.js) — now 0.1.0 baseline
└── sq-tasks/     # ex packages/tasks-axi 0.2.5 (renamed from sq-tasks-axi) — now 0.1.0 baseline
```

Root `package.json` workspaces glob (`packages/*`) and `turbo.json` needed no edits — new packages are picked up automatically. Root stays `bun@1.2.0`; each fork keeps its own `pnpm@11.1.1` workspace inside. Root `bun install` tolerates the nested pnpm lockfiles (verified).

## 2. Vendoring Pattern (mirror of M2 tasks-axi / M3-M5 provenance)

Per new package, from the pinned upstream tag (`gh-axi-v0.1.30`, `chrome-devtools-axi-v0.1.29`, `lavish-axi-v0.1.48`, `quota-axi-v0.1.20`):

1. **Pin + copy:** shallow reference clone at the tag; copy tracked files into `packages/<new-name>/`; exclude `.git/`, `node_modules/`, `dist/` (gitignored like the M2 fork).
2. **Provenance:** write `vendor.json` (source URL, tag, sha256 of package.json + source, extraction date) — the pr-review/goal-loop-audit pattern (M3/M5). The M2 tasks-axi fork has no vendor.json; add one during the sq-tasks rename (OQ-M6-06, recommended).
3. **Keep upstream-internal structure:** tsconfig, pnpm-workspace.yaml, eslint config, `.airlock/lint.sh` (present in gh-axi, chrome-devtools-axi, quota-axi), release-please files, skills dir, LICENSE, THIRD-PARTY-NOTICES (lavish). Engine floors respected: `node>=20` (sq-gh, sq-browser), `node>=22` (sq-report), `node>=22.19` (sq-quota) — CI node 22 covers all.
4. **Name rename only (decision 3):** package.json `name`/`bin`/`files`, bin entry files, `dist/` output names, release-please `package-name`, build-script path literals. Prose/help/TOON untouched (deferred).
5. **Tests green in-workspace:** `pnpm install --frozen-lockfile && pnpm build && pnpm test` per package; upstream test issues fixed only when they are environment/strictness breaks (M5 precedent: three documented upstream test fixes), never by weakening assertions.

## 3. Install/Build Mechanics (REQ-M6-03) — DELIVERED

**Decision (OQ-M6-02 (a)): local global install from the workspace folder.** Mirrors the proven M2 CI path for tasks-axi:

```
(cd packages/<pkg> && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build)
npm install -g ./packages/<pkg>     # prepack runs the build (cache hit)
```

- `sq-bootstrap.sh install_cmd` branches (current, verified):
  - `sq-gh|sq-browser|sq-report` → `(cd packages/$1 && pnpm install --frozen-lockfile && pnpm run build) && npm install -g ./packages/$1 && $1 setup hooks`
  - `sq-quota|sq-tasks` → same without the `setup hooks` half
  - `drill` → OQ-03 release placeholder (`curl -fsSL .../drill-install.sh | sh`); `fob` → `bin/sq-install-fob.sh ~/.local/bin` (builds the vendored `packages/fob`, PR #26)
- Real npm publish stays org-gated (OQ-03) and is recorded as future work, not planned here.
- **Legacy aliases (OQ-M6-01):** the mandatory `tasks-axi` → `sq-tasks` protocol alias is implemented (CI + resolver fallback). The four optional legacy aliases were NOT created (review 2026-08-13) — deferred prose naming the old tools remains in the guard keep-list and is owned by the rebrand item.

## 4. Bootstrap Wiring (REQ-M6-03) — DELIVERED

`bin/sq-bootstrap.sh` changes (name references only) — all applied and verified:

- `COMMON_TOOLS="node git gh drill sq-gh sq-browser sq-report sq-quota sq-tasks"` (drill replaced no-mistakes after PR #8)
- `install_cmd` branches per §3
- Floor checks: `tool_version_at_least sq-gh "$GH_AXI_MIN"`, `tool_version_at_least sq-report "$LAVISH_AXI_MIN"`, `fm_quota_axi_compatible` (probes `sq-quota`), `fm_tasks_axi_compatible` (resolver probes `sq-tasks`) — all on the new bin names
- Legacy alias: only the mandatory `tasks-axi` → `sq-tasks` (CI + resolver); optional aliases for the other four were not created (see §3 review note)

## 5. Version Floors (REQ-M6-04) — DELIVERED (values reset by PR #16)

Constant **names** stay (decision 3 deferral); **operands** now point at the new bins. **Values** are all the 0.1.0 clean-baseline reset (PR #16, 2026-08-11) — the planned bumps were superseded:

| Constant | Old value | Planned value | Current value | Operand |
| --- | --- | --- | --- | --- |
| `GH_AXI_MIN` (sq-bootstrap.sh) | 0.1.29 | 0.1.30 | **0.1.0** | `sq-gh` |
| `LAVISH_AXI_MIN` (sq-bootstrap.sh) | 0.1.46 | 0.1.48 | **0.1.0** | `sq-report` |
| `SQUAD_QUOTA_AXI_MIN` (sq-quota-lib.sh) | 0.1.17 | 0.1.20 | **0.1.0** | `sq-quota` |
| `SQUAD_TASKS_AXI_MIN` (sq-tasks-lib.sh) | 0.2.4 | 0.2.4 (durable) | **0.1.0** | `sq-tasks` |

`sq-browser` keeps presence-only detection (no floor today) — documented, no new floor in M6.

## 6. CI Additions (REQ-M6-05) — DELIVERED

`.github/workflows/ci.yml`, following the existing `tasks-axi` job pattern — both applied and green:

- **New job `axi-tools` (matrix):** `pkg: [sq-gh, sq-browser, sq-quota, sq-report]`; steps: checkout → pnpm/action-setup 11.1.1 → setup-node 22 → `cd packages/${{ matrix.pkg }} && pnpm install --frozen-lockfile && pnpm run build && pnpm run test` → `npm pack --dry-run | grep` the new bin name. (OQ-M6-05 (a).)
- **`tasks-axi` job renamed → `sq-tasks`:** path `packages/sq-tasks`, bin assertions `sq-tasks --version` + alias `tasks-axi`; the three test-lane install steps update path + alias symlink (`ln -s "$(command -v sq-tasks)" …/tasks-axi`).
- Go jobs untouched; `go-build-test` keeps fob/drill filters (workflow renamed `drill-required.yml`, PR #8).

## 7. Distro Call-Site Sweep (names only) — DELIVERED

Code that *executes* the tools (not prose) — all applied and verified (guard green):

| File | Change | Status |
| --- | --- | --- |
| `bin/sq-pr-merge.sh` | `gh-axi pr merge` → `sq-gh pr merge` | done (header prose kept in guard keep-list) |
| `bin/sq-teardown.sh` | `gh-axi pr list` → `sq-gh pr list` | done (prose kept) |
| `bin/sq-procevent-lavish.sh` | `lavish-axi poll` → `sq-report poll`; `command -v lavish-axi` → `command -v sq-report`; register id `lavish` KEPT | done |
| `bin/sq-quota-axi-lib.sh` → `bin/sq-quota-lib.sh` | probe `quota-axi` → `sq-quota` | done |
| `bin/sq-tasks-axi-lib.sh` → `bin/sq-tasks-lib.sh` | `fm_tasks_axi_cmd` prefers `sq-tasks`, falls back `tasks-axi`; `SQUAD_TASKS_AXI_MIN` 0.1.0; sourcing files updated (sq-bootstrap.sh, sq-public-followup.sh/-lib/-emit, sq-unit-snapshot.sh, sq-x-poll.sh, sq-backlog-handoff/-receive, sq-decision-hold, sq-remote-doctor, sq-teardown, sq-session-start, sq-test-run) | done |
| `bin/sq-bootstrap.sh` | COMMON_TOOLS, install_cmd, floor operands, lib source path | done |
| `bin/sq-vendor-auth-probe.sh` | no `quota-axi` executable invocation (only prose comment) | n/a — prose kept |
| `bin/sq-session-start.sh` etc. | tool-name references in executable paths | done |
| `tests/` | fakebin stubs and fixtures renamed to `sq-*`; prose-assertion files kept per the guard keep-list | done |
| `.github/workflows/ci.yml` | §6 | done |
| `docs/scripts.md` | file-path references to renamed bin/lib files → new paths | done |

`AGENTS.md`, `docs/*.md` prose, package READMEs/help strings: **deferred** (roadmap item).

## 8. pr-review Fix Shipping (REQ-M6-06) — DELIVERED

The working-tree change in `packages/pr-review/extensions/pr-review-subagent.ts` (replaces the top-level `Type.Object` **union** for `PrReviewVerifyParams` with a **single** Object schema `{action, pr_number?, head_sha?, baseline_name?}` + runtime required-field validation in `execute`) landed as a normal M6 commit.

- **Verify:** the fix is committed and its regression test passes ("registers a single top-level object schema and enforces run's required fields at runtime"). Current suite: 250 pass / 2 fail — the two failures are README-content assertions (tests assert exact README prose for the focus viewer and the cached single-post contract) that drifted when the READMEs were beautified in PR #11; unrelated to the schema fix. Residual, documented; no M6 action.
- The upstream identity cleanup in PR #16 re-classified pr-review from "vendored" to "maintained" (0.1.0, no vendor.json, docs/pr-review.md updated) — the package remains in-repo and wired via `.pi/extensions/sq-pr-review.ts`.
- Upstream package name/identity stays `@runecraft/pr-review` (T-M3-02, Runecraft's own package).

## 9. Upstream Sync Procedure (on-demand, REQ-M6-07) — DELIVERED

Trigger: commander says "quando der na telha". Steps per package (unchanged; procedure recorded):

1. Resolve new tag: `gh api repos/kunchenguid/<tool>/releases/latest` (or pick a tag).
2. Reference clone at the tag; diff against the vendored package (`git diff --no-index` or a scratch worktree) — expect upstream-prose noise; isolate name-bearing diffs.
3. Copy changed tracked files (exclude `.git`, `node_modules`, `dist`).
4. Re-apply the Squad name rename on new files (per-tool rename table) — never blind-copy upstream package.json/bin names.
5. Bump the fork version + the Squad floor constant to the new version (unless the durable floor contract applies).
6. Update `vendor.json` (new tag/sha/date).
7. Run the package suite + affected distro tests + the M6 name-surface guard. Commit per package.
8. If upstream changed the CLI protocol, update the distro call sites / compatibility probes (defense-in-depth probes in sq-tasks-lib.sh / sq-quota-lib.sh are the tripwires).

## 10. Verification Guards (M6) — DELIVERED

`tests/sq-m6-name-guard.test.sh` is committed and green. It scans `packages/*/package.json`, `packages/*/bin`, `packages/*/release-please-config.json`, `packages/*/plugin.json`, `.github/workflows/ci.yml`, `bin/*.sh`, and `tests/*.test.sh` for the five old names with a documented deferred-prose keep-list (sq-brief.sh "Use gh-axi…", comments in the call-site scripts, prose-assertion test files). PR #25 retired every packages/ hit (incl. the former sq-browser bridge log-prefix pin). `.specs/` exempt. Executor's keep-list is documented in the guard file itself.

## 11. Risks — REVISED 2026-08-13

- **RISK-M6-01 — Nested pnpm lockfiles at root:** no adverse finding; root `bun install` tolerates the 5 nested `pnpm-lock.yaml` files.
- **RISK-M6-02 — lavishly large copy:** shipped in the tracked copy; no pruning decision made (recorded future option).
- **RISK-M6-03 — Engine floors:** CI pins node 22; documented requirement; no adverse finding.
- **RISK-M6-04 — Deferred-prose staleness:** the four optional legacy aliases were NOT created, so deferred prose naming `gh-axi`/`chrome-devtools-axi`/`lavish-axi`/`quota-axi` (sq-brief.sh, comments) points at names absent from PATH. Owned by the rebrand item (roadmap-futuro-rebrand-completo-de-menco-31); operators follow the sq-* names. The `tasks-axi` protocol alias is mandatory and kept.
- **RISK-M6-05 — Guard keep-list drift:** partially retired by PR #25; remaining keep-list documented in the guard file; the rebrand item must retire it when it lands.
- **RISK-M6-06 — Upstream drift between vendoring and first sync:** on-demand sync (decision 5) means pinned versions age; floors + compatibility probes catch protocol breakage. Accepted (decision 5).
- **Post-delivery:** PR #16 reset all fork versions/floors to the 0.1.0 baseline — future syncs bump both fork version and floor together (sync §9 step 5).
