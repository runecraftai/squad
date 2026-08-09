# Squad Inception — Tasks

**Base:** design.md §1–§10 · context.md AD-001..AD-015 (all locked) · spec.md REQ-M0-01..REQ-M5-01
**Executor notes:** never write to the reference clones or the harness repo; never touch upstream `.git/`; run everything in `/home/rehem/Projects/squad/` and throwaway `SQUAD_HOME`s. Open decisions OQ-01..03: pick the recommended default, record it in context.md, and continue — do not block.
**Safety valve:** if any M1 task reveals >5 unexpected steps or new interdependencies, STOP and extend this file before continuing (Tasks phase re-entry).

---

## M0 — Import & Scaffold (REQ-M0-01..03)

### T-M0-01 — Repo init + gitignore (REQ-M0-01 AC3)
- [ ] `mkdir -p /home/rehem/Projects/squad`; `git init`
- [ ] Root `.gitignore` covering (copied from upstream ref): `projects/ state/ data/ .no-mistakes/ .lavish/ .fm-secondmate-home .fm-secondmate-parent .DS_Store __pycache__/ *.pyc .env config/` (commander-private, AD-011)
- [ ] **Verificar:** `git status --porcelain` clean after ignoring; `.gitignore` entries match upstream ref byte-for-byte (same set, no additions)

### T-M0-02 — Planning corpus (REQ-M0-02)
- [ ] Commit `.specs/project/{PROJECT,ROADMAP}.md` + `.specs/features/squad-inception/{spec,context,design,tasks}.md` (already present in this tree) as part of the initial commit
- [ ] **Verificar:** all six files present, English (AD-008), tokens from AD-001 (Squad, commander, sergeant at arms, operator, strike, recon, FOB, sentry, stand-to queue, SQUAD_*) present; `git ls-files .specs/` lists exactly these

### T-M0-03 — Squashed import, no history (REQ-M0-01 AC1/AC2, AD-010)
- [ ] Copy tracked files from `/tmp/firstmate-ref` (depth-1 clone) into the repo root, EXCLUDING `.git/` (372-file set: AGENTS.md, bin/, .agents/, .claude/, .codex/, .grok/, .opencode/, .pi/, docs/, skills/, tests/, .github/, README.md, CONTRIBUTING.md, LICENSE, .tasks.toml, .no-mistakes.yaml, assets/, CLAUDE.md symlink, .claude/skills symlink)
- [ ] Preserve symlinks: `CLAUDE.md → AGENTS.md`, `.claude/skills → ../.agents/skills`
- [ ] Single root commit authored by the Squad owner (no upstream co-authors)
- [ ] **Verificar:** `git log` shows exactly 1 commit; `git log --format='%an <%ae>'` contains no `kunchenguid`/`Kun Chen`; `git status` clean; file count matches reference (372); symlinks intact (`test -L CLAUDE.md && test -L .claude/skills`)

### T-M0-04 — Tooling presence (REQ-M0-03 prerequisite)
- [ ] Verify shellcheck pin installs (`bin/fm-install-shellcheck.sh`), forked tools available for tests that need them (tasks-axi, treehouse)
- [ ] **Verificar:** `shellcheck --version` pinned; `tasks-axi --version` works; `treehouse` binary present or install path documented

### T-M0-05 — Baseline suite green on pristine import (REQ-M0-03)
- [ ] Run the inherited suite via the upstream runner (`bin/fm-test-run.sh`) in a throwaway `FM_HOME`; record pass/fail counts + shard-coverage proof in the task log
- [ ] If failures: record them as import problems (environment/tooling), do NOT fix source
- [ ] **Verificar:** runner exit 0; evidence note committed under `docs/verification/` (or task log if CI lacks the env); baseline recorded for M1 comparison

---

## M1 — Rebrand Sweep (REQ-M1-01..11)

