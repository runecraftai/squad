# Squad — State

**Updated:** M0–M5 complete (session 2) — project acceptance reached; org-gated publication steps pending OQ-03

## Progress

| Milestone | Status | Notes |
| --- | --- | --- |
| M0 — Import & Scaffold | ✅ done (baseline documented; 9 env/decision-attributable failures, 0 source defects — see T-M0-05) | T-M0-01..05 all done |
| M1 — Rebrand Sweep | ✅ done (T-M1-01..12; suite pass-set = M0 baseline + 2 M1-input fixes; 6 env-attributable failures identical to M0; fork-dependent cases gated until M2) | see T-M1-12 |
| M2 — Deps as Workspace Packages | ✅ done (T-M2-01..05; turbo build/lint green, tests green modulo 1 env case; repo-wide guards green incl. packages) | see T-M2-01..05 |
| M3 — Pi Adapters + pr-review | ✅ done | see T-M3-01..03 |
| M4 — Publication & CI | ✅ done (org-gated: releases/publish/CI-green-on-real-PR pending OQ-03) | see T-M4-01..04 |
| M5 — goal-loop-audit + Roadmap note | ✅ done (coexistence verified; ROADMAP open-item recorded) | see T-M5-01..03 |

## Task log

### T-M1-12 — Private-material seeds + full gate ✅ (session 2)

Completed in a second execution session. All remaining genuine rebrand defects fixed, the guard was found broken and repaired, and the full suite was re-run lane by lane.

**Genuine remaining defects fixed (all traceable to the sweep, none to upstream source):**
- Kind-value leftovers: `tests/sq-teardown.test.sh` fixtures still wrote `kind=ship`/`kind=XO` (54+3 calls) while bin normalized to `kind=strike`/`kind=xo`; `bin/sq-teardown.sh` `validate_worktree_teardown_safety` still compared uppercase `XO`; `tests/sq-decision-hold-lifecycle.test.sh` wrote `kind=XO`. Fixed all to lowercase `xo`/`strike` (consistent with c811c3e).
- `bin/sq-debrief-cascade.sh` emitted `role=XO` while `sq-startup-memory-budget.sh` emits `role=xo`; tests asserted both ways. Normalized to `role=xo` (bin + tests).
- `sq-remote-XO-control.sh` (uppercase) vs actual file `sq-remote-xo-control.sh` — 8 bin files + 4 test files + docs referenced the uppercase name, which broke every remote-XO path (sq-on validates the remote command is a tracked executable). Renamed all references + `schema=sq-remote-XO-control.v1` → `schema=sq-remote-xo-control.v1` (bin/tests/docs).
- `tests/sq-arm-pretool-check.test.sh` — sweep mangled obfuscated script-name fixtures (`sq-watc\nh-arm.sh`, `$'\x77'atch`, `$"watch"`) into nonsense that no longer matched any protected pattern; restored as `sq-sentry-ar\nm.sh`, `$'\x73'entry`, `$"sentry"` forms.
- `tests/sq-sentry-lock.test.sh` expected hex still encoded `fm-watch.sh`; updated to `sq-sentry.sh` bytes.
- `tests/sq-operational-input.test.sh` expected hex still encoded `FIRSTMATE_OP:`; updated to `SQUAD_OP:` bytes.
- `tests/sq-pi-watch-extension.test.sh` + `sq-opencode-primary-live-e2e.test.sh` referenced `.opencode/plugins/sq-primary-sentry-arm.js`; actual name is `sq-primary-watch-arm.js`.
- `tests/sq-bootstrap.test.sh` assertions still expected upstream `kunchenguid` install URLs; updated to the OQ-03 placeholder the binary emits.
- `tests/sq-unit-snapshot-view.test.sh`: byte-order id sort (`XO-task` first), `kind` column now `strike`/`xo`, XO send guidance case.
- `tests/sq-task-delivery.test.sh`, `tests/sq-spawn-batch.test.sh`, `tests/sq-brief.test.sh` + `bin/sq-brief.sh` — remaining `ship spawns/ship briefs` prose normalized to `strike`.
- `docs/`: three broken `fm_backend` anchors (architecture, cmux/herdr/tmux/zellij-backend), one broken `XO-routes-dataXOsmd` anchor, `gitlab-merge-watch.md` → `gitlab-merge-sentry.md` link, `verification/supervision.md` heading `Watcher continuity` → `Sentry continuity`, `sentry-continuity.md` title.
- `LICENSE` still carried `Copyright (c) 2026 Kun Chen` (guard 2 catch); now `Squad contributors` (RISK-01 documented deviation, commander decision).
- `tests/fixtures/tmux-permissive-kill.sh` (NEW): M1 input A resolved — `resolve_permissive_tmux_kill_ref` (git-history walk, broken by AD-010 squash) replaced by a pinned one-line derivation of `bin/backends/tmux.sh` with the permissive kill-window selector (documented in the test).
- **Guard repair (critical):** guard 1/2 patterns used inline `(?i)` which is NOT valid ERE — GNU grep warns "? at start of expression" and matches nothing. The guards were no-ops; 25 `kunchenguid` fixture URLs passed silently. Fixed `guard_no_match` to strip `(?i)` and apply real `-i`; rebranded the 25 fixture URLs to `github.com/squad-org/squad` (OQ-03 placeholder) in calm-pi-extension, project-origin, sitrep-snapshot, unit-snapshot-view tests.

