# Squad M6 — Vendoring the AXI Toolchain — Design

**Status:** Ready for Execute (commander decisions 1–6 locked; open decisions OQ-M6-01..06 in context.md, defaults recommended)
**Sources (researched 2026-08-10 via GitHub API/raw, read-only):** `kunchenguid/{gh-axi,chrome-devtools-axi,lavish-axi,quota-axi}` at `main`; local `packages/tasks-axi` (vendored fork), `packages/pr-review`, `bin/sq-bootstrap.sh`, `bin/sq-tasks-axi-lib.sh`, `bin/sq-quota-axi-lib.sh`, `.github/workflows/ci.yml`

---

## 1. Target Workspace Layout

```
packages/
├── fob/  no-mistakes/  pr-review/  goal-loop-audit/      # unchanged (M2/M3/M5)
├── sq-gh/        # ex gh-axi v0.1.30       (TS, pnpm@11.1.1, node>=20)
├── sq-browser/   # ex chrome-devtools-axi v0.1.29 (TS, pnpm@11.1.1, node>=20, @modelcontextprotocol/sdk)
├── sq-quota/     # ex quota-axi v0.1.20     (TS, pnpm@11.1.1, node>=22.19)
├── sq-report/    # ex lavish-axi v0.1.48    (JS, pnpm@11.1.1, node>=22, scripts/build.js)
└── sq-tasks/     # ex packages/tasks-axi 0.2.5 (renamed from sq-tasks-axi)
```

Root `package.json` workspaces glob (`packages/*`) and `turbo.json` need **no edits** — new packages are picked up automatically; every fork already ships `build`/`test` scripts. Root stays `bun@1.2.0`; each fork keeps its own `pnpm@11.1.1` workspace inside (M2 RISK-10 fidelity precedent). Root `bun install` must tolerate four more nested pnpm lockfiles (proven with tasks-axi in T-M2-04; re-verify after adding).

## 2. Vendoring Pattern (mirror of M2 tasks-axi / M3-M5 provenance)

Per new package, from the pinned upstream tag (`gh-axi-v0.1.30`, `chrome-devtools-axi-v0.1.29`, `lavish-axi-v0.1.48`, `quota-axi-v0.1.20`):

1. **Pin + copy:** shallow reference clone at the tag; copy tracked files into `packages/<new-name>/`; exclude `.git/`, `node_modules/`, `dist/` (gitignored like the M2 fork).
2. **Provenance:** write `vendor.json` (source URL, tag, sha256 of package.json + source, extraction date) — the pr-review/goal-loop-audit pattern (M3/M5). The M2 tasks-axi fork has no vendor.json; add one during the sq-tasks rename (OQ-M6-06, recommended).
3. **Keep upstream-internal structure:** tsconfig, pnpm-workspace.yaml, eslint config, `.airlock/lint.sh` (present in gh-axi, chrome-devtools-axi, quota-axi), release-please files, skills dir, LICENSE, THIRD-PARTY-NOTICES (lavish). Engine floors respected: `node>=20` (sq-gh, sq-browser), `node>=22` (sq-report), `node>=22.19` (sq-quota) — CI node 22 covers all.
4. **Name rename only (decision 3):** package.json `name`/`bin`/`files`, bin entry files, `dist/` output names, release-please `package-name`, build-script path literals. Prose/help/TOON untouched (deferred).
5. **Tests green in-workspace:** `pnpm install --frozen-lockfile && pnpm build && pnpm test` per package; upstream test issues fixed only when they are environment/strictness breaks (M5 precedent: three documented upstream test fixes), never by weakening assertions.

## 3. Install/Build Mechanics (REQ-M6-03)

**Decision (default, OQ-M6-02): local global install from the workspace folder.** Mirrors the proven M2 CI path for tasks-axi:

```
(cd packages/<pkg> && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build)
npm install -g ./packages/<pkg>     # prepack runs the build (cache hit)
```

- `sq-bootstrap.sh install_cmd` new branches:
  - `sq-gh|sq-browser|sq-report` → `npm install -g ./packages/<name> && <name> setup hooks` (setup-hooks tools; `sq-report` = lavish-axi which has hooks via `plugin.json`)
  - `sq-quota|sq-tasks` → `npm install -g ./packages/<name>` (no setup-hooks step today)
- Real npm publish stays org-gated (OQ-03) and is recorded as future work, not planned here.
- The Go tools keep their release-channel install commands (fob/no-mistakes 404 = OQ-03 boundary, unchanged).

## 4. Bootstrap Wiring (REQ-M6-03)

`bin/sq-bootstrap.sh` changes (name references only):