### T-M1-01 — Mapping table frozen (REQ-M1-01 AC1)
- [ ] Confirm design.md §2 table is the single source of truth; no edits after this task without a context.md AD update
- [ ] **Verificar:** table rows 1–20 match AD-015; grep guard list (§8) drafted as `tests/sq-rebrand-guard.test.sh` skeleton

### T-M1-02 — AGENTS.md operating contract (REQ-M1-01 AC3, REQ-M1-02/03 refs)
- [ ] Identity block: "You are the sergeant at arms. The user is the commander."; address rule (commander), seasoning note (military-light, optional)
- [ ] Hard rules 1–5: perimeter wording (read-only boundary), operator flow, recon worktree discard rule, XO communication rule, faithful reporting
- [ ] Sections 1–14 (verified count): vocab (unit, strike, recon, XO, FOB, sentry, stand-to queue, the perimeter), env (`SQUAD_HOME`, `SQUAD_*`), script refs (`bin/sq-*`), layout block, private-material list (`commander.md`, `commander-shared.md`, `XOs.md`), `AGENTS.md` self-reference kept; `/updatefirstmate`→`/updatesquad` (section 12)
- [ ] **Verificar:** head matches Squad identity; `grep -n 'fm-\|FM_\|firstmate\|captain\|crewmate\|fleet\|treehouse' AGENTS.md` → 0 hits; every `bin/sq-*.sh` referenced exists (reference checker)

### T-M1-03 — bin/ script renames (REQ-M1-03 AC1/AC2)
- [ ] Rename all 128 `bin/fm-*.sh` → `sq-*.sh` (mechanical + vocab rule, design.md §2) + 2 `bin/fm-*.mjs` → `sq-*.mjs` (`fm-arm-command-policy.mjs`, `fm-cd-command-policy.mjs`): e.g., `fm-watch.sh`→`sq-sentry.sh`, `fm-wake-drain.sh`→`sq-stand-to-drain.sh`, `fm-fleet-snapshot.sh`→`sq-unit-snapshot.sh`, `fm-bearings-snapshot.sh`→`sq-sitrep-snapshot.sh`, `fm-secondmate-*`→`sq-xo-*`, `fm-install-treehouse.sh`→`sq-install-fob.sh`
- [ ] `bin/backends/` filenames UNCHANGED (tool names); content refs deferred to T-M1-04
- [ ] **Verificar:** `ls bin/ | grep -c '^fm-'` → 0; count of `sq-*.sh` == 128; count of `sq-*.mjs` == 2; `bin/backends/` intact (7 files)

### T-M1-04 — Script internals sweep (REQ-M1-03 AC3, REQ-M1-02)
- [ ] Per script: sibling calls, state-file paths (`.stand-to-queue`, `.watch.lock`→`.sentry.lock`, `.watch-triage.log`→`.sentry-triage.log`), env reads (`SQUAD_*` incl. `SQUAD_PI_HARNESS` marker, `FM_WATCHER_*`→`SQUAD_SENTRY_*`), meta fields (`kind=recon`, `mode=strike`), output prose (commander/operator/unit/strike/recon/XO/FOB/sentry/stand-to/perimeter/sergeant at arms), home markers (`.fm-secondmate-home`→`.sq-xo-home`, `.fm-secondmate-parent`→`.sq-xo-parent`)
- [ ] `.gitignore` entries: `.fm-secondmate-home`→`.sq-xo-home`, `.fm-secondmate-parent`→`.sq-xo-parent` (design.md §2 row 27)
- [ ] `bash -n` clean on every script; `bin/sq-lint.sh` (ex-`fm-lint.sh`) passes
- [ ] **Verificar:** `grep -r 'fm-\|FM_' bin/` → 0 hits; `grep -rl 'firstmate\|captain\|crewmate\|treehouse\|secondmate' bin/` → 0 hits; `grep -r '\.fm-secondmate' bin/ .gitignore` → 0 hits; `bash -n bin/*.sh bin/backends/*.sh` exit 0; `bin/sq-lint.sh` exit 0