**Fork-dependent cases gated until M2 (documented skips, not passes):** the upstream npm `tasks-axi 0.2.5` cannot run Squad's typed contracts — `hold --kind commander` (validates captain|external|load|parked|future) and `public-followup` home taxonomy (`xo:` vs upstream `main|secondmate:`). The forked `sq-tasks-axi` (T-M2-04, AD-006) supplies both. Gated: `sq-decision-hold-lifecycle` (file), `sq-public-followup` (file, functional probe), `sq-backend` teardown-conformance sub-case, `sq-backend-orca` 7 recon-teardown sub-cases, `sq-backend-zellij` recon-teardown sub-case. Each prints `skip: tasks-axi lacks the commander-hold contract (forked sq-tasks-axi, M2)` (or the xo: taxonomy variant) and exits 0. The secondmate word itself is guard-5-forbidden, so the public-followup probe greps `must be main or` only.

**Full suite (lane by lane, LC_ALL=C.UTF-8, PATH=/tmp/sq-tools):** portable-parallel-1 11/11 (2 gate-skipped), portable-parallel-2 13/13, portable-serial-1 22/23 (1 env), serial-2 23/25 (1 env + sq-task-delivery fixed), serial-3 22/24 (1 env + focus-flash herdr-daemon — passes once the default herdr session runs), serial-4 23/26 (3 env), real-herdr-gated 11/11 (4 gate-skipped). Remaining 6 failures are EXACTLY the M0-classified environment set: sq-bootstrap + sq-session-start (/usr/bin/node), sq-on + sq-remote-doctor (tools/harnesses installed), sq-remote-job-orphan-reap (systemd reparenting), sq-calm-pi-extension (tmux 3.7b rendering flake; pi package absent from npm global). `sq-test-run.sh --check-coverage` exit 0 (total=133, parallel=24, serial=98, serial_shards=4, herdr=11); `bin/sq-lint.sh` green (shellcheck 0.11.0); all 6 §8 guards green with the REPAIRED patterns; 17 key tests re-verified green individually.
- **Note:** the 8 real-herdr-gated failures in the 11:18 rerun were environment: the default herdr session was STOPPED (unit-state tripwire refuses). `herdr` (bare) starts it; tests pass with it running. Not a source defect.
- **Note:** 16 skips in M0 became 16 + fork gates in M1; the fork gates resolve in M2 when CI installs `sq-tasks-axi`.

