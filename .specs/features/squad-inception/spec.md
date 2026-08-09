# Squad Inception — Specification

**Scope:** Complex (multi-component: distro rebrand + 3 dep forks + 2 Runecraft integrations + publication)
**Prereq:** none (greenfield; reference clones at `/tmp/firstmate-ref`, `/tmp/dep-treehouse`, `/tmp/dep-no-mistakes`, `/tmp/dep-tasks-axi`, harness at `/home/rehem/Projects/harness`)
**Language:** English (AD-008)

## Problem Statement

A general-purpose coding agent is only one worker. firstmate (MIT) solves this with an agent-distro pattern — one liaison agent supervising a visible crew in disposable worktrees — but it carries an external identity (nautical theme, `fm-*`/`FM_*` naming, upstream author presence) and its runtime deps (treehouse, no-mistakes, tasks-axi) live in separate upstream repos with upstream authorship. The commander wants the *same mechanics* under a **Squad** identity: military theme, `sq-`/`SQUAD_*` naming, total removal of upstream author mentions, runtime deps forked into the monorepo, and Runecraft's pr-review (v1) + goal-loop-audit (v1.1) wired into the Pi-primary flow. The distro remains clone-based; Go deps keep their Go source with turbo-driven builds; only publication targets change (GitHub Releases for Go, npm for the tasks-axi fork).

## Goals

- [ ] G1 — Faithful rebranded fork: Squad identity across AGENTS.md, bin, skills, docs, adapters, `.pi`, tests; ~133 tests rebranded and green
- [ ] G2 — Deps as workspace packages (fob, no-mistakes, tasks-axi) built/tested via turbo
- [ ] G3 — Runecraft pr-review wired into the Pi-primary strike flow (v1, P1); goal-loop-audit (v1.1, P2)
- [ ] G4 — Publication: Go binaries → GitHub Releases; tasks-axi fork → npm; distro → git clone
- [ ] G5 — Commander-private hygiene (gitignore) + single squashed import with no upstream history

## Out of Scope

| Feature | Reason |
| --- | --- |
| TS port of Go deps | Explicitly open/optional ("ou não") — recorded on roadmap, NOT committed (AD-004) |
| npm tarball for the distro | Distro is consumed by git clone (AD-007) |
| New backends / task shapes / hard rules | Inherit firstmate mechanics, do not extend |
| Upstream sync workflow | Accepted cost after total-removal fork (RISK-03) |
| Upstream author attribution | Documented decision — total removal (AD-002); legal caveat flagged once |

## Requirement IDs

Requirements are grouped by milestone. Prefix: `REQ-M0-*` (import/scaffold), `REQ-M1-*` (rebrand), `REQ-M2-*` (deps), `REQ-M3-*` (Pi + pr-review), `REQ-M4-*` (publication/CI), `REQ-M5-*` (v1.1). Priority: P1 = required for v1, P2 = v1.1, P0 = blocking gate.

---

## M0 — Import & Scaffold

### REQ-M0-01 (P0) — Fresh repo, single squashed import

**User Story:** As commander, I want the Squad repo to start clean so the product is ours with no upstream history.

**Acceptance Criteria:**

1. WHEN `git -C /home/rehem/Projects/squad/ log` runs THEN it SHALL show exactly one root commit (the squashed import) with no upstream author identities anywhere in history
2. WHEN the import is inspected THEN source SHALL match the `/tmp/firstmate-ref` reference clone (depth-1) byte-for-byte except `.git/`
3. WHEN `.gitignore` is read THEN it SHALL cover `projects/ state/ data/ .no-mistakes/ .lavish/ .env config/` (commander-private)

**Independent Test:** `git log --format='%an <%ae>' | grep -ci 'kunchenguid\|kun chen'` returns 0; `git status --porcelain` clean.

### REQ-M0-02 (P0) — Planning corpus committed

**User Story:** As the team, I want the full planning corpus in-repo so decisions are traceable.

**Acceptance Criteria:**