### T-M1-05 — Skills sweep (REQ-M1-04)
- [ ] All 19 `.agents/skills/*` directory renames per design.md §2 rows 21–26 (`updatefirstmate`→`updatesquad`, `fmx-respond`→`relay-respond`, `firstmate-codexapp`→`squad-codexapp`, `firstmate-coding-guidelines`→`squad-coding-guidelines`, `firstmate-orca`→`squad-orca`, `stuck-crewmate-recovery`→`stuck-operator-recovery`, `secondmate-provisioning`→`xo-provisioning`, `ahoy`→`reporting`, `bearings`→`sitrep`, `stow`→`debrief`); content rebranded (vocab/env/script refs); command names `/reporting`, `/sitrep`, `/debrief`, `/updatesquad`; `metadata.internal=true` preserved
- [ ] `harness-adapters/SKILL.md` facts updated (`sq-*`, `SQUAD_*`, Pi/pi-signed co-primary with claude/grok); `bin/sq-harness.sh` detection markers
- [ ] Public `skills/stow` → `skills/debrief` (name + installer-facing metadata)
- [ ] **Verificar:** `grep -rl 'fm-\|FM_\|firstmate\|captain\|crewmate' .agents/skills/ skills/` → 0 hits; `metadata.internal=true` count == 19; dir names match rows 21–26; `skills/debrief` exists, `skills/stow` gone

### T-M1-06 — docs sweep (REQ-M1-09 AC1)
- [ ] Rebrand `docs/` (architecture.md, configuration.md, backend docs, supervision-protocols/, turnend-guard.md, arm-pretool-check.md, subagent-guard.md, verification/, examples/, scripts.md, watcher-continuity.md→sentry-continuity.md, fm-test-portable-shards.md→sq-test-portable-shards.md, **fm-test-isolation-proof.{json,md}→sq-test-isolation-proof.{json,md}**, gitlab-merge-watch.md, remote-secondmates.md→remote-XOs.md, wedge-alarm.md, calm.md, trace-context.md, sessionstart-nudge.md, decision-hold-lifecycle.md, documentation-audiences.{md,json})
- [ ] Mechanism prose preserved verbatim except identity tokens
- [ ] **Verificar:** `grep -rl 'fm-\|FM_\|firstmate\|captain\|crewmate\|treehouse' docs/` → 0 hits; `docs/documentation-audiences.json` valid JSON

### T-M1-07 — README/CONTRIBUTING/assets (REQ-M1-09 AC2/AC3)
- [ ] README: tagline "Talk to one agent. Deploy with a squad."; remove upstream badge/links (X @kunchenguid, upstream Discord); quick-start uses Squad clone URL (OQ-03 placeholder); feature list vocab; no author mentions
- [ ] CONTRIBUTING.md rebrand; assets/banner text/alt updated (no upstream branding)
- [ ] **Verificar:** `grep -ri 'kunchenguid\|@kunchenguid\|discord.gg/Wsy2NpnZDu' README.md CONTRIBUTING.md assets/` → 0 hits; tagline matches; `grep -c 'firstmate\|first mate' README.md` → 0

### T-M1-08 — Non-Pi adapter dirs (REQ-M1-07)
- [ ] `.claude/settings.json`, `.claude/skills` symlink (kept); `.codex/hooks.json`; `.grok/hooks/*.json` (4 hooks: cd-check, pretool-check, sessionstart-nudge, turnend-guard); `.opencode/plugins/*.js` + `lib/` + `package.json` — mechanism unchanged, refs rebranded (`bin/sq-*`, `SQUAD_*`, `sq-primary-*` plugin naming where fm-prefixed)
- [ ] **Verificar:** `grep -rl 'fm-\|FM_' .claude/ .codex/ .grok/ .opencode/` → 0 hits; hook JSON parses; `.claude/skills` still symlink