- `COMMON_TOOLS="node git gh no-mistakes sq-gh sq-browser sq-report sq-quota sq-tasks"` (order kept for diff readability)
- `install_cmd` branches renamed per §3
- Floor checks: `tool_version_at_least sq-gh "$GH_AXI_MIN"`, `tool_version_at_least sq-report "$LAVISH_AXI_MIN"`, `fm_quota_axi_compatible` (probes `sq-quota`), `fm_tasks_axi_compatible` (resolver probes `sq-tasks`)
- **Legacy aliases (OQ-M6-01, default: yes):** CI and bootstrap install the fork under its new bin AND a legacy-name symlink (`gh-axi`→`sq-gh`, `chrome-devtools-axi`→`sq-browser`, `lavish-axi`→`sq-report`, `quota-axi`→`sq-quota`, `tasks-axi`→`sq-tasks`), mirroring the M2 `tasks-axi` alias. Rationale: deferred operator-facing prose (sq-brief.sh: "Use gh-axi…") and ecosystem scripts keep working until the rebrand item lands. The `tasks-axi` alias is mandatory regardless (protocol/backend value, deferred).

## 5. Version Floors (REQ-M6-04)

Constant **names** stay (decision 3 deferral); **values and operands** change:

| Constant | Old value | New value | Operand |
| --- | --- | --- | --- |
| `GH_AXI_MIN` (sq-bootstrap.sh) | 0.1.29 | 0.1.30 | `sq-gh` |
| `LAVISH_AXI_MIN` (sq-bootstrap.sh) | 0.1.46 | 0.1.48 | `sq-report` |
| `SQUAD_QUOTA_AXI_MIN` (sq-quota-axi-lib.sh) | 0.1.17 | 0.1.20 | `sq-quota` |
| `SQUAD_TASKS_AXI_MIN` (sq-tasks-lib.sh) | 0.2.4 | **0.2.4 (unchanged, durable contract)** | `sq-tasks` |

`chrome-devtools-axi`/`sq-browser` keeps presence-only detection (no floor today) — documented, no new floor in M6 (OQ-M6-03 option retained).

## 6. CI Additions (REQ-M6-05)

`.github/workflows/ci.yml`, following the existing `tasks-axi` job pattern:

- **New job `axi-tools` (matrix):** `pkg: [sq-gh, sq-browser, sq-quota, sq-report]`; steps: checkout → pnpm/action-setup 11.1.1 → setup-node 22 → `cd packages/${{ matrix.pkg }} && pnpm install --frozen-lockfile && pnpm run build && pnpm run test` → `npm pack --dry-run | grep` the new bin name. (Alternative: one job per package — rejected: 4 identical jobs, matrix is the established Turbo/CI idiom here; record as OQ-M6-05.)
- **Rename the existing `tasks-axi` job → `sq-tasks`:** path `packages/sq-tasks`, bin assertions `sq-tasks --version` + alias `tasks-axi`; the three test-lane install steps (`Install tasks-axi (forked sq-tasks-axi, M2)`) update path + alias symlink (`ln -s "$(command -v sq-tasks)" …/tasks-axi`).
- Go jobs untouched; `go-build-test` keeps fob/no-mistakes filters.

## 7. Distro Call-Site Sweep (names only)

Code that *executes* the tools (not prose):

| File | Change |
| --- | --- |
| `bin/sq-pr-merge.sh` | `gh-axi pr merge` → `sq-gh pr merge` |
| `bin/sq-teardown.sh` | `gh-axi pr list` → `sq-gh pr list` |
| `bin/sq-procevent-lavish.sh` | `lavish-axi poll` → `sq-report poll`; `command -v lavish-axi` → `command -v sq-report`; register id `lavish` KEPT (deferred) |
| `bin/sq-quota-axi-lib.sh` (→ `bin/sq-quota-lib.sh` per OQ-M6-04) | probe `quota-axi` → `sq-quota` |
| `bin/sq-tasks-axi-lib.sh` (→ `bin/sq-tasks-lib.sh`, commander-mandated) | `fm_tasks_axi_cmd` prefers `sq-tasks`, falls back `tasks-axi`; `SQUAD_TASKS_AXI_MIN` unchanged; sourced by sq-public-followup.sh/-lib/-emit, sq-unit-snapshot.sh, sq-x-poll.sh, sq-bootstrap.sh → update source paths |
| `bin/sq-bootstrap.sh` | COMMON_TOOLS, install_cmd, floor operands, `. "$SCRIPT_DIR/sq-quota-axi-lib.sh"` path |
| `bin/sq-vendor-auth-probe.sh` | any `quota-axi` invocation (verify at execute; reads quota data for dispatch judgment) |
| `bin/sq-session-start.sh`, `bin/sq-brief.sh` (code paths), `bin/sq-project-mode.sh` (comments/help are prose → deferred) | tool-name references in executable paths |
| `tests/` | fakebin stubs and fixtures named `gh-axi|chrome-devtools-axi|lavish-axi|quota-axi|sq-tasks-axi` → new names; prose assertions (e.g., sq-brief test asserting "Use gh-axi…") KEPT (deferred) |
| `.github/workflows/ci.yml` | §6 |
| `docs/scripts.md` | file-path references to renamed bin/lib files → new paths (prose mentions deferred) |