1. WHEN `.specs/project/` is listed THEN `PROJECT.md` and `ROADMAP.md` SHALL exist
2. WHEN `.specs/features/squad-inception/` is listed THEN `spec.md`, `context.md`, `design.md`, `tasks.md` SHALL exist
3. WHEN each artifact is read THEN it SHALL be in English (AD-008) and consistent with the FINAL decisions in context.md

**Independent Test:** file existence + grep for a sample of FINAL decision tokens (Squad, commander, sergeant at arms, operator, strike, recon, FOB, sentry, stand-to queue, SQUAD_*).

### REQ-M0-03 (P0) — Baseline suite green on pristine import

**User Story:** As the team, I want proof the inherited mechanics are intact before rebranding so regressions are attributable to the sweep.

**Acceptance Criteria:**

1. WHEN the inherited test runner runs on the pristine import THEN the suite SHALL pass (record: pass count, shard partition proof, environment notes)
2. WHEN the runner is unavailable or fails THEN the failure SHALL be recorded as an import problem, not silently fixed

**Independent Test:** runner exit 0 on pristine import; evidence note in M0 task log.

---

## M1 — Rebrand Sweep

### REQ-M1-01 (P0) — Vocabulary applied repo-wide

**User Story:** As commander, I want every surface to speak Squad: commander, sergeant at arms, operators, unit, strike, recon, XO, FOB, sentry, stand-to queue, perimeter.

**Acceptance Criteria:**

1. WHEN the design.md §2 mapping table is applied to tracked content THEN the table SHALL be the single source of truth for term replacement
2. WHEN `grep -ri 'firstmate\|first mate\|captain\|crewmate\|fleet\|secondmate\|treehouse\|ahoy\|bearings\|stow\|wake-queue'` runs over tracked content (excluding `.specs/`), plus the mapped-sense patterns from design.md §8.5 (`\bship task\b`, `\bscout task\b`, `\bscout worktree\b`, `\bthe watch\b`, `watch\.sh`, `watcher-continuity`) THEN it SHALL return zero hits (vocabulary context-sensitive: natural-English `ship`/`watch`/`scout` outside the mapped-sense patterns are allowed — see design.md §2 note + §8.5 allowlist)
3. WHEN `AGENTS.md` is read THEN the identity SHALL be "You are the sergeant at arms. The user is the commander." with roles section updated (operators, XOs, unit)

**Independent Test:** grep guards above; `AGENTS.md` head matches Squad identity; `CLAUDE.md` still symlinks to `AGENTS.md` (REQ-M1-05).

### REQ-M1-02 (P0) — Env prefix `SQUAD_*`

**User Story:** As an operator, I want environment variables namespaced to Squad so multiple distros never collide.

**Acceptance Criteria:**

1. WHEN `FM_HOME` is searched in tracked content THEN it SHALL be replaced by `SQUAD_HOME` (and `FM_*`→`SQUAD_*` per design.md §3 table)
2. WHEN `bin/sq-harness.sh` (ex-`fm-harness.sh`) resolves the primary harness THEN the Pi marker `FM_PI_HARNESS` SHALL read `SQUAD_PI_HARNESS=pi-signed`
3. WHEN scripts run in a clean environment THEN they SHALL fail closed on missing `SQUAD_HOME` exactly as upstream fails on missing `FM_HOME`

**Independent Test:** `grep -r 'FM_'` over tracked content (excluding `.specs/`) → 0 hits (except documented keeps); `bin/sq-send.sh` without `SQUAD_HOME` exits nonzero with clear message.

### REQ-M1-03 (P0) — Script prefix `sq-` with vocab-in-name mapping

**User Story:** As an operator, I want script names that match the Squad vocabulary.

**Acceptance Criteria:**

1. WHEN `bin/` is listed THEN every `fm-*.sh` SHALL be renamed `sq-*.sh`; names containing mapped words SHALL use the mapped word (`fm-watch.sh`→`sq-sentry.sh`, `fm-wake-drain.sh`→`sq-stand-to-drain.sh`, `fm-spawn.sh`→`sq-spawn.sh`, `fm-teardown.sh`→`sq-teardown.sh`, `fm-pr-merge.sh`→`sq-pr-merge.sh`)
2. WHEN `bin/backends/` is listed THEN tmux/herdr/zellij/orca/cmux backends SHALL be present, unchanged in mechanism
3. WHEN scripts cross-reference siblings THEN all references SHALL point to the renamed scripts (no dangling `fm-*` calls)