### T-M1-09 — .pi extensions (REQ-M1-08)
- [ ] Rename `.pi/extensions/fm-primary-turnend-guard.ts`→`sq-primary-turnend-guard.ts`, `fm-primary-pi-watch.ts`→`sq-primary-pi-watch.ts`, `fm-calm.ts`→`sq-calm.ts`, `lib/fm-*.ts`→`lib/sq-*.ts`
- [ ] Content sweep: env markers (`SQUAD_PI_HARNESS`), script paths, prose; Pi engine auto-discovery contract preserved
- [ ] **Verificar:** `grep -rl 'fm-\|FM_\|firstmate' .pi/` → 0 hits; extension files list matches pre-rename count (8 files); headless Pi load smoke (T-M3-01 for full verification)

### T-M1-10 — Tests rebrand (REQ-M1-06)
- [ ] Rename 132 `fm-*.test.sh` → `sq-*.test.sh` + `fm-backend-herdr-eventwait.test.py` → `sq-backend-herdr-eventwait.test.py` (vocab rule applied: watch/wake/fleet/bearings/secondmate names); test helpers `secondmate-helpers.sh`→`xo-helpers.sh`, `wake-helpers.sh`→`stand-to-helpers.sh` (design.md §2 row 28)
- [ ] Rebrand identity-bearing assertions only (script paths `bin/sq-*`, env `SQUAD_*`, vocab in expected output, `SQUAD_PI_HARNESS=pi-signed` marker, `data/commander.md` paths); non-identity assertions untouched
- [ ] Runner rename `bin/fm-test-run.sh`→`bin/sq-test-run.sh` + its shard definitions; isolation-proof docs/tests renamed
- [ ] **Verificar:** `grep -rl 'fm-\|FM_' tests/` → 0 hits; `ls tests/ | grep -c '^fm-'` → 0; test count == 133 (132 sh + 1 py)

### T-M1-11 — CI workflows (REQ-M1-10)
- [ ] `.github/workflows/ci.yml`: `sq-install-shellcheck.sh`, `sq-lint.sh`, `sq-test-run.sh --check-coverage`, portable shards, serial + herdr lanes; forked tasks-axi install
- [ ] `.github/workflows/no-mistakes-required.yml`: forked binary path
- [ ] **Verificar:** `grep -rl 'fm-\|FM_\|firstmate' .github/` → 0 hits; YAML valid (`actionlint` or ruby yaml parse); jobs == upstream set (rebranded)

### T-M1-12 — Private-material seeds + full gate (REQ-M1-11, REQ-M1-06 AC3/AC4)
- [ ] `sq-home-seed.sh`-created names: `data/commander.md`, `commander-shared.md`, `XOs.md`, `learnings.md`, `projects.md`, `backlog.md`; `.tasks.toml` content refs; `config/` seed names per design.md §3
- [ ] Run full suite via `sq-test-run.sh` in a throwaway `SQUAD_HOME`; fix only identity-related failures (re-run sweep tools); then run `tests/sq-rebrand-guard.test.sh` (grep guards §8)
- [ ] **Verificar:** full suite green (same pass-set as M0 baseline); `sq-test-run.sh --check-coverage` exit 0; all §8 guards pass; seed run in throwaway home produces the renamed private files

---

## M2 — Deps as Workspace Packages (REQ-M2-01..04)

### T-M2-01 — Go workspace scaffold (REQ-M2-01 AC1/AC2)
- [ ] Create `packages/fob/` and `packages/no-mistakes/` from the reference clones (tracked files only)
- [ ] Private stub `package.json` per package: `{ "name": "fob"/"no-mistakes", "private": true, "scripts": { "build": "go build -o dist/... ./...", "test": "go test ./...", "lint": "go vet ./..." } }`
- [ ] Root `package.json` workspaces `["packages/*"]`; `turbo.json` build/lint/test graph covers the Go stubs (design.md §7)
- [ ] Module path rename (AD-005, OQ-01): default `github.com/<squad-org>/squad/packages/fob` / `.../no-mistakes`; sweep all internal imports; record chosen path in context.md
- [ ] **Verificar:** `turbo build --filter=fob --filter=no-mistakes` exit 0; `go test ./...` green per package; `grep -r kunchenguid packages/fob packages/no-mistakes` → 0 hits; `go.mod` module line matches chosen path

