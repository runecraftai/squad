# Squad Inception — Design

**Status:** Ready for Execute (all AD-* locked; open decisions OQ-01..03 flagged for executor confirmation)
**Sources (verified from local clones, read-only):** `/tmp/firstmate-ref` (distro), `/tmp/dep-treehouse`, `/tmp/dep-no-mistakes`, `/tmp/dep-tasks-axi` (deps), `/home/rehem/Projects/harness` (Runecraft conventions + packages)

---

## 1. Architecture Overview

Squad is a **clone-based agent distro** that happens to live in a monorepo. Two layers:

1. **The distro (repo root)** — the operating contract (`AGENTS.md`, kept filename), `bin/sq-*.sh` (130 files: 128 `.sh` + 2 `.mjs`, + `bin/backends/`), 19 internal skills (`.agents/skills/`, `metadata.internal=true`), tracked harness adapters (`.claude/ .codex/ .grok/ .opencode/ .pi/`), `docs/`, public `skills/debrief`, `tests/`, `.github/workflows/`. Mechanics are inherited **unchanged** from firstmate: liaison spawns visible operators in tmux/herdr/zellij/orca/cmux endpoints, each in a clean FOB worktree; two task shapes (strike → PR/local merge by project mode `no-mistakes`/`direct-PR`/`local-only` `+yolo`; recon → `data/<id>/report.md`, never pushes); zero-token bash sentry (`bin/sq-sentry.sh`) with durable `state/.stand-to-queue`; turn-end guard; restart-proof disk state under `SQUAD_HOME`; the perimeter (read-only project boundary); optional XOs; dispatch profiles; unit sync/self-update.
2. **The workspace packages (`packages/`)** — runtime deps built from source in-repo: `fob` (Go worktree pool), `no-mistakes` (Go CI gate), `tasks-axi` (TS backlog CLI), plus Runecraft `@runecraft/pr-review` (v1) and `@runecraft/goal-loop-audit` (v1.1). Turbo orchestrates builds; the distro's install scripts fetch release artifacts from Squad-owned sources.