**Independent Test:** `grep -r 'fm-' bin/` → 0 hits; every `sq-*.sh` referenced in AGENTS.md/docs exists (`bash -n` lint + reference checker task).

### REQ-M1-04 (P0) — Skills rebranded

**User Story:** As the sergeant at arms, I want the internal skills to speak Squad.

**Acceptance Criteria:**

1. WHEN `.agents/skills/` is listed THEN all 19 skills SHALL exist with rebranded content and internal names (dirs per design.md §2 rows 21–26: `updatefirstmate`→`updatesquad`, `fmx-respond`→`relay-respond`, `firstmate-*`→`squad-*`, `stuck-crewmate-recovery`→`stuck-operator-recovery`, `secondmate-provisioning`→`xo-provisioning`, `ahoy`→`reporting`, `bearings`→`sitrep`, `stow`→`debrief`; commands `/reporting`, `/sitrep`, `/debrief`; `metadata.internal=true` preserved)
2. WHEN `harness-adapters` skill is read THEN harness facts SHALL reference `sq-*` scripts, `SQUAD_*` env, and Pi/pi-signed as co-primary with claude/grok
3. WHEN public `skills/stow` is listed THEN it SHALL be renamed `skills/debrief` and installer-facing metadata updated

**Independent Test:** skill dir listing + grep guards; `skills/debrief` installable per upstream contract.

### REQ-M1-05 (P0) — Tooling-convention filenames kept

**User Story:** As the team, I want agent-tooling conventions preserved so tooling keeps working.

**Acceptance Criteria:**

1. WHEN the repo root is listed THEN `AGENTS.md` SHALL exist and `CLAUDE.md` SHALL be a symlink to it
2. WHEN `.tasks.toml` and `.no-mistakes.yaml` are read THEN their filenames SHALL be unchanged (tooling conventions); content SHALL be rebranded where it references `fm-*`/`FM_*`/firstmate
3. WHEN `.claude/skills` is checked THEN it SHALL remain a symlink to `.agents/skills`

**Independent Test:** symlink checks; grep guards on content.

### REQ-M1-06 (P0) — Tests rebranded and green

**User Story:** As the team, I want the full inherited suite kept, rebranded, and green in CI.

**Acceptance Criteria:**

1. WHEN `tests/` is listed THEN every `fm-*.test.sh` SHALL be renamed `sq-*.test.sh` (132 shell + 1 python test, per design.md §4 strategy)
2. WHEN test assertions are reviewed THEN they SHALL assert the Squad identity (script paths `bin/sq-*`, env `SQUAD_*`, vocab) — semantics byte-equivalent except identity
3. WHEN `sq-test-run.sh --check-coverage` runs THEN it SHALL prove the portable shards + serial lane partition the complete inventory with no missing/duplicate tests
4. WHEN the full suite runs THEN it SHALL be green (same pass set as the M0 baseline, modulo identity-related assertion updates)

**Independent Test:** coverage-guard exit 0; full suite exit 0; `grep -rl 'fm-' tests/` → 0 hits.

### REQ-M1-07 (P0) — Non-Pi harness adapters kept working

**User Story:** As commander, I want Claude Code, Grok, Codex, and OpenCode primaries to keep working after the rebrand.

**Acceptance Criteria:**

1. WHEN `.claude/`, `.codex/`, `.grok/hooks/`, `.opencode/plugins/` are inspected THEN hook/plugin mechanics SHALL be unchanged and every `fm-*`/`FM_*`/firstmate reference SHALL be rebranded to `sq-*`/`SQUAD_*`/Squad
2. WHEN a non-Pi primary starts a session THEN session-start/watcher/turn-end guard paths SHALL resolve to the renamed scripts

**Independent Test:** grep guards per adapter dir; smoke: claude Stop-hook re-arm path resolves `bin/sq-claude-stop-autoarm.sh`; opencode plugin resolves `bin/sq-watch-arm.sh`.

