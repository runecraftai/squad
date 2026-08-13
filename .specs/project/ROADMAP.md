# Roadmap — Squad

**Current Milestone:** M6 — Vendoring the AXI Toolchain (DELIVERED)
**Status:** M0–M6 executed; M6 implemented 2026-08-10 and delivered as a PR for commander review.

Dependency chain: **M0 → M1 → {M2, M3} → M4** · **M5 ∥ M4** (M5 depends on M3's wiring pattern only) · **M6** (after M5)

Legend: ✅ done · ▶️ in progress · ⬜ planned

---

## M0 — Import & Scaffold — ✅ DONE

**Goal:** The Squad repo exists at `/home/rehem/Projects/squad/` with a single squashed firstmate import (no history), planning artifacts committed, and the inherited test suite green as a pre-rebrand baseline.

**Exit criteria:**

- Fresh git repo; one squashed import commit; `git log` shows no upstream author identities
- `.specs/project/{PROJECT,ROADMAP}.md` + `.specs/features/squad-inception/{spec,context,design,tasks}.md` committed
- `.gitignore` covers `projects/ state/ data/ .no-mistakes/ .lavish/ .env config/` (commander-private)
- Inherited test suite runs green on the pristine import (baseline proof before any rebrand)
- No source edits beyond import + planning artifacts (identity untouched yet)

### Work packages

- **W-M0-01** — Repo init: `squad/` git init, root files, gitignore (captain-private hygiene)
- **W-M0-02** — Planning corpus: PROJECT.md, ROADMAP.md, feature artifacts (this directory) committed as part of the initial commit
- **W-M0-03** — Squashed import of firstmate (depth-1 reference clone at `/tmp/firstmate-ref`), no history; `.git` of the clone excluded
- **W-M0-04** — Tooling presence check: shellcheck pin, tasks-axi, treehouse (for tests that exercise FOB) available to CI/local runners
- **W-M0-05** — Baseline validation: run the full inherited suite via the upstream runner; record results; fix nothing yet (any failure = import problem, not rebrand)

---

## M1 — Rebrand Sweep — ✅ DONE

**Goal:** Everything in the distro speaks Squad. Vocabulary, `SQUAD_*` env, `sq-` prefix, AGENTS.md contract, skills, docs, README, adapters, `.pi` extensions, and the test suite are fully rebranded; the suite is green under the new names.

**Exit criteria:**

- `grep -r "firstmate\|first mate\|fm-\|FM_"` over tracked content yields zero hits (except documented tooling-convention keeps and the single legal caveat in `.specs/`)
- All ~133 tests renamed `sq-*.test.sh` and green; `sq-test-run.sh --check-coverage` passes (complete partition proof)
- Non-Pi adapters (`.claude/ .codex/ .grok/ .opencode/`) still function, now referencing `sq-*` hooks
- Pi primary uses adapted tracked extensions (`.pi/extensions/sq-*.ts`)
- `AGENTS.md`, `CLAUDE.md` (symlink), `.tasks.toml`, `.no-mistakes.yaml` filenames KEPT (tooling convention)

### Work packages (rebrand sweep order — dependency-aware, see design.md §2)

- **W-M1-01** — Vocabulary source of truth: full mapping table frozen in design.md §2; used by every sweep task
- **W-M1-02** — `AGENTS.md` operating contract (identity, roles, hard rules, env, layout, sections)
- **W-M1-03** — `bin/` scripts: mechanical `fm-`→`sq-` rename + `FM_*`→`SQUAD_*` + vocab-in-name mapping (e.g., `fm-watch.sh`→`sq-sentry.sh`)
- **W-M1-04** — Internal cross-references inside scripts (calls to sibling scripts, state filenames, env reads)
- **W-M1-05** — `.agents/skills/` (19 skills; dir renames per design.md §2 rows 21–26 incl. `updatefirstmate`→`updatesquad`, `fmx-respond`→`relay-respond`, `stuck-crewmate-recovery`→`stuck-operator-recovery`; `/ahoy`→`/reporting`, `/bearings`→`/sitrep`, `/stow`→`/debrief`; harness-adapters facts)
- **W-M1-06** — `docs/` (architecture.md, configuration.md, backend docs, supervision-protocols, verification evidence)
- **W-M1-07** — README.md, CONTRIBUTING.md, assets (badges/links/banner), public `skills/stow`→`skills/debrief`
- **W-M1-08** — Non-Pi adapter dirs (`.claude/ .codex/ .grok/ .opencode/` — hooks, plugins, package.json refs)
- **W-M1-09** — `.pi/extensions/` tracked extensions (`fm-primary-*`→`sq-primary-*`, lib modules)
- **W-M1-10** — Tests: filename rename + assertion/content rebrand; keep semantics byte-equivalent except identity
- **W-M1-11** — CI workflows (`.github/workflows/`) rebranded refs
- **W-M1-12** — Private-material seeds (`sq-home-seed.sh` etc. create `commander.md`, `XOs.md`… under data/) + full-suite green + grep guards

---

## M2 — Deps as Workspace Packages — ✅ DONE

**Goal:** The three runtime deps are first-class packages in the monorepo, built and tested by turbo, with no upstream identity.

**Exit criteria:**

- `packages/fob/` (Go, ex-treehouse), `packages/no-mistakes/` (Go), `packages/tasks-axi/` (TS) exist; upstream tests green under Squad identity
- No `kunchenguid` reference anywhere in Go sources, manifests, URLs, or CI
- Go packages expose turbo tasks via private stub `package.json` (`build`/`test`/`lint`) — turbo drives `go build`/`go test`
- `tasks-axi` fork builds with its own npm name and bin (`sq-tasks-axi`), test suite green
- Distro install scripts (`sq-install-fob.sh`, no-mistakes bootstrap) point at Squad-owned sources/Releases

### Work packages

- **W-M2-01** — Go workspace scaffold: `packages/{fob,no-mistakes}` private stub package.json + turbo wiring + Go module path rename (AD-005: new module path is an open decision; default `github.com/runecraftai/squad/…` — never `kunchenguid`)
- **W-M2-02** — Fork `fob` (treehouse): copy, module rename, internal identity sweep, tests green
- **W-M2-03** — Fork `no-mistakes`: copy, module rename, identity sweep (skill/, scripts/, docs, workflows), tests green
- **W-M2-04** — Fork `tasks-axi`: copy, npm rename + bin rename, package identity sweep, build+test green (pnpm or bun)
- **W-M2-05** — Distro↔dep wiring: `sq-install-*` scripts fetch from Squad Releases; `.no-mistakes.yaml` gate uses the forked binary; backlog backend uses forked tasks-axi

---

## M3 — Pi Adapters + pr-review Integration — ✅ DONE

**Goal:** Pi is a first-class Squad primary with adapted tracked extensions, and `@runecraft/pr-review` runs inside the Pi-primary strike flow.

**Exit criteria:**

- `.pi/extensions/` adapted extensions load in a Pi session (turn-end guard, primary watcher)
- `@runecraft/pr-review` vendored as `packages/pr-review/` workspace package (pinned from runecraft-ai/harness), tests green, loads in Pi
- Wiring: a `sq-pr-review` extension + bin wrapper invoke parallel tiered review on a landed strike PR; findings are COMMENT-only and surfaced to the commander; never auto-merges
- Documented 1× live validation against a test repo (requires `gh` auth; not a CI gate)

### Work packages

- **W-M3-01** — Adapt remaining Pi touchpoints (session-start, watcher, turn-end guard) to `sq-*` identity; verify in a headless Pi session
- **W-M3-02** — Vendor `@runecraft/pr-review` into `packages/pr-review/` (source tarball pin, provenance record), workspace registration, tests green
- **W-M3-03** — Integration layer: `.pi/extensions/sq-pr-review.ts` + `bin/sq-pr-review.sh`; hook point in the strike (ship) flow after PR creation
- **W-M3-04** — Docs + 1× live validation record; failure modes (no repo, no PR, no `gh` auth) fail with clear messages

---

## M4 — Publication & CI — ✅ DONE (org-gated boundaries recorded in STATE.md)

**Goal:** Everything builds and ships from the Squad monorepo.

**Exit criteria:**

- CI matrix green: lint (shellcheck via `sq-lint.sh`), test-coverage guard, portable parallel shards, Go build/test, tasks-axi build+test
- Go binaries built in CI and published to GitHub Releases (release-please flow, no upstream URLs)
- `tasks-axi` fork published to npm (name verified available — AD-006) with provenance
- README quick start works from a plain `git clone` (distro consumption path)
- Version bump/commit hygiene (no author co-authors) enforced by workflow

### Work packages

- **W-M4-01** — CI matrix consolidation (mirrors upstream ci.yml, rebranded + Go jobs + tasks-axi job)
- **W-M4-02** — Go release pipeline (release-please manifests carried over; binary assets to Releases)
- **W-M4-03** — npm publish pipeline for tasks-axi fork (pnpm/bun publish, `publishConfig`, provenance)
- **W-M4-04** — Distro install docs + end-to-end smoke: fresh clone → bootstrap → spawn operator → land a change in a scratch project

---

## M5 — goal-loop-audit (v1.1) + TS-Port Note — ✅ DONE

**Goal:** Runecraft v1.1: `@runecraft/goal-loop-audit` integrated; roadmap records the optional TS port.

**Exit criteria:**

- `@runecraft/goal-loop-audit` vendored as `packages/goal-loop-audit/`, tests green, loads in Pi alongside pr-review (coexistence validated)
- Wired via Pi extension layer + bin script into a Squad flow (long-running goal loops supervised with isolated auditor)
- ROADMAP carries an explicit **open/optional** entry: TS port of the Go deps ("ou não") — NOT committed, revisit decision only at commander's request

### Work packages

- **W-M5-01** — Vendor goal-loop-audit (pin + provenance), workspace registration, tests green
- **W-M5-02** — Integration layer (extension + bin) + coexistence validation with pr-review
- **W-M5-03** — Roadmap note: TS port as future/open item; documentation update
**Open/optional item (NOT committed — AD-004):** a TS port of the Go deps (`fob` worktree pool, `no-mistakes` gate) is deliberately out of scope ("ou não", commander decision). The Go packages are private workspace packages with turbo tasks and ship via GitHub Releases; revisit this decision only at the commander's explicit request. No design or tasks exist for the port.

**Cut decision (2026-08-10, commander):** `@runecraft/goal-loop-audit` (Runecraft v1.1) is removed from the distro "for now" — `packages/goal-loop-audit/` and `.pi/extensions/sq-goal-loop-audit.ts` deleted; drill/no-mistakes and pr-review stay. This deliberately reverses the M5 vendoring decision; the M5 records above (W-M5-01..03) and the T-M5-01..03 task log in STATE.md stay as history, not as an erasure.

**Re-add path (provenance):** re-vendor `@runecraft/goal-loop-audit` **v0.28.34** (the M5 pin, upstream v1.1) from `https://github.com/runecraft-ai/harness/tree/main/packages/goal-loop-audit` via a tracked-file copy (extraction date 2026-08-09; write `vendor.json` with source URL, tag, sha256 of package.json + source), restore `.pi/extensions/sq-goal-loop-audit.ts` (bootstraps `extensions/loops/goal.ts`), register the package's docs in `docs/documentation-audiences.json`, and re-run the M5 coexistence validation (goal-loop-audit + pr-review in one Pi session). No code changes are required outside those pieces — the root workspace glob, turbo graph, and Pi extension auto-discovery pick it back up unchanged.


---

## M6 — Vendoring the AXI Toolchain — ✅ DONE

**Goal:** The remaining kunchenguid-ecosystem runtime tools are vendored into the monorepo under the commander's FINAL naming convention (no `-axi` anywhere), the M2 `tasks-axi` fork is renamed to `sq-tasks`, bootstrap installs the whole toolchain from the workspace, CI covers the new packages, and the unlanded pr-review fix ships.

**Exit criteria:**

- `packages/{sq-gh, sq-browser, sq-quota, sq-report}` exist (ex gh-axi / chrome-devtools-axi / quota-axi / lavish-axi, pinned), upstream suites green in-workspace, `vendor.json` provenance per package
- `packages/tasks-axi` renamed → `packages/sq-tasks` (pkg `sq-tasks`, bin `sq-tasks`, lib `bin/sq-tasks-lib.sh`); `SQUAD_TASKS_AXI_MIN` kept as durable contract
- `sq-bootstrap.sh` detects/installs the toolchain from the workspace (no upstream npm URLs); floors `GH_AXI_MIN=0.1.30`, `LAVISH_AXI_MIN=0.1.48`, `SQUAD_QUOTA_AXI_MIN=0.1.20`; `SQUAD_TASKS_AXI_MIN=0.2.4` unchanged
- CI: new `axi-tools` matrix job (build+test+pack check for the 4 new packages); `tasks-axi` job renamed `sq-tasks` with the protocol alias kept
- pr-review fix (`pr_review_verify` schema) committed and verified; sync-on-demand procedure + deferred-rebrand pointer recorded
- M6 name-surface guard green; old tool names absent from name-surfaces

### Work packages

- **W-M6-01** — Vendor 4 tools: `packages/sq-gh` (gh-axi v0.1.30), `packages/sq-browser` (chrome-devtools-axi v0.1.29), `packages/sq-quota` (quota-axi v0.1.20), `packages/sq-report` (lavish-axi v0.1.48) — M2 pattern + provenance
- **W-M6-02** — Rename `packages/tasks-axi` → `packages/sq-tasks` (pkg/bin/lib + CI + resolver); floors retargeted
- **W-M6-03** — Bootstrap wiring (workspace installs) + distro call-site/test sweep
- **W-M6-04** — CI additions (axi-tools matrix job; sq-tasks job rename)
- **W-M6-05** — Ship the pr-review fix + M6 name guard + full gates
- **W-M6-06** — Planning records (this section) + sync-on-demand procedure

**Roadmap note (deferred rebrand):** per commander decision (2026-08-10), M6 renames **names only** (directories, packages, binaries, file paths). Internal prose/strings — help text, TOON output, package READMEs, AGENTS.md/docs mentions, AXI-compliant terminology, env/constant names, `config/backlog-backend=tasks-axi` and the procevent `lavish` protocol ids — are **deferred** to backlog item **roadmap-futuro-rebrand-completo-de-menco-31** ("rebrand completo de menções internas das ferramentas vendored"). That item also retires the M6 name-guard keep-list. No date committed; scheduled after the main M6 delivery.

**Delivered (2026-08-10):** all exit criteria above met — 4 tools vendored with `vendor.json` provenance, `packages/tasks-axi` renamed to `packages/sq-tasks` (pkg/bin/lib + resolver + `vendor.json` backfill), bootstrap installs the whole toolchain from the workspace with floors `GH_AXI_MIN=0.1.30` / `LAVISH_AXI_MIN=0.1.48` / `SQUAD_QUOTA_AXI_MIN=0.1.20` / `SQUAD_TASKS_AXI_MIN=0.2.4` (unchanged), CI `axi-tools` matrix job added and `tasks-axi` job renamed `sq-tasks` (protocol alias kept), pr-review `pr_review_verify` schema fix committed with regression coverage, sync-on-demand procedure recorded in umbrella design.md §9, and `tests/sq-m6-name-guard.test.sh` green. Upstream suites green in-workspace (sq-gh 892, sq-browser 442, sq-quota 411, sq-report 744, sq-tasks 429/1); turbo build/test/lint green; `bin/sq-lint.sh` clean; distro regression batch green. Delivered on branch `fm/m6-executar-vendoring-da-toolchain-no-mo-3b` through the M6 strike pipeline.

**Reviewed 2026-08-13 (post-delivery corrections — see `.specs/features/squad-m6-vendoring/context.md` "Post-delivery review"):** PR #16 (2026-08-11) reset every workspace package and all four AXI floors to a clean **0.1.0** baseline (incl. `SQUAD_TASKS_AXI_MIN`, superseding the durable 0.2.4 claim), re-classified pr-review from vendored to maintained, and un-vendored its `vendor.json`/upstream identity fields; PR #8 (2026-08-10) renamed `no-mistakes` to `drill` (`packages/drill`, `DRILL_MIN=1.31.2`); goal-loop-audit was cut (commander decision 2026-08-10, PR #3); PR #25 (2026-08-13) scrubbed packaged-skill dirs to the `sq-*` names and retired the guard's packages/ keep-list; PR #24 trimmed sq-report third-party notices; PR #26 builds vendored `fob` from source. The four optional legacy aliases (`gh-axi`→`sq-gh` etc.) were not created — only the mandatory `tasks-axi` protocol alias exists. The exit criteria above describe the 2026-08-10 delivery state; the reviewed artifacts (spec/context/design/tasks) carry the current facts.


## Post-v1.1 (recorded, NOT committed)

- **TS port of Go deps** (`fob`, `drill` — renamed from `no-mistakes` in PR #8) — explicitly "ou não": recorded as open/optional; no design, no tasks, no dates.
- Upstream sync process — blocked by total-removal fork (diff noise); open risk, revisit if upstream adopts useful mechanics.
- New squad mechanics (backends, task shapes) — out of scope by design; inherit, don't extend.