### T-M2-02 — fob fork identity sweep (REQ-M2-01 AC3)
- [ ] README/CHANGELOG/docs/VISION/AGENTS.md/CLAUDE.md inside `packages/fob/` rebranded (no author mentions — AD-002); treehouse.toml.example content refs
- [ ] **Verificar:** `grep -ri 'kunchenguid\|firstmate' packages/fob/` → 0 hits (except none); `go test ./...` still green

### T-M2-03 — no-mistakes fork identity sweep (REQ-M2-02 AC3)
- [ ] README/README.zh-CN (drop or rebrand), docs/, scripts/, skills/, VISION, workflow_*.go tests content refs; `.no-mistakes/` local dir remains gitignored
- [ ] **Verificar:** `grep -ri 'kunchenguid\|firstmate' packages/no-mistakes/` → 0 hits; full `go test ./...` green (incl. workflow_*.go tests)

### T-M2-04 — tasks-axi fork (REQ-M2-03)
- [ ] Copy tracked source into `packages/tasks-axi/`; keep pnpm workspace (`packageManager: pnpm@11.1.1`) inside the package for fidelity (RISK-10); root bun workspace entry `packages/*` must tolerate the nested pnpm lockfile (verify hoisting; exclude `pnpm-lock.yaml` from root bun resolution if needed)
- [ ] Rename npm `name` → `sq-tasks-axi` (AD-006, OQ-02 default) and `bin` → `sq-tasks-axi`; sweep src refs, README, CHANGELOG, skills/tasks-axi, scripts
- [ ] `build` (tsc) + `test` (vitest) green
- [ ] **Verificar:** `bun/pnpm run build` + `test` exit 0; `npm pack --dry-run` lists renamed bin/artifacts; `grep -ri 'kunchenguid' packages/tasks-axi/` → 0 hits; `grep -rn 'tasks-axi'` inside package only refers to the forked name where identity-bearing

### T-M2-05 — Distro↔dep wiring (REQ-M2-01 AC3, REQ-M2-02 AC3, REQ-M2-03 AC3)
- [ ] `bin/sq-install-fob.sh` fetches Squad Release asset (URL placeholder OQ-03); no-mistakes bootstrap points at Squad release; `sq-tasks-axi-lib.sh` invokes forked CLI; `.no-mistakes.yaml` gate path
- [ ] **Verificar:** in a throwaway `SQUAD_HOME`, `sq-install-fob.sh` succeeds against a scratch release (or documented local build fallback); backlog command via fork works; `grep -rn 'kunchenguid\|treehouse.*install' bin/` → 0 hits

---

## M3 — Pi Adapters + pr-review (REQ-M3-01..02)

### T-M3-01 — Pi primary verification (REQ-M1-08 full)
- [ ] Headless Pi session loads the repo; adapted `.pi/extensions/` auto-discover; turn-end guard + primary watcher protocols exercise
- [ ] **Verificar:** session loads without extension errors; watcher arm reports honest started/FAILED; `SQUAD_PI_HARNESS=pi-signed` detection path verified by `bin/sq-harness.sh`

### T-M3-02 — Vendor @runecraft/pr-review (REQ-M3-01)
- [ ] Pin source tarball from runecraft-ai/harness (version from `/home/rehem/Projects/harness/packages/pr-review/package.json`); extract to `packages/pr-review/`; write provenance record (sha256, version, URL, date) into `packages/pr-review/vendor.json`
- [ ] Workspace registration + peer deps resolution via bun hoisting; `bun test` green
- [ ] **Verificar:** `bun test` exit 0; headless Pi load registers extension; provenance file exists; package `name` == `@runecraft/pr-review` (unchanged — it is Runecraft's, not upstream-author's)