### REQ-M1-08 (P0) — Pi primary via adapted tracked extensions

**User Story:** As commander, I want Pi to remain a co-primary Squad harness.

**Acceptance Criteria:**

1. WHEN `.pi/extensions/` is listed THEN `fm-primary-turnend-guard.ts` and `fm-primary-pi-watch.ts` (and lib modules) SHALL be renamed/adapted to `sq-*` with identity rebranded
2. WHEN a Pi session loads the repo THEN the tracked extensions SHALL auto-discover and the turn-end guard + watcher protocols SHALL work as upstream

**Independent Test:** headless Pi session smoke per design.md §6; extension files present; grep guards.

### REQ-M1-09 (P0) — Docs, README, CONTRIBUTING rebranded

**User Story:** As commander, I want all prose to carry the Squad identity and no upstream author mentions.

**Acceptance Criteria:**

1. WHEN `docs/` is swept THEN architecture.md, configuration.md, backend docs, supervision-protocols, verification evidence SHALL be rebranded (vocab, env, script names) with mechanism text preserved
2. WHEN README.md is read THEN tagline SHALL be "Talk to one agent. Deploy with a squad."; badges/links SHALL NOT reference upstream author handles/servers; quick-start SHALL reference `git clone` of the Squad repo
3. WHEN CONTRIBUTING.md and assets are swept THEN no upstream author mention SHALL remain (AD-002)

**Independent Test:** grep guards incl. `kunchenguid`, `@kunchenguid`, upstream Discord/X links; README tagline match.

### REQ-M1-10 (P0) — CI workflows rebranded

**User Story:** As the team, I want CI to run the Squad suite.

**Acceptance Criteria:**

1. WHEN `.github/workflows/ci.yml` is read THEN lint (shellcheck via `bin/sq-lint.sh`), coverage guard (`sq-test-run.sh --check-coverage`), and portable parallel shards SHALL reference `sq-*` scripts
2. WHEN `.github/workflows/no-mistakes-required.yml` is read THEN PR-body compliance SHALL use the forked no-mistakes binary
3. WHEN a PR is opened on the Squad repo THEN CI SHALL run green on the rebranded suite

**Independent Test:** CI run on M1 completion; workflow YAML grep guards.

### REQ-M1-11 (P2) — Private-material seeds rebranded

**User Story:** As commander, I want the private data layout to speak Squad.

**Acceptance Criteria:**

1. WHEN `sq-home-seed.sh`-owned private material is generated THEN `data/captain.md`→`data/commander.md`, `data/captain-shared.md`→`data/commander-shared.md`, `data/secondmates.md`→`data/XOs.md` (per vocab table) SHALL be created with rebranded prose
2. WHEN `.tasks.toml` content is generated THEN backlog path SHALL remain `data/backlog.md`

**Independent Test:** seed run in a throwaway `SQUAD_HOME`; file inventory matches.

---

## M2 — Deps as Workspace Packages

### REQ-M2-01 (P0) — fob (ex-treehouse) as Go workspace package

**User Story:** As the team, I want the worktree-pool CLI forked into the monorepo with turbo-driven builds.

**Acceptance Criteria:**

1. WHEN `packages/fob/` is inspected THEN it SHALL contain the treehouse source with module path renamed (AD-005 default: no `kunchenguid` in `go.mod`), upstream tests green
2. WHEN the root `turbo.json`/stub `package.json` build task runs THEN `go build ./...` SHALL succeed and produce the `sq-fob`/`fob` binary
3. WHEN `sq-install-fob.sh` (ex-`fm-install-treehouse.sh`) is read THEN install SHALL fetch from Squad-owned sources (GitHub Releases, M4)

**Independent Test:** `turbo build --filter=fob` exit 0; `go test ./...` green; `grep -r kunchenguid packages/fob` → 0 hits.

### REQ-M2-02 (P0) — no-mistakes as Go workspace package

**User Story:** As the team, I want the CI gate forked into the monorepo.

**Acceptance Criteria:**