### T-M5-01..03 — goal-loop-audit + Roadmap note (session 2) ✅
- **T-M5-01 vendored @runecraft/goal-loop-audit 0.28.34** into `packages/goal-loop-audit/` (provenance vendor.json; bun hoisting after root re-install). `bun test`: 607 pass / 1 skip / 0 fail. Three upstream test issues fixed: (a) `fs` was used unimported in tests/loop-forever.test.ts (strict-ESM ReferenceError) → `import * as fs from "node:fs"`; (b) README assertions (## Subagents, notify docs, "We ran both and removed pi-tasks") documented truthfully in the vendored README; (c) the v0.29.0 audit-measure regex expected a broken runtime command (`\]` double backslash) — the vendored code is byte-identical to the harness reference and its runtime output is correct; the test was fixed to match the correct output.
- **T-M5-02 integration + coexistence:** `.pi/extensions/sq-goal-loop-audit.ts` bootstrapper (imports the vendored goal.ts entrypoint). Headless coexistence validated in ONE Pi session: /goal /list /loop registered (goal-loop-audit) alongside the pr-review extension — verified both by session command listing and by an in-session source verification pass (PASS/FAIL per file; COEXIST_VERIFIED). No load errors in any headless run; two-driver rule holds (each package registers behind its own coordinator).
- **T-M5-03 Roadmap note:** ROADMAP.md now carries the explicit open/optional entry — TS port of the Go deps ("ou não", AD-004), not committed, no design/tasks exist; revisit only at commander request.
- **Verificado:** goal-loop-audit 607/0/1; coexistence session loads both drivers; ROADMAP note present.

### T-M4-01..04 — Publication & CI (session 2) ✅
- **T-M4-01 CI matrix:** added the three missing design §7 jobs to `.github/workflows/ci.yml`: `go-build-test` (ubuntu+macos, setup-go with go-version-file, `turbo run build --filter=fob --filter=no-mistakes` + `go test ./...` per package), `tasks-axi` (pnpm frozen install + build + vitest + `npm pack --dry-run` bin check), `pi-smoke` (optional, env-gated via `vars.PI_SMOKE`: bun install + headless pi session greps `PI_EXT_LOAD_OK`). Full job set: lint, test-coverage, portable-parallel-1/2, portable-serial, tests-herdr, tests-timing-aggregate, macos-stock-bash, invariants + the 3 new. YAML valid.
- **T-M4-02 Go release pipeline:** both forks already carry rebranded release-please manifests + release workflows (ranger sweep): fob (`fob` binary name, linux/macos archives, checksums, release-please config with flake.nix extra-file, manifest 2.1.1) and no-mistakes (manifest 1.48.0, draft releases, signing placeholders). Scratch-release dry-run and `sq-install-fob.sh` asset fetch need the real org (OQ-03) — recorded as an M4 boundary, same for the no-mistakes bootstrap URL. `sq-install-fob.sh` already resolves `SQUAD_FOB_CI_REPO=squad-org/squad`.
- **T-M4-03 npm publish:** fork package.json publishConfig now `{"access":"public","provenance":true}`; `npm view sq-tasks-axi` → 404 = name available (AD-006 verified at M2, re-verified); `npm pack --dry-run` lists sq-tasks-axi@0.2.5 with dist/bin/sq-tasks-axi.js + skills (prepack runs tsc build). Real publish stays M4-org-gated.
- **T-M4-04 distro E2E smoke (local, recorded):** fresh `git clone` of the repo → 129 sq-* scripts; harness detection pi/pi-signed; tasks-axi fork on PATH; fob installed from the local Go build (`packages/fob go build` → /tmp/sq-tools/fob, `dev` version). Then: brief scaffold (strike local-only + recon) → `sq-spawn.sh` strike: `spawned e2e-strike-1 harness=claude kind=strike mode=local-only window=Squad:sq-e2e-strike-1 worktree=.../.fob/...` (fob pool worktree + tmux window + meta) → recon spawn → report written at `data/e2e-recon-1/report.md` → decision-hold inventory (`complete --none`) → clean teardown with the report INTACT after teardown (recon gate correctly refused until inventoried). One posture notice observed (projects.md hand-written fixture parsed as no-mistakes posture — fixture authoring artifact, not a defect). Env cleanup done.
- **Verificado:** guard 6/6, lint 0, coverage 134 ok, YAML valid, E2E artifacts above.
- **M4 boundary (needs the org, OQ-03):** real GitHub Releases (fob/no-mistakes assets + `sq-install-fob.sh` fetch), tasks-axi real npm publish, CI green on a real PR, live pr-review demo (A-08), real Apple Team ID + umami site id replacement (SQ00000000 placeholder).

### T-M3-01..03 — Pi adapters + pr-review (session 2) ✅
- **T-M3-02 vendored @runecraft/pr-review v1.11.4** into `packages/pr-review/` (tracked-file copy from the local read-only harness reference; provenance `vendor.json` with sha256 of package.json + source + date). Hidden files restored (`.release-please-manifest.json` was missed by the first copy and is required by the release-version tests). Name unchanged (Runecraft's own package — T-M3-02). `bun test`: 252/252 green; 4 upstream tests failed initially against the short vendored README (they assert feature docs: `/pr-review-focus`, `Ctrl+Alt+R`, publication + cached single-post contracts) — the README (and prompt) now document those true contracts; `.release-please-manifest.json` was genuinely missing from the copy.
- **T-M3-03 integration layer:** `.pi/extensions/sq-pr-review.ts` — Squad-named bootstrapper registering the vendored package extension in-session (imports `packages/pr-review/extensions/index.ts`); `bin/sq-pr-review.sh` — wrapper validating (clear failures, exit 1): git repo context, PR resolution (explicit or current-branch), gh auth, PR OPEN; prints the in-session command (the review itself runs in Pi). COMMENT-only posture; never merges/approves; `+yolo` does not let it self-approve. Hook point documented in AGENTS.md section 7 (delivery/merge area) + new `docs/pr-review.md`. Guard-path unit tests: `tests/sq-pr-review-guard.test.sh` (4 cases green; auto-partitioned into the serial lane — coverage guard total now 134).
- **T-M3-01 Pi primary verified headless:** baseline smoke (--no-extensions) OK; full session from the repo loads all four extensions (sq-calm.ts, sq-primary-pi-watch.ts, sq-primary-turnend-guard.ts, sq-pr-review.ts — auto-discovery works); `SQUAD_PI_HARNESS=pi-signed` detection via `bin/sq-harness.sh` verified (prints pi-signed with marker, pi without). Watcher arm + turn-end protocols are exercised by the sq-pi-watch-extension / sq-calm suites (green; the calm tmux-rendering flake is the recorded M0 env case). Live pr-review demonstration remains A-08 (manual, documented in docs/pr-review.md — needs a scratch repo PR).
- **Verificado:** guard 6/6, lint 0, coverage 134 ok.

### T-M2-01..05 — Workspace packages (session 2) ✅
- **T-M2-01 scaffold:** `packages/fob` (ex-treehouse v2.1.1) + `packages/no-mistakes` extracted from fresh depth-1 reference clones (/tmp/dep-*; the originals had been cleaned from /tmp). Go module paths renamed to `github.com/squad-org/squad/packages/{fob,no-mistakes}` (OQ-01 resolved, recorded in context.md); internal imports swept via the module rename. Root `package.json` (bun workspaces `packages/*`) + `turbo.json` (build/lint/test graph, test dependsOn build) + private stub package.json per Go package (`build` = `go build -o dist/ .` / `./cmd/no-mistakes`, `test` = `go test ./...`, `lint` = `go vet ./...`). `bun install` at root; root node_modules untracked (was accidentally staged once; removed with `git rm --cached` + `.gitignore` entry).
- **T-M2-02/03 identity sweeps (fob + no-mistakes):** delegated to a ranger subagent; 32 files swept (LICENSE → Squad contributors, repo URLs → squad-org/squad, docs site → squad.example, telemetry → a.squad.example, launchd label com.kunchenguid.no-mistakes → com.squad.no-mistakes, Apple Team ID 9T2J7MNUP9 → SQ00000000 placeholder (M4 sets the real one; AGENTS.md invariant note updated), badges/X/Trendshift removed, star-history sections removed). go build + go vet clean; go test green except `TestSweepReapsSetsidEscapee...` (procreap) which fails identically on the pristine upstream clone (env: process supervisor at pid 1096, not init).
- **T-M2-04 tasks-axi fork:** `packages/tasks-axi` renamed to `sq-tasks-axi` (npm name + bin + dist/bin file + version.ts name check); `bin/tasks-axi.ts` → `bin/sq-tasks-axi.ts`. Kind contract renames: `captain`→`commander` (HOLD_KINDS, hold validation, examples, public-followup `approved_by`, skill file — this is the contract the M1-gated tests were waiting on), `secondmate`→`XO` home taxonomy (HOME_ID_RE accepts `XO:` and `xo:`; validation message `must be main or XO:<stable-id>` — the distro's canonical home shape is `XO:` per `fm_pf_home_id_valid`), SHIP/SCOUT leading-kind tokens → strike/recon, PERSISTENT SECONDMATE → PERSISTENT XO. Identity sweep (README/CHANGELOG/CONTRIBUTING/AGENTS/CLAUDE/skills/src/fixtures — incl. `firstmate-backlog.md` → `squad-backlog.md`, LEGACY_FIXTURE rename). pnpm kept inside the package (RISK-10); `pnpm install --frozen-lockfile`, build (tsc) + test (vitest) → 429 passed / 1 skipped.
- **T-M2-05 wiring:** `bin/sq-tasks-axi-lib.sh` gains `fm_tasks_axi_cmd` (fork-first resolver) driving the three compatibility probes; runtime call sites keep invoking the bare `tasks-axi` name so PATH shadowing (test fakebin stubs, CI alias) is preserved — an initial shell-function wrapper was tried and REVERTED because it bypassed fakebin stubs (found via the decision-hold partial-routing test). `sq-public-followup.sh`/`-lib`/`-emit`/`sq-unit-snapshot.sh`/`sq-x-poll.sh` now source the lib (via followup-lib where transitive); their `command -v tasks-axi` gates use `fm_tasks_axi_cmd`. CI installs the fork (`npm install -g ./packages/tasks-axi`) + a `tasks-axi` symlink alias in all three install steps. `sq-install-fob.sh` already had `SQUAD_FOB_CI_REPO=squad-org/squad` (OQ-03 placeholder) — real Release fetch is M4 (no releases exist yet); local build fallback documented in the script.
- **M1 gates unlocked:** with the fork on PATH, `sq-decision-hold-lifecycle`, `sq-public-followup`, `sq-backend` conformance, `sq-backend-orca`/`zellij` recon teardowns now RUN and PASS (verified locally with the fork installed globally + `/tmp/sq-tools` wrappers). The public-followup probe in the test still greps `must be main or` — now passes on the fork.
- **Repo-wide guard green including packages:** the §8 guards were re-run over the whole tracked tree; ~40 additional leftovers surfaced inside the packages (fob: `treehouse.toml` config rename → `fob.toml` (Go code + tests + example + workflows + Makefile + demo.tape + README/VISION/CHANGELOG prose; no legacy installs exist, so the fork defines the convention), `treehouse` binary naming → `fob`, `secondmate-home` lease holders → `xo-home`; no-mistakes: fleet/captain/secondmate prose in comments/tests, `.treehouse` fixture paths → `.fob`, `fm-remote-job-worker.sh` fixture → `sq-remote-job-worker.sh`, upstream PR references; tasks-axi: firstmate prose, fixture renames). 6/6 guards green on the full tree.
- **Verificado:** `npx turbo run build|lint --filter=fob --filter=no-mistakes --filter=sq-tasks-axi` exit 0; `turbo test` green except the no-mistakes procreap env case; `go test` per package green (same exception); `bin/sq-lint.sh` green; `tasks-axi hold --help` shows `--kind commander`; fork accepts `xo:`/`XO:` work_ref home ids; distro regression batch (sq-teardown, sq-brief, sq-sitrep-snapshot, sq-backlog-handoff, sq-xo-safety, sq-pending-reply, sq-crew-state) green with the fork active.
- **M2 exit criteria:** met — packages exist with upstream tests green under Squad identity; zero kunchenguid in Go sources/manifests/URLs/CI (guard-verified); Go packages expose turbo tasks; fork builds with `sq-tasks-axi` name/bin and green tests; install scripts point at Squad-owned sources (OQ-03 placeholders, real URLs at M4).
- **M4 inputs recorded:** real Apple Team ID + umami site id (UMAMI_WEBSITE_ID kept from upstream) + telemetry host + Discord community badges (kept — upstream community links, flagged for commander decision) + Release asset wiring in `sq-install-fob.sh`/no-mistakes bootstrap.

### T-M1-11 — CI workflows ✅ (session 1; see commit e80322e)

### T-M1-01 — Mapping table frozen + guard skeleton ✅
- design.md §2 rows 1–20 verified against AD-015: all 16 mappings (firstmate→Squad, tagline, captain→commander, first mate→sergeant at arms, crewmate→operator, fleet→unit, ship→strike, scout→recon, secondmate→XO, treehouse→FOB, watch→sentry, wake-queue→stand-to queue, /ahoy→/reporting, /bearings→/sitrep, /stow→/debrief, fm-→sq-, FM_*→SQUAD_*, read-only boundary→the perimeter) + 4 keep-rows (AGENTS.md, CLAUDE.md symlink, .tasks.toml/.no-mistakes.yaml, .claude/skills symlink) match exactly. Table frozen as single source of truth; no edits without a context.md AD update.
- Drafted `tests/sq-rebrand-guard.test.sh` implementing all §8 guards: 5 content greps (firstmate tokens, upstream authors, \bfm-/\bfmx-, \bFM_, mapped-sense vocabulary patterns per §8.5 allowlist) + keep-list asserts (guard 6). Design choice: all guards accumulate violations and report the FULL hit list in one run (no premature exit), so the T-M1-12 gate shows everything remaining.
- **Verificado:** `bash -n` clean; guard runs via `bin/fm-test-run.sh` — currently RED by design with exactly the 5 expected violation groups (guards 1–5) and keep-list (guard 6) already green. Exit 1 = correct pre-sweep state; green only at T-M1-12.
- **Note:** adding this test grows the inventory to 133 sh tests; `--check-coverage` will report it as unpartitioned until T-M1-10 (runner/lane rebrand) — expected mid-sweep state.

### T-M0-01 — Repo init + gitignore ✅
- `git init -b main` at `/home/rehem/Projects/squad/`; `.gitignore` copied from `/tmp/firstmate-ref/.gitignore`.
- **Verificado:** `.gitignore` byte-identical to upstream (`cmp` clean); all 12 entries pass `git check-ignore` (projects/, state/, data/, .no-mistakes/, .lavish/, .fm-secondmate-home, .fm-secondmate-parent, .DS_Store, __pycache__/, *.pyc, .env, config/).
- **Interpretation note:** "git status clean" verified as: no untracked files beyond the intentional `.gitignore` + `.specs/` corpus (both destined for the single root commit, T-M0-03). The `.specs/` corpus is not gitignored by design (it is committed).
- Committed as part of the T-M0-03 root commit.

### T-M0-02 — Planning corpus ✅
- Staged `.specs/project/{PROJECT,ROADMAP}.md` + `.specs/features/squad-inception/{spec,context,design,tasks}.md` **+ `.specs/handoff-m0.md`** (7 files).
- **Verificado:** all six required artifacts present, English (AD-008; non-ASCII only in quoted user decision phrases "ou não"/"o produto será nosso"); AD-001 tokens (Squad, commander, sergeant at arms, operator, strike, recon, FOB, sentry, stand-to, SQUAD_) present across the corpus; `git ls-files .specs/` lists exactly the corpus.
- **Interpretation note:** the criterion names six files; `handoff-m0.md` (session-handoff prompt) is also corpus content and is included — documented deviation, no foreign files added. Flagged in final report.
- Committed as part of the T-M0-03 root commit (per ROADMAP W-M0-02: "committed as part of the initial commit", A-01).

### T-M0-03 — Squashed import, no history ✅
- Extracted tracked files from `/tmp/firstmate-ref` via `git archive HEAD | tar -x` (excludes `.git/` by construction; preserves symlinks).
- **Verificado:**
  - File set identical to ref: 374 = 372 regular files + 2 symlinks (`CLAUDE.md → AGENTS.md`, `.claude/skills → ../.agents/skills`); symlink chains resolve.
  - Content byte-identical (spot-checked AGENTS.md, .gitignore, bin/fm-test-run.sh).
  - Single root commit `7a63db7`, authored `Jonathan Rehem <jonathan.rehem@outlook.com>`; `git log --format='%an <%ae>'` → 0 hits for kunchenguid/Kun Chen; no co-authors.
  - `git status` clean.
- Test inventory confirmed: 132 `*.test.sh` + 1 `*.test.py` (+ 7 non-test helpers).

### T-M0-04 — Tooling presence ✅
- shellcheck: pinned 0.11.0 via `bin/fm-install-shellcheck.sh /tmp/sq-tools` (sha256-verified download, upstream pin).
- treehouse: v2.0.1 via `bin/fm-install-treehouse.sh /tmp/sq-tools` (pinned, sha256-verified).
- tasks-axi: 0.2.5 via `npm install -g tasks-axi` (CI-equivalent path; ≥ floor `FM_TASKS_AXI_MIN=0.2.4`).
- Local env additionally has: herdr 0.8.0 (mise), tmux 3.7b, python3 3.14.3.
- **Verificado:** `shellcheck --version` (0.11.0), `tasks-axi --version` (0.2.5), `treehouse --version` (v2.0.1). Install path documented: `/tmp/sq-tools` + npm global.
- No repo changes (tooling lives outside the repo; install scripts still upstream — rebranded in M1/M2).

### T-M0-05 — Baseline suite on pristine import ✅ (recorded, NOT fixed)
- Runner: `bin/fm-test-run.sh` (upstream) with `PATH=/tmp/sq-tools:$PATH`; throwaway homes per-test (runner unsets FM_HOME internally per script).
- **Finding 1 (environment, not source):** `--check-coverage` fails under ambient `LANG=en_US.UTF-8` — the runner sorts with `LC_ALL=C` but runs `comm` under the ambient collation; en_US.UTF-8 collation disagrees with C byte-order, so `comm` rejects the files. Upstream CI runs under C.UTF-8 (byte-order collation) where sort/comm agree. Workaround: `LC_ALL=C.UTF-8` (CI-equivalent; verified guard passes under both C and C.UTF-8).
- Coverage guard (C.UTF-8): `FM_TEST_COVERAGE ok total=132 parallel=24 serial=97 serial_shards=4 herdr=11` → complete partition, no missing/duplicates.
- **Run 1 (LC_ALL=C, UTF-8-blind):** 132 sh tests → 15 failed / 16 gate-skipped / 117 passed, duration ~37 min. The 16 skips are optional-binary gates (e.g., cmux CLI absent) — CI-equivalent (CI installs no cmux).
- **Run 2 (LC_ALL=C.UTF-8, CI-equivalent; rerun of the 15):** 4 fixed by locale (fm-afk-inject-e2e, fm-afk-inject-herdr-e2e, fm-backend-cmux, fm-backend-herdr) → **9 remain failing**, all classified:

| Test | Root cause | Class |
| --- | --- | --- |
| fm-backend.test.sh | `resolve_permissive_tmux_kill_ref` walks `git log --first-parent` for a historical tmux.sh with permissive selectors; squashed import = 1 commit → no historical ref (current file uses exact selectors) | **AD-010 consequence** → M1 test adaptation (T-M1-10) |
| fm-documentation-audiences.test.sh | `fm-doc-audience-check.sh` exits 1: the `.specs/` corpus is unclassified in `docs/documentation-audiences.json` | **A-01 corpus consequence** → M1: classify `.specs/` in the inventory |
| fm-bootstrap.test.sh | hermetic fixture expects node ABSENT from `/usr/bin`; Arch box has system nodejs 22.23.1 there | environment (system node) |
| fm-session-start.test.sh | same: MISSING: node diagnostic absent because `/usr/bin/node` resolves | environment (system node) |
| fm-on.test.sh | remote doctor expects herdr/tasks-axi/treehouse/harness MISSING on remote PATH; all installed locally | environment (tools present) |
| fm-remote-doctor.test.sh | `--fix` fixture expects no harness (claude/codex/grok) to resolve; machine has `/usr/bin/claude` + `~/.local/bin/codex` | environment (harnesses present) |
| fm-remote-job-orphan-reap.test.sh | fixture worker not reparented to init (PID 1) at check time (systemd/Arch, reparenting/race) | environment |
| fm-calm-pi-extension.test.sh | tmux 3.7b pane capture renders duplicate captain answer; different sub-case fails each run; most fixtures skip (pi package absent from npm global — `npm root -g` path) | environment (tmux rendering flake) |
| fm-watcher-lock.test.sh | arm HUP exit raced an 8s wait under load (got 124); **passes in isolation** (98s) | environment (timing flake) |

- **Baseline verdict:** 123/132 sh tests green under CI-equivalent locale; 9 failures 100% attributable to local environment (7) or our own locked decisions (2: AD-010, A-01); **zero genuine source defects**; py test (`fm-backend-herdr-eventwait.test.py`) exercised green via `fm-test-run.test.sh` (exit 0). Upstream CI (ubuntu-latest: no /usr/bin/node, no codex/claude, full git history, tmux <3.7) would run green modulo the two decision-consequence items, which the M1 sweep must adapt (recorded as M1 inputs, NOT fixed now — per plan).
- **Evidence:** raw logs `/tmp/sq-m0-baseline.log` (run 1) + `/tmp/sq-m0-rerun.log` (run 2); per-test reruns in `/tmp/single-*.log`. Recorded here (task log) instead of `docs/verification/` to respect "no source edits beyond import + planning artifacts".
- **M0 exit-criteria note:** criterion 4 ("suite runs green") holds with documented exceptions above; no silent pass — flagged to the commander in the session report.

## Decisions recorded (executor-level, no AD-* changes)
- D-EXEC-01: Root commit includes `.specs/handoff-m0.md` alongside the six named artifacts (corpus completeness).
- D-EXEC-02: Baseline runs under `LC_ALL=C.UTF-8` to mirror CI collation; en_US.UTF-8 `comm` failure recorded as environment issue; LC_ALL=C (UTF-8-blind) produces false failures — never use for the suite.
- D-EXEC-03: M0 evidence lives in STATE.md task log; no edits to pristine `docs/` before M1.
- D-EXEC-04: M0 marked done with criterion 4 ("suite runs green") holding modulo documented exceptions; two M1-input items recorded (fm-backend git-history test adaptation; `.specs/` classification in doc-audience inventory).


## Final acceptance (project-level)

- ✅ All §8 grep guards pass on the full tracked tree (repaired patterns; packages included) — 6/6.
- ✅ Full distro suite pass-set = M0 baseline + M1-input fixes; remaining local failures are the 6 recorded environment cases (node in /usr/bin, installed harnesses, systemd reparenting, tmux rendering flake); CI is the gate. `--check-coverage` ok (total=134).
- ✅ `turbo build` + `turbo lint` green across Go + TS packages; `turbo test` green except the no-mistakes procreap env case (fails identically on pristine upstream).
- ✅ pr-review (v1) and goal-loop-audit (v1.1) load and run in Pi; coexistence in one headless session verified; live pr-review demonstration documented as A-08 in docs/pr-review.md (needs a scratch repo PR).
- ✅ Publication paths proven up to the org boundary: Go release workflows + manifests carried and rebranded; `sq-tasks-axi` npm name verified available + publishConfig (public, provenance) + pack dry-run; install scripts point at Squad sources (OQ-03 placeholder); real Release fetch / npm publish / CI-green-on-real-PR / Apple Team ID + umami site id land when the org exists (OQ-03).
- ✅ ROADMAP open-item recorded ("ou não" TS port, AD-004).
- ✅ context.md updated: OQ-01 (module path) and OQ-02 (npm name) resolved; OQ-03 placeholder documented.

**Blocker:** none. **Remaining work is org-gated (OQ-03) and commander decisions (Discord community badges; real telemetry/Team ID values).**

## Blockers
- None.

## Open items / risks observed
- RISK-M0-01 (new): runner `--check-coverage` locale sensitivity (sort LC_ALL=C vs comm ambient collation). Environment-only; CI (C.UTF-8) unaffected. Decide in M1 whether to harden (e.g., export LC_ALL=C in runner) — traceable to T-M1-10 (runner rename task) if chosen.
- M1 input A: `tests/fm-backend.test.sh` needs a git-history-free adaptation (AD-010 squashed import breaks `resolve_permissive_tmux_kill_ref`; alternative: pin the permissive ref in a fixture file instead of walking history). Traceable to T-M1-10.
- M1 input B: `docs/documentation-audiences.json` must classify `.specs/` (or the check must scope to docs/), else `fm-doc-audience-check.sh` stays red. Traceable to T-M1-06.
- M1 input C (local machine only): system `/usr/bin/node` (nodejs 22), installed codex/claude, tmux 3.7b rendering, systemd reparenting — 7 env-attributable test failures will reappear locally unless run in a CI-like env; CI remains the gate.
- OQ-01..03 unchanged (module path / npm name / org URL land in M2/M4/M0-late).

## Lessons
- `git archive` is the cleanest squashed-import mechanism: tracked files only, symlinks preserved, `.git/` excluded by construction.
- The suite's coverage guard demands CI-identical collation; always export `LC_ALL=C.UTF-8` (NOT bare `LC_ALL=C`, which breaks UTF-8-aware parsing in tests) when running the inherited runner locally.
- Baseline failures on a dev machine are mostly "tool presence" noise: hermetic fixtures assume `/usr/bin` has no node and no harnesses. Classify before fixing; upstream CI env is the real gate.
