# Squad

**Tagline:** *Talk to one agent. Deploy with a squad.*

**Status:** Inception (M0) — planning artifacts committed, import pending.

## Vision

Squad is an **agent distro**: a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose terminal coding agent into a specialized one — the **sergeant at arms**. The human is the **commander**. The sergeant at arms is the single point of contact; it spawns, supervises, and reports on a visible squad of **operators** that execute project work in clean, disposable git worktrees; **XOs** (persistent operators with isolated bases) extend the squad across machines. There is no app to install: the cloned repo *is* the distro.

Squad is a fork/rebrand of [firstmate](https://github.com/kunchenguid/firstmate) (MIT) under a military theme, plus its three runtime dependencies forked as first-class workspace packages, plus two Runecraft packages integrated into the Pi-primary flow. The mechanics, state model, and safety guards are inherited from firstmate and preserved faithfully; only the identity, vocabulary, packaging, and Runecraft integration are Squad's own.

## For

Developers who run a coding agent (Claude Code, Grok, Pi/pi-signed, Codex, or OpenCode) and want one point of contact that runs a parallel squad without tab-juggling: spawning visible operators in tmux/herdr/zellij/orca/cmux endpoints, each in a clean FOB-managed worktree, supervised to completion, handing the commander finished PRs, approved local merges, or standalone recon reports.

## Goals

- **G1 — Faithful rebranded fork:** Full functional fork of firstmate under the Squad identity — vocabulary, env (`SQUAD_*`), script prefix (`sq-`), skills, docs, adapters, and all ~133 tests rebranded and green in CI.
- **G2 — Runtime deps as workspace packages:** `fob` (worktree-pool CLI, Go), `no-mistakes` (CI gate, Go), and `tasks-axi` (backlog CLI, TS) forked into the monorepo, built via turbo tasks, tested in CI.
- **G3 — Runecraft integration:** v1 wires `@runecraft/pr-review` (parallel tiered PR review) into the Pi-primary strike flow; v1.1 adds `@runecraft/goal-loop-audit` (isolated-auditor goal loops).
- **G4 — Publication:** Go binaries via GitHub Releases; tasks-axi fork published to npm; distro consumed by `git clone` (no npm tarball for the distro).
- **G5 — Commander-private hygiene:** `data/ state/ config/ projects/ .env` gitignored captain-private material, same as upstream.

## Tech Stack

**Distro (the repo itself):** Bash + POSIX shell scripts (`bin/sq-*.sh`), a 65KB `AGENTS.md` operating contract (filename kept — tooling convention), 22 internal skills under `.agents/skills/` (`metadata.internal=true`), tracked harness adapters (`.claude/`, `.codex/`, `.grok/`, `.opencode/`, `.pi/`), docs, and a ~133-test shell suite.

**Monorepo orchestration (mirrors `/home/rehem/Projects/harness` conventions):**

- Package manager: `bun` (root `package.json`, `workspaces: ["packages/*"]`, `packageManager: bun@1.3.14`)
- Build orchestration: Turborepo (`turbo.json` — `build` dependsOn `^build`, outputs `dist/**`; `lint`; `test` dependsOn `build`)
- Lint/format: Biome 1.9 (`biome.json` — tab indent, lineWidth 100, double quotes, `vcs.useIgnoreFile`)
- TypeScript base: `tsconfig.base.json` (ESNext / NodeNext, `customConditions: ["development"]`, strict, `noUncheckedIndexedAccess`, declaration, sourceMap)

**Runtime dependencies (workspace packages):**

| Package | Upstream source | Language | Role |
| --- | --- | --- | --- |
| `fob` | kunchenguid/treehouse | Go | FOB worktree pool (clean worktrees per task) |
| `no-mistakes` | kunchenguid/no-mistakes | Go | CI gate / merge authority pipeline |
| `tasks-axi` | kunchenguid/tasks-axi | TS (npm) | AXI-compliant backlog CLI (markdown backend) |
| `@runecraft/pr-review` | runecraft-ai/harness (v1) | TS (Bun) | Parallel tiered PR review (COMMENT-only) |
| `@runecraft/goal-loop-audit` | runecraft-ai/harness (v1.1) | TS (Bun) | Goal loops with isolated auditor |

## Repo Layout (target)

```
squad/
├── AGENTS.md                 # operating contract (filename KEPT); CLAUDE.md symlinks here
├── .agents/skills/            # 22 internal skills (rebranded; /reporting /sitrep /debrief …)
├── bin/                       # 130 sq-* files (128 .sh + 2 .mjs) + bin/backends/ (tmux herdr zellij orca cmux)
├── docs/                      # architecture, configuration, backend docs, supervision protocols
├── skills/                    # public installer-facing skills (debrief)
├── tests/                     # ~133 sq-*.test.sh (+ 1 .test.py) — green in CI
├── .pi/                       # adapted tracked Pi extensions (+ Runecraft wiring)
├── .claude/ .codex/ .grok/ .opencode/   # kept-working non-Pi harness adapters (rebranded refs)
├── .github/workflows/         # ci.yml + no-mistakes-required.yml (rebranded)
├── packages/
│   ├── drill/                 # Go CI gate (private pkg.json → turbo tasks)
│   ├── fob/                   # Go worktree-pool CLI (private pkg.json → turbo tasks)
│   ├── pr-review/             # @runecraft/pr-review workspace package (maintained)
│   ├── sq-gh/                 # gh-axi vendored CLI
│   ├── sq-browser/            # chrome-devtools-axi vendored CLI
│   ├── sq-quota/              # quota-axi vendored CLI
│   ├── sq-report/             # lavish-axi vendored CLI
│   └── sq-tasks/              # tasks-axi vendored CLI
├── package.json  turbo.json  tsconfig.base.json  biome.json
├── .tasks.toml  .drill.yaml   # tooling-config filenames KEPT
├── data/ state/ config/ projects/ .env   # commander-private, gitignored
└── .specs/                    # this planning corpus
```

## Scope

**v1 (M0–M4) includes:**

- Single squashed import of firstmate (no history, upstream authors absent from history)
- Complete rebrand sweep: vocabulary, `SQUAD_*` env, `sq-` prefix, AGENTS.md, skills, docs, README/CONTRIBUTING, adapters, `.pi` extensions, tests
- Go deps as workspace packages with turbo build/test tasks; CI builds binaries
- tasks-axi fork as workspace package, published to npm
- `@runecraft/pr-review` integration in the Pi-primary strike flow (P1)
- CI matrix (lint, coverage guard, portable shards, Go builds) + GitHub Releases publication
- Commander-private gitignore hygiene

**v1.1 (M5):** `@runecraft/goal-loop-audit` integration (P2).

**Explicitly out of scope:**

- **TS port of the Go deps** — recorded on the roadmap as a future/open item ("ou não"), explicitly NOT committed
- **npm tarball for the distro** — the distro is consumed by git clone only
- New runtime backends, new task shapes, new hard rules — the inherited mechanics are preserved, not extended
- Upstream sync workflow — accepted cost after a total-removal fork; recorded as an open risk
- Upstream author attribution — **documented decision: total removal** ("o produto será nosso"). See AD-002 legal caveat: MIT *requires* retaining the copyright notice; this decision carries residual legal risk. Flagged once in this spec, once in design, then owned as-is.

## Constraints

- **Identity:** name Squad, prefix `sq-`, env `SQUAD_*`; roles commander / sergeant at arms / operators / XO. Filenames that are tooling conventions are KEPT: `AGENTS.md`, `CLAUDE.md` (symlink), `.tasks.toml`, `.drill.yaml`.
- **Faithfulness:** all ~133 upstream tests kept and rebranded (`sq-*`), green in CI; non-Pi harness adapters kept working; Pi primary via adapted tracked extensions.
- **License:** MIT. See AD-002 — total author removal is a documented deviation with residual legal risk (MIT requires retaining the copyright notice). No `NOTICE.md`, no author name anywhere.
- **Git:** single squashed import, fresh repo, no history.
- **Runecraft:** `@runecraft/pr-review` v1 (P1), `@runecraft/goal-loop-audit` v1.1 (P2); both wired via the Pi extension layer + bin scripts.
- **Specs language:** English.

## Decisions

- **D-2026-08-10 — goal-loop-audit cut:** commander decision — `@runecraft/goal-loop-audit` (Runecraft v1.1; M5 pin 0.28.34) is removed from the distro "for now"; drill/no-mistakes and pr-review stay. `packages/goal-loop-audit/` and `.pi/extensions/sq-goal-loop-audit.ts` deleted; `docs/documentation-audiences.json` entries and `bun.lock` workspace refs removed. This supersedes the v1.1 goal-loop clauses above (G3, runtime-deps table, layout tree) — those remain as charter snapshot text (this spec was frozen at M0 planning; the M6 packages are likewise absent). Re-add path with full provenance (source URL, pin, extraction date) is recorded in ROADMAP.md (M5 section).