1. WHEN `packages/no-mistakes/` is inspected THEN it SHALL contain the no-mistakes source with module path renamed, upstream tests green (incl. workflow_*.go tests)
2. WHEN the turbo build task runs THEN the `no-mistakes` binary SHALL build
3. WHEN `.no-mistakes.yaml` gate + `sq-gate-refuse-lib.sh` run THEN they SHALL invoke the forked binary

**Independent Test:** `turbo build --filter=no-mistakes` exit 0; `go test ./...` green; grep guards.

### REQ-M2-03 (P0) — tasks-axi fork as npm workspace package

**User Story:** As the team, I want the backlog CLI forked, renamed, and publishable.

**Acceptance Criteria:**

1. WHEN `packages/tasks-axi/` is inspected THEN it SHALL contain the tasks-axi source with npm `name` and `bin` renamed (AD-006 default: `sq-tasks-axi`), upstream tests green
2. WHEN `build` + `test` run THEN dist output SHALL be produced and the suite green
3. WHEN `sq-tasks-axi-lib.sh` (ex-`fm-tasks-axi-lib.sh`) is read THEN it SHALL invoke the forked CLI

**Independent Test:** build+test exit 0; `npm pack --dry-run` lists renamed artifacts; grep guards.

### REQ-M2-04 (P0) — No upstream identity in packages or wiring

**User Story:** As commander, I want zero upstream author presence in the forks.

**Acceptance Criteria:**

1. WHEN tracked content under `packages/` + distro wiring is grepped THEN `kunchenguid`, upstream URLs, and upstream author names SHALL be absent (AD-002)
2. WHEN CHANGELOG/README of each fork is swept THEN no author mention SHALL remain

**Independent Test:** repo-wide grep guard (design.md §8).

---

## M3 — Pi Adapters + pr-review Integration

### REQ-M3-01 (P0) — @runecraft/pr-review as workspace package

**User Story:** As the team, I want pr-review vendored into the monorepo.

**Acceptance Criteria:**

1. WHEN `packages/pr-review/` is inspected THEN it SHALL contain the pinned `@runecraft/pr-review` source (from runecraft-ai/harness, provenance recorded), tests green
2. WHEN a Pi session loads it THEN the extension SHALL register without errors (peer deps satisfied via workspace)

**Independent Test:** `bun test` green; headless Pi load smoke; provenance record file present.

### REQ-M3-02 (P0) — pr-review wired into the Pi-primary strike flow

**User Story:** As the sergeant at arms, I want a landed strike PR reviewed by parallel tiered subagents before it reaches the commander.

**Acceptance Criteria:**

1. WHEN a strike (ship task) produces a PR THEN the integration SHALL invoke `@runecraft/pr-review` (via `.pi/extensions/sq-pr-review.ts` + `bin/sq-pr-review.sh`)
2. WHEN review findings exist THEN they SHALL be published COMMENT-only and surfaced to the commander; the integration SHALL NEVER auto-merge or auto-approve
3. WHEN invoked outside a repo/PR context or without `gh` auth THEN it SHALL fail with a clear message, not crash the session

**Independent Test:** headless Pi smoke with a test PR (1× live validation documented — not a CI gate); unit checks of the wrapper's argument/guard paths.

### REQ-M3-03 (P2) — v1.1 goal-loop-audit integration (M5)

**User Story:** As the sergeant at arms, I want long-running goal loops supervised with an isolated auditor.

**Acceptance Criteria:**

1. WHEN `packages/goal-loop-audit/` is vendored (M5) THEN it SHALL be pinned from runecraft-ai/harness with provenance, tests green
2. WHEN wired via Pi extension + bin script THEN goal loops SHALL run with the isolated auditor on completion, coexisting with pr-review in one session (validated, not presumed)

**Independent Test:** bun test green; coexistence smoke; wiring smoke per design.md §6.

---

## M4 — Publication & CI

### REQ-M4-01 (P0) — CI matrix green

**User Story:** As the team, I want one CI that proves the whole monorepo.

**Acceptance Criteria:**