`AGENTS.md`, `docs/*.md` prose, package READMEs/help strings: **deferred** (roadmap item).

## 8. pr-review Fix Shipping (REQ-M6-06)

The working-tree change in `packages/pr-review/extensions/pr-review-subagent.ts` (replaces the top-level `Type.Object` **union** for `PrReviewVerifyParams` with a **single** Object schema `{action, pr_number?, head_sha?, baseline_name?}` + runtime required-field validation in `execute`, because the union serialized without `"type":"object"` and broke every subagent spawn with "Invalid schema for function 'pr_review_verify'") lands as a normal M6 commit:

- **Verify:** `bun test` in `packages/pr-review` green (252 upstream tests); headless Pi load smoke; one `pr_review_verify` spawn exercise (action=list / action=run missing-fields → clear error, not schema failure).
- **Optional regression coverage (recommended):** a small unit test asserting the JSON-schema form of `PrReviewVerifyParams` has `"type":"object"` and that `action=run` without `pr_number`/`head_sha`/`baseline_name` returns the missing-fields error. Upstream package name/identity untouched (it is Runecraft's package, T-M3-02).

## 9. Upstream Sync Procedure (on-demand, REQ-M6-07)

Trigger: commander says "quando der na telha". Steps per package:

1. Resolve new tag: `gh api repos/kunchenguid/<tool>/releases/latest` (or pick a tag).
2. Reference clone at the tag; diff against the vendored package (`git diff --no-index` or a scratch worktree) — expect upstream-prose noise; isolate name-bearing diffs.
3. Copy changed tracked files (exclude `.git`, `node_modules`, `dist`).
4. Re-apply the Squad name rename on new files (per-tool rename table) — never blind-copy upstream package.json/bin names.
5. Bump the fork version + the Squad floor constant to the new version (unless the durable floor contract applies).
6. Update `vendor.json` (new tag/sha/date).
7. Run the package suite + affected distro tests + the M6 name-surface guard. Commit per package.
8. If upstream changed the CLI protocol, update the distro call sites / compatibility probes (defense-in-depth probes in sq-tasks-lib.sh / sq-quota-lib.sh are the tripwires).

## 10. Verification Guards (M6)

Name-surface guard (extends the M1 §8 guard family; a `tests/sq-m6-name-guard.test.sh`): `grep -rE '\b(gh-axi|chrome-devtools-axi|lavish-axi|quota-axi|sq-tasks-axi)\b'` over `packages/*/package.json`, `packages/*/bin`, `packages/*/release-please-config.json`, `packages/*/plugin.json`, `.github/workflows/ci.yml`, `bin/` (excluding deferred prose files: `sq-brief.sh` prose strings stay until rebrand), and `tests/` (excluding prose-assertion files, documented keep-list) → 0 hits. `.specs/` exempt (planning corpus names origins, per M1 §8). Executor pins the exact keep-list when writing the test; this spec's boundary (decision 3) is the rule: **names change, prose defers.**

## 11. Risks

- **RISK-M6-01 — Nested pnpm lockfiles at root:** 4 more `pnpm-lock.yaml` files under `packages/*`; root `bun install` must not choke (proven for tasks-axi; verify after adding; exclude from bun resolution if needed — T-M2-04 precedent).
- **RISK-M6-02 — lavishly large copy:** lavish-axi repo ≈ 76 MB (lavish-editor-marketing renders). Tracked-file copy only (no `.git`); size impact on the Squad repo should be measured; if excessive, the marketing assets are a candidate for later pruning (recorded, not decided).
- **RISK-M6-03 — Engine floors:** sq-report (node>=22) and sq-quota (node>=22.19) raise the local/CI node floor above the other tools; CI pins node 22 (already), local bootstrap already checks node presence — document the requirement.
- **RISK-M6-04 — Deferred-prose staleness:** operators following deferred instructions (sq-brief "Use gh-axi…") until the rebrand item lands; mitigated by legacy aliases (OQ-M6-01 default). Known and accepted for the window.
- **RISK-M6-05 — Guard keep-list drift:** the M6 name guard's exclude list is hand-maintained; the rebrand item must retire the guard's exclusions when it lands.
- **RISK-M6-06 — Upstream drift between vendoring and first sync:** on-demand sync (decision 5) means pinned versions age; floors + compatibility probes catch protocol breakage. Accepted (decision 5).