```
┌──────────────────────────────  squad/ (git clone = the distro)  ──────────────────────────────┐
│  AGENTS.md ◄─ CLAUDE.md (symlink)         .tasks.toml / .no-mistakes.yaml (filenames KEPT)     │
│  bin/sq-*.sh (+ backends/)   .agents/skills/ (19)   skills/debrief   docs/   tests/sq-*.test.sh │
│  .claude/ .codex/ .grok/ .opencode/  (kept working, rebranded refs)   .pi/extensions/sq-*.ts    │
│  .github/workflows/ (ci.yml, no-mistakes-required.yml)   .specs/ (planning corpus)             │
│  data/ state/ config/ projects/ .env  → gitignored (commander-private, the perimeter)          │
├──────────────────────────────  packages/ (turbo workspace)  ───────────────────────────────────┤
│  fob/ (Go, private stub pkg.json)   no-mistakes/ (Go, private stub pkg.json)                   │
│  tasks-axi/ (TS, npm-publishable)   pr-review/ (@runecraft/pr-review)   goal-loop-audit/ (v1.1)│
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Command flow (Pi primary, v1):** commander → sergeant at arms (Pi session, repo loaded) → intake → `bin/sq-spawn.sh` launches operator in endpoint (tmux default) with clean FOB worktree → operator executes strike/recon → sentry watches, wakes sergeant on actionable events via stand-to queue → strike PR lands → `sq-pr-review` (`.pi/extensions/sq-pr-review.ts` + `bin/sq-pr-review.sh`, backed by `@runecraft/pr-review`) runs parallel tiered review (COMMENT-only) → findings surfaced to commander → merge only on commander word (or standing `+yolo` green posture) via `bin/sq-pr-merge.sh`.

---

## 2. Rebrand Sweep — Vocabulary Mapping Table (single source of truth)

Rule: **apply vocabulary first, then mechanical prefix swaps.** A script name containing a mapped word takes the mapped word (`fm-watch.sh` → `sq-sentry.sh`); otherwise `fm-` → `sq-` mechanically. Ambiguous English words (`ship`, `watch`, `fleet`, `scout`) are replaced **context-sensitively** — only when they denote the mapped concept (task shape, supervision mechanism, operator group, task shape), never inside unrelated prose (e.g., "ship the change" → "deploy the change"; "watch for errors" stays natural English). The 65KB AGENTS.md is the reference for every mapping; verify each replacement against its section.

| # | Old (firstmate) | New (Squad) | Scope |
| --- | --- | --- | --- |
| 1 | firstmate (product) | **Squad** | everything |
| 2 | "Talk to one agent. Ship with a crew." | **"Talk to one agent. Deploy with a squad."** | README, AGENTS.md identity |
| 3 | captain | **commander** | roles, `data/captain.md`→`commander.md`, `captain-shared.md`→`commander-shared.md`, prose |
| 4 | first mate / firstmate (role) | **sergeant at arms** | AGENTS.md identity, prose ("the sergeant at arms", "sergeant") |
| 5 | crewmate | **operator** | roles, prose, state refs |
| 6 | fleet | **unit** | "the unit", `fm-fleet-snapshot.sh`→`sq-unit-snapshot.sh`, `fm-fleet-view.sh`→`sq-unit-view.sh` |
| 7 | ship (task shape) | **strike** | task shapes, "ship task"→"strike task" |
| 8 | scout (task shape) | **recon** | task shapes, `fm-promote.sh` recon-promotion paths, "scout worktree"→"recon worktree" |
| 9 | secondmate | **XO** | `data/secondmates.md`→`data/XOs.md`, `fm-secondmate-*`→`sq-xo-*`, `config/secondmate-harness`→`config/xo-harness` |
| 10 | treehouse | **FOB** | `fm-install-treehouse.sh`→`sq-install-fob.sh`, package `fob`, prose "FOB worktree pool" |
| 11 | watch (supervision mechanism) | **sentry** | `fm-watch.sh`→`sq-sentry.sh`, `fm-watch-arm.sh`→`sq-sentry-arm.sh`, "the sentry", `fm-watch-checkpoint.sh`→`sq-sentry-checkpoint.sh` |
| 12 | wake-queue | **stand-to queue** | `state/.wake-queue`→`state/.stand-to-queue`, `fm-wake-drain.sh`→`sq-stand-to-drain.sh`, `fm-wake-lib.sh`→`sq-stand-to-lib.sh` |
| 13 | /ahoy | **/reporting** | skills, docs, command names |
| 14 | /bearings | **/sitrep** | skills, docs (`fm-bearings-snapshot.sh`→`sq-sitrep-snapshot.sh`) |
| 15 | /stow | **/debrief** | skills, docs, public `skills/stow`→`skills/debrief` |
| 16 | `fm-` | **`sq-`** | all script/test/workflow filenames + references |
| 17 | `FM_*` | **`SQUAD_*`** | all env vars (§3) |
| 18 | read-only boundary | **the perimeter** | AGENTS.md hard-rule prose, docs |
| 19 | `AGENTS.md` | **KEPT** (filename) | tooling convention (AD-012) |
| 20 | `CLAUDE.md` symlink, `.tasks.toml`, `.no-mistakes.yaml`, `.claude/skills` symlink | **KEPT** (filenames) | tooling conventions (AD-012) |
| 21 | skill dir `updatefirstmate` (invoked `/updatefirstmate`) | **`updatesquad`** (`/updatesquad`) | `.agents/skills/`, AGENTS.md section 12 |
| 22 | skill dir `fmx-respond` | **`relay-respond`** | `.agents/skills/` (Relay mention playbook). NOTE: `fmx-` escapes `\bfm-` — the §8.3 guard greps `\bfmx-` too |
| 23 | skill dirs `firstmate-codexapp`, `firstmate-coding-guidelines`, `firstmate-orca` | **`squad-codexapp`, `squad-coding-guidelines`, `squad-orca`** | `.agents/skills/` |
| 24 | skill dir `stuck-crewmate-recovery` | **`stuck-operator-recovery`** | `.agents/skills/` |
| 25 | skill dir `secondmate-provisioning` | **`xo-provisioning`** | `.agents/skills/` |
| 26 | skill dirs `ahoy`, `bearings`, `stow` | **`reporting`, `sitrep`, `debrief`** | `.agents/skills/` (internal) + public `skills/stow`→`skills/debrief` |
| 27 | home markers `.fm-secondmate-home` / `.fm-secondmate-parent` | **`.sq-xo-home` / `.sq-xo-parent`** | `.gitignore` + the ~10 scripts referencing them (`fm-teardown.sh`, `fm-spawn.sh`, `fm-stow-cascade.sh`, `fm-startup-memory-budget.sh`, `fm-secondmate-parent-lib.sh`, `fm-remote-secondmate-control.sh`, `fm-remote-home-provision.sh`, …) |
| 28 | test helpers `secondmate-helpers.sh`, `wake-helpers.sh` | **`xo-helpers.sh`, `stand-to-helpers.sh`** | `tests/` (non-test helper files carry mapped words) |

**Keep-list (deliberately NOT renamed):** `bin/backends/{tmux,herdr,zellij,orca,cmux}.sh` (tool names), `AGENTS.md`, `CLAUDE.md`, `.tasks.toml`, `.no-mistakes.yaml`, `.no-mistakes/`, `config/crew-harness` (generic knob name; content values rebranded), `docs/` filename stems except where they encode mapped words (e.g., `tmux-backend.md` stays; `watcher-continuity.md`→`sentry-continuity.md`). `README.md`, `CONTRIBUTING.md`, `LICENSE` stay as filenames.

## 3. Environment Variable Migration (`FM_*` → `SQUAD_*`)

Mechanical: every `FM_*` token becomes `SQUAD_*`. Representative table (non-exhaustive — the sweep greps `FM_` repo-wide):

| Old | New |
| --- | --- |
| `FM_HOME` | `SQUAD_HOME` |
| `FM_PI_HARNESS` (marker `FM_PI_HARNESS=pi-signed`) | `SQUAD_PI_HARNESS` |
| `FM_STALE_ESCALATE_SECS` | `SQUAD_STALE_ESCALATE_SECS` |
| `FM_PAUSE_RESURFACE_SECS` | `SQUAD_PAUSE_RESURFACE_SECS` |
| `FM_BUSY_TURN_MAX_SECS` | `SQUAD_BUSY_TURN_MAX_SECS` |
| `FM_WEDGE_DEMAND_INSPECT_COUNT` | `SQUAD_WEDGE_DEMAND_INSPECT_COUNT` |
| `FM_ALLOW_SUBAGENT` | `SQUAD_ALLOW_SUBAGENT` |
| `FM_COMPOSER_IDLE_RE` | `SQUAD_COMPOSER_IDLE_RE` |
| `FM_WATCH_*` / `FM_WATCHER_*` (any) | `SQUAD_SENTRY_*` (vocab applies). Verified real vars: `FM_WATCHER_HEALTHY_IDENTITY`, `FM_WATCHER_HEALTHY_PID`, `FM_WATCHER_MATCHED_IDENTITY`, `FM_WATCHER_STALE_GRACE`, `FM_WATCHER_VERDICT_OK`, `FM_WATCHER_VERDICT_REASON` |
| `FM_*` (all others) | `SQUAD_*` |

Config-file names under `config/` follow the vocab table when they encode mapped words (`config/secondmate-harness`→`config/xo-harness`); generic knobs (`crew-harness`, `crew-dispatch.json`, `backlog-backend`, `backend`, `calm`, `trace-context`, `wedge-alarm`, `x-mode.env`) keep names, content rebranded.

## 4. Rebrand Sweep Order (M1) — dependency-aware

Executed in this order; each step ends with its local grep guard so the next step starts from a consistent tree. **Only after the last step does the full suite run.**

1. **Freeze the mapping table** (this file, §2) — the single source of truth.
2. **`AGENTS.md`** — identity block ("You are the sergeant at arms. The user is the commander."), hard rules (perimeter), sections 1–14 (verified: AGENTS.md has 14 numbered sections) vocab/env/script refs. This is the reference every other file mirrors.
3. **`bin/` scripts** — rename files first (mechanical + vocab), then sweep internal references: sibling calls, state-file paths (`.stand-to-queue`, `<id>.meta` unchanged fields, `kind=recon`), env reads (`SQUAD_*`), output prose ("commander", "operator", "strike", "recon", "unit", "FOB", "sentry", "stand-to", "XO", "perimeter", "sergeant at arms"). `bin/backends/` content refs only.
4. **`tests/`** — rename `fm-*.test.sh`→`sq-*.test.sh` (+ `fm-backend-herdr-eventwait.test.py`→`sq-backend-herdr-eventwait.test.py`), rebrand assertions that encode identity (script paths, env, vocab in expected output, harness-detection markers). **Semantics stay byte-equivalent except identity tokens.**
5. **`.agents/skills/` (19)** — directory renames per §2 rows 21–26 (`updatesquad`, `relay-respond`, `squad-codexapp`, `squad-coding-guidelines`, `squad-orca`, `stuck-operator-recovery`, `xo-provisioning`, `reporting`, `sitrep`, `debrief`); content sweep; command renames (`/reporting`, `/sitrep`, `/debrief`, `/updatesquad`); harness-adapters facts (`sq-*` scripts, `SQUAD_*` env, Pi/pi-signed co-primary); `metadata.internal=true` preserved.
6. **`docs/`** — architecture.md, configuration.md, backend docs, supervision-protocols, turnend-guard.md, verification evidence, examples; file renames where stems encode mapped words.
7. **README.md, CONTRIBUTING.md, assets** — tagline, badges/links (no upstream handles/servers — AD-002), quick-start clone URL, feature list vocab.
8. **Adapter dirs** — `.claude/` (settings.json, skills symlink kept), `.codex/hooks.json`, `.grok/hooks/*.json`, `.opencode/plugins/*.js` + `lib/` + `package.json`: mechanism unchanged, every `fm-*`/`FM_*`/firstmate ref rebranded.
9. **`.pi/extensions/`** — rename `fm-primary-*`→`sq-primary-*`, `lib/fm-*.ts`→`lib/sq-*.ts`, identity sweep (env markers, script paths, prose).
10. **`.github/workflows/`** — ci.yml + no-mistakes-required.yml: `sq-*` script refs, `SQUAD_*`, forked no-mistakes binary.
11. **Private-material seeds** — `sq-home-seed.sh`-created files (`commander.md`, `commander-shared.md`, `XOs.md`, `learnings.md`, `projects.md`, `backlog.md`), `.tasks.toml` content, `config/` seeds.
12. **Full-suite gate** — `sq-test-run.sh --check-coverage` + full suite green; repo-wide grep guards (§8) pass.

## 5. Test Rename Strategy

- **Inventory:** 132 `*.test.sh` + 1 `*.test.py` (upstream `tests/`). All kept (AD-009).
- **Rename rule:** `fm-`→`sq-` (+ vocab words in names: `fm-watch*`→`sq-sentry*`, `fm-wake*`→`sq-stand-to*`, `fm-fleet*`→`sq-unit*`, `fm-bearings*`→`sq-sitrep*`, `fm-secondmate*`→`sq-xo*`).
- **Assertion rebrand:** only identity-bearing tokens (paths `bin/sq-*`, env `SQUAD_*`, vocab in expected strings, harness marker `SQUAD_PI_HARNESS=pi-signed`). Non-identity assertions untouched.
- **Runner:** `bin/fm-test-run.sh`→`bin/sq-test-run.sh` owns the complete partition proof (`--check-coverage`: portable parallel shards + portable serial + Herdr lane == complete inventory, no missing/duplicates) and the per-shard execution. CI calls only `sq-test-run.sh` (single owner, same as upstream).
- **Isolation:** upstream's portable-shard isolation proof is kept and rebranded in BOTH locations: evidence `docs/fm-test-isolation-proof.{json,md}`→`sq-*` AND the test `tests/fm-test-isolation-proof.test.sh`→`sq-*`; it documents which tests are proven-isolated for parallel shards.
- **Gate:** M1 is not green until the full suite passes with the same pass-set as the M0 baseline (modulo identity assertions). Any test that encodes upstream URLs/author handles is rebranded per AD-002.

## 6. Runecraft Integration (Pi Primary Flow)

**Vendoring (mirrors harness F1/F5 practice):** source tarball pins from runecraft-ai/harness into `packages/pr-review/` and `packages/goal-loop-audit/`, with `vendor.json`-style provenance records (sha256 pin, version, source URL, extraction date). Workspaces registered in root `package.json` (`"workspaces": ["packages/*"]`); peer deps (`@earendil-works/pi-*`, `typebox`) resolved via bun hoisting — same strategy the harness uses. Both packages keep their `pi` manifest (`extensions/`, `prompts/`) so `pi install`/auto-discovery works.

**v1 — pr-review in the strike flow (REQ-M3-02):**
- Hook point: after a strike (ship task) produces a PR and before the commander's merge decision (AGENTS.md section 7 delivery/merge area) — the sergeant at arms runs the review.
- Surfaces: (a) `.pi/extensions/sq-pr-review.ts` — a Pi extension that registers the review action in-session (invokes the package's lib, COMMENT-only publishing, findings table to the commander); (b) `bin/sq-pr-review.sh` — thin wrapper for manual/CI invocation (validates repo+PR context and `gh` auth; fails with clear messages per REQ-M3-02 AC3).
- Guards: never auto-merge/auto-approve; publish mode COMMENT-only (package default); findings feed the commander decision; `+yolo` posture does not let the review self-approve.
- Validation: unit checks of the wrapper's guard paths (no repo / no PR / no `gh` auth) + one documented live run against a test repo (REQ-M3-02; not a CI gate — A-08).

**v1.1 — goal-loop-audit (M5, REQ-M3-03):** same vendoring pattern; extension + bin wrapper wire goal loops with the isolated auditor (fresh session, no extensions/skills/editor — only read tools) on completion; coexistence with pr-review validated in one headless Pi session (two-driver rule) before shipping.

## 7. CI Matrix (M4, REQ-M4-01)

One `.github/workflows/ci.yml`, mirroring upstream jobs rebranded + new jobs:

| Job | Runner | Command | Notes |
| --- | --- | --- | --- |
| lint | ubuntu-latest | `bin/sq-install-shellcheck.sh` (pinned) + `bin/sq-lint.sh` | single owner of lint definition (parity asserted by `tests/sq-lint.test.sh`) |
| test-coverage | ubuntu-latest | `bin/sq-test-run.sh --check-coverage` | complete partition proof |
| tests-portable-parallel-1 / -2 | ubuntu-latest | `sq-test-run.sh` shards | duration-balanced; `fetch-depth: 0`; shellcheck + forked tasks-axi installed |
| tests-portable-serial | ubuntu-latest | `sq-test-run.sh` serial lane | |
| herdr | ubuntu-latest | herdr lane (upstream-equivalent) | |
| go-build-test | ubuntu + macos | `turbo build --filter=fob --filter=no-mistakes` + `go test ./...` per package | toolchain per go.mod (1.25.x) |
| tasks-axi | ubuntu-latest | `bun/pnpm install` + build + test (fork) | |
| pi-smoke (optional) | ubuntu-latest | headless Pi session loads `.pi/extensions/` + Runecraft packages | env-gated; not a hard gate if Pi unavailable in CI |
| no-mistakes-required | ubuntu-latest | `.github/workflows/no-mistakes-required.yml` | PR-body compliance via forked binary |

**Go coexistence via turbo (AD-004):** each Go package carries a minimal **private** stub `package.json` (`"private": true`) exposing turbo tasks: `"build": "go build ./..."` (outputs `dist/` binaries), `"test": "go test ./..."`, `"lint": "go vet ./..."`. Root `turbo.json` gains the standard `build`/`lint`/`test` task graph (`test` dependsOn `build`), so `turbo build`/`turbo test` drive Go and TS uniformly. Go packages are private (never npm-published); their artifacts ship via GitHub Releases.

## 8. Repo-Wide Grep Guards (verification chain)

Executed at end of M1 and enforced in CI (a `tests/sq-rebrand-guard.test.sh`):

1. `grep -r "firstmate\|first mate\|Firstmate"` → 0 hits (tracked, **excluding `.specs/`** — the planning corpus may name the fork origin per item 7)
2. `grep -r "kunchenguid\|Kun Chen\|@kunchenguid"` → 0 hits (tracked, **excluding `.specs/`** — legal caveat and module-path decisions legitimately name the upstream there)
3. `grep -rE "\bfm-|\bfmx-"` → 0 hits (tracked, **excluding `.specs/`**; `fmx-` is grepped explicitly because it escapes `\bfm-`)
4. `grep -rE "\bFM_"` → 0 hits (tracked, **excluding `.specs/`**)
5. Mapped-sense vocabulary patterns → 0 hits (tracked, **excluding `.specs/`**). Concrete pattern list (not bare words): `\bcaptain\b`, `\bcrewmate\b`, `\bfleet\b`, `\bsecondmate\b`, `\btreehouse\b`, `\bahoy\b`, `\bbearings\b`, `\bstow\b`, `\bwake-queue\b`, `\bship task\b`, `\bscout task\b`, `\bscout worktree\b`, `\bthe watch\b`, `watch\.sh`, `watcher-continuity`. Natural-English `watch`/`ship`/`scout` outside these patterns are **allowed** (e.g., "watch for errors", "ship the change"); the allowlist is enforced by this pattern list, never by bare-word greps.
6. Keep-list asserts: `AGENTS.md` exists, `CLAUDE.md` is a symlink, `.tasks.toml`/`.no-mistakes.yaml` exist, `.claude/skills` symlink intact
7. `.specs/` is the only location allowed to mention the legal caveat (RISK-01) and fork origin

## 9. Publication Flow (M4, AD-007)

| Artifact | Source | Target | Mechanism |
| --- | --- | --- | --- |
| Distro | repo root | `git clone` | README quick start; no npm tarball |
| `fob` binary | `packages/fob` (Go) | GitHub Releases | release-please (manifests carried from upstream, rebranded) + CI build → release assets (linux/macos) |
| `no-mistakes` binary | `packages/no-mistakes` (Go) | GitHub Releases | same pipeline |
| tasks-axi fork | `packages/tasks-axi` (TS) | npm | `publishConfig` + provenance; name verified available (AD-006) |
| pr-review / goal-loop-audit | `packages/` (TS) | in-repo only | workspace packages; not re-published (Runecraft upstream publishes `@runecraft/*`) |

Install-time resolution: `sq-install-fob.sh` (ex-`fm-install-treehouse.sh`) fetches the Squad release asset; the no-mistakes bootstrap points at the Squad release; `sq-tasks-axi-lib.sh` prefers the forked npm package. No upstream URLs anywhere (AD-002).

## 10. Risks (design-level)

- **RISK-01 Legal (flagged once):** MIT requires retaining the copyright notice; AD-002 removes all attribution ("o produto será nosso"). Documented, accepted, owned. No `NOTICE.md`. Full caveat in context.md.
- **RISK-02/04/05/06/07/08:** see context.md — module-path rename gates (M2), npm name collision (M4), deep cross-reference sweep (mitigated by sweep order + guards), identity-encoding test assertions (M1-10), Runecraft peer deps (M3), pi-signed marker rename (M1).
- **New (design):** RISK-09 — turbo running Go requires the pinned Go toolchain on every runner; upstream uses `go 1.25.x` → pin via `go.mod` + CI setup-go. RISK-10 — `bun` vs `pnpm` for tasks-axi fork: upstream uses pnpm (`packageManager: pnpm@11.1.1`); keep pnpm inside `packages/tasks-axi/` for fidelity, root stays bun (harness convention) — validated in M2.