1. WHEN CI runs on main/PR THEN lint, coverage guard, portable shards, Go build+test (fob, no-mistakes), and tasks-axi build+test SHALL all pass (design.md §7 matrix)
2. WHEN the matrix is compared to upstream ci.yml THEN every upstream job SHALL have a rebranded equivalent plus the new Go/npm jobs

**Independent Test:** CI green run recorded at M4 completion.

### REQ-M4-02 (P0) — Go binaries to GitHub Releases

**User Story:** As the team, I want commander-ready binaries published from CI.

**Acceptance Criteria:**

1. WHEN a release tag is cut THEN CI SHALL build fob + no-mistakes binaries (linux/macos) and attach them to the GitHub Release
2. WHEN `sq-install-fob.sh` and the no-mistakes bootstrap run on a fresh machine THEN they SHALL fetch the Squad release assets (no upstream URLs)

**Independent Test:** release dry-run in a scratch repo; install-from-release smoke on a throwaway `SQUAD_HOME`.

### REQ-M4-03 (P0) — tasks-axi fork to npm

**User Story:** As the team, I want the backlog CLI installable from npm under the Squad name.

**Acceptance Criteria:**

1. WHEN the fork is published THEN the npm package SHALL be the renamed fork (AD-006 name verified available before publish) with provenance
2. WHEN `sq-home-seed.sh`/`sq-tasks-axi-lib.sh` resolve the CLI THEN they SHALL prefer the forked package

**Independent Test:** publish dry-run (`pnpm/bun publish --dry-run`); install from registry in a throwaway env.

### REQ-M4-04 (P0) — Distro clone consumption + docs

**User Story:** As commander, I want the quick start to work from a plain clone.

**Acceptance Criteria:**

1. WHEN README quick start is followed on a fresh machine THEN `git clone` → bootstrap → spawn → operator lands a change in a scratch project SHALL succeed end-to-end
2. WHEN the release docs are read THEN publication paths SHALL match AD-007 (Go→Releases, tasks-axi→npm, distro→clone)

**Independent Test:** end-to-end smoke recorded (M4-04 task); docs grep guards.

---

## M5 — v1.1 + Roadmap Note

### REQ-M5-01 (P2) — goal-loop-audit shipped

**User Story:** As commander, I want the v1.1 Runecraft capability live.

**Acceptance Criteria:**

1. WHEN M5 completes THEN `packages/goal-loop-audit/` SHALL be vendored, tested, and wired (REQ-M3-03 acceptance)
2. WHEN the roadmap is read THEN the TS-port entry SHALL be explicitly open/optional ("ou não") and NOT committed (AD-004)

**Independent Test:** M5 task verifications; ROADMAP grep for the open-item marker.

---

## Traceability

| Requirement | Milestone | Priority | Work package(s) | Depends on |
| --- | --- | --- | --- | --- |
| REQ-M0-01..03 | M0 | P0 | W-M0-01..05 | — |
| REQ-M1-01..11 | M1 | P0 (11 = P2) | W-M1-01..12 | REQ-M0-* |
| REQ-M2-01..04 | M2 | P0 | W-M2-01..05 | REQ-M0-* (parallel to M1 where independent) |
| REQ-M3-01..02 | M3 | P0 | W-M3-01..04 | REQ-M1-08 |
| REQ-M3-03 / REQ-M5-01 | M5 | P2 | W-M5-01..03 | REQ-M3-02 pattern |
| REQ-M4-01..04 | M4 | P0 | W-M4-01..04 | REQ-M1-*, REQ-M2-* |

## Success Criteria (project-level)

1. Repo-wide grep guards pass: no `fm-`/`FM_`/`firstmate`/`kunchenguid`/upstream author tokens in tracked content (documented keeps + legal caveat in `.specs/` only)
2. Full test suite green in CI with the same coverage as the M0 baseline (all ~133 tests kept)
3. `turbo build`/`turbo test` green across Go + TS workspace packages
4. pr-review + goal-loop-audit load and run in a headless Pi session; strike-flow review demonstrated once live
5. Publication paths proven: Go releases, npm package, clone-based distro
6. Roadmap carries the explicit open/optional TS-port entry (AD-004)