### T-M3-03 — pr-review integration layer (REQ-M3-02)
- [ ] `.pi/extensions/sq-pr-review.ts`: registers the review action in the Pi session; invokes package lib; COMMENT-only publish; findings table to commander; never auto-merge/approve
- [ ] `bin/sq-pr-review.sh`: wrapper with guard paths (no repo / no PR / no `gh` auth → clear failure messages)
- [ ] Hook point documented in AGENTS.md section 7 (strike delivery area) + docs
- [ ] **Verificar:** unit checks of wrapper guards exit with clear messages (not crashes); extension loads; review invocation against a scratch PR (1× live, documented — A-08) produces COMMENT-only findings

---

## M4 — Publication & CI (REQ-M4-01..04)

### T-M4-01 — CI matrix consolidation (REQ-M4-01)
- [ ] Final `ci.yml` per design.md §7: lint, coverage guard, portable shards 1/2, serial, herdr, go-build-test (ubuntu+macos), tasks-axi; optional pi-smoke (env-gated)
- [ ] **Verificar:** CI green on a PR; every upstream job has a rebranded equivalent + new Go/npm jobs; no `fm-*`/`FM_*` refs

### T-M4-02 — Go release pipeline (REQ-M4-02)
- [ ] Carry release-please manifests from upstream forks (rebranded, no author); release workflow builds fob + no-mistakes binaries (linux/macos) and attaches to GitHub Release
- [ ] **Verificar:** scratch-repo release dry-run produces assets; `sq-install-fob.sh` fetches the asset from a scratch release

### T-M4-03 — tasks-axi npm publish (REQ-M4-03)
- [ ] Publish config (provenance, access) on the fork; name availability verified (AD-006); publish dry-run then real publish from CI on tag
- [ ] **Verificar:** `npm pack --dry-run` + registry install in throwaway env; `sq-tasks-axi-lib.sh` resolves forked package

### T-M4-04 — Distro E2E smoke + docs (REQ-M4-04)
- [ ] Fresh clone → bootstrap (shellcheck, FOB, tasks-axi, no-mistakes) → `sq-on.sh` → spawn operator → strike task lands a change in a scratch project (local-only mode) → recon task produces `data/<id>/report.md`
- [ ] README quick start + release docs updated; no upstream URLs
- [ ] **Verificar:** E2E smoke recorded (exit codes + artifacts); docs grep guards pass

---

## M5 — goal-loop-audit + Roadmap note (REQ-M3-03, REQ-M5-01)

### T-M5-01 — Vendor goal-loop-audit (REQ-M3-03 AC1)
- [ ] Pin + provenance (same pattern as T-M3-02); `packages/goal-loop-audit/`; workspace registration; `bun test` green
- [ ] **Verificar:** tests green; extension loads in Pi; provenance file exists

### T-M5-02 — Integration + coexistence (REQ-M3-03 AC2)
- [ ] Extension + bin wrapper wiring goal loops with isolated auditor (fresh session, read tools only) on completion
- [ ] Coexistence validated: goal-loop-audit + pr-review in ONE headless Pi session (two-driver rule, no conflicts)
- [ ] **Verificar:** headless session loads both extensions; a goal loop runs with auditor; pr-review still functional in same session

### T-M5-03 — Roadmap open-item note (REQ-M5-01 AC2)
- [ ] ROADMAP.md carries explicit open/optional entry: TS port of Go deps ("ou não") — NOT committed (AD-004)
- [ ] **Verificar:** ROADMAP grep for "ou não" / open-item marker; no design/tasks for the port exist

---

## Final Acceptance (project-level)

- [ ] All §8 grep guards pass; full suite green in CI; `turbo build && turbo test` green across Go + TS packages
- [ ] pr-review (v1) and goal-loop-audit (v1.1) load and run in Pi; one live pr-review demonstration documented
- [ ] Publication paths proven (Go Releases, npm fork, clone distro); ROADMAP open-item recorded
- [ ] context.md updated with OQ-01..03 resolutions and any new risks observed during execution
