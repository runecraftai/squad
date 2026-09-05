# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`drill`](https://github.com/runecraftai/squad/tree/main/packages/drill).**  # OQ-03 placeholder
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`drill` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require drill`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that drill writes.
It evaluates every PR opening and body edit independently, so a later edit cannot replace an earlier pending compliance check.
GitHub Actions and Dependabot are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:runecraftai/squad.git`)  # OQ-03 placeholder.
2. Create a branch and make your changes.
3. Initialize the gate with your fork as the push target: `drill init --fork-url git@github.com:<you>/squad.git` (without a fork, plain `drill init` still works for maintainers with push access).
4. Commit your changes.
5. Push through the gate instead of pushing to `origin`:

   ```sh
   git push drill
   ```

6. Run `drill` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed drill version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch to your fork and opens the PR against the parent repo for you.

See the [drill quick start](https://github.com/runecraftai/squad/tree/main/packages/drill)  # OQ-03 placeholder for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a Squad orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled Squad skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Feature branches use the `sq/` prefix (for example `sq/feature-name`), never the retired `fm/` prefix.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `.github/pull_request_template.md`, `bin/`, `.agents/skills/`, `skills/`, and `config/skill-verification.json`.
  `.agents/skills/` holds agent-loaded skills that assume a live Squad base and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no Squad dependency (see the README's "Two-tier skill layout").
  Everything personal to one commander's unit (`.env`, `data/`, `state/`, `projects/`, `.drill/`, and all `config/` files except tracked `config/skill-verification.json`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `sq-tasks` config for `data/backlog.md`; compatible `sq-tasks` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces Squad's routine backlog updates to hand-editing and stays gitignored; validated XO handoffs still delegate through `sq-tasks mv`.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Most helper scripts in `bin/` are plain bash; `sq-skill-verify.py` is the Python skill-verification entrypoint.
  Command-line helpers start with a usage header comment or docstring; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/sq-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, and pinned shellcheck version), and both CI and the drill pre-push gate run it, so local and CI can never diverge.
  It pins one exact shellcheck version and refuses to run under any other; print it with `bin/sq-lint.sh --required-version` and install that build locally.
- Harness-adapter ownership spans detection in `bin/sq-harness.sh`, launch and hook mechanics in `bin/sq-spawn.sh`, semantic busy sources and trust gates in `bin/sq-busy-lib.sh`, delivery-only rendered guards in `bin/sq-tmux-lib.sh`, cleanup in `bin/sq-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`; the `squad-coding-guidelines` skill owns the validation policy for checks that depend on those harnesses.
- Changes to runtime session backends (`bin/sq-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) keep current setup and limits in the relevant backend guide and active empirical evidence in [`docs/verification/runtime-backends.md`](docs/verification/runtime-backends.md).
- [`docs/documentation-audiences.md`](docs/documentation-audiences.md) and its machine-consumed inventory own prose classification; run `bin/sq-doc-audience-check.sh` after documentation changes.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to Squad itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through the `drill` pipeline on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `squad-coding-guidelines` skill (`.agents/skills/squad-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/sq-brief.sh`'s scaffold to detect that a task's repo is Squad itself, so Squad adds this skill's load line to Squad-repo briefs by hand.
An operator picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live operators, keep Squad's own long validation or build commands in the background so sentry wakes can still be handled.
Operator validation follows the installed drill version's SKILL.md and live `axi` help instead of duplicating gate mechanics in Squad docs.
Squad's wrapper still matters: operators route every `ask-user` finding to Squad, which applies the authority contract in `AGENTS.md`, and operators avoid `--yes` because it would bypass that check and any required commander escalation.
Local `.drill/` state and test evidence stay out of this repo; `.drill.yaml` keeps evidence in a temp directory and pins the gate's lint command to `bin/sq-lint.sh`, matching the Linux CI lint job.
Local drill Test is intent-targeted and must not re-run every `tests/*.test.sh`; `.github/workflows/ci.yml` owns the broad behavior suite plus platform-specific compatibility lanes.
That is Squad-specific; do not commit `.drill/evidence/` here even when another drill-managed target project keeps committed PR evidence.

Check and test the toolbelt before pushing:

```sh
while IFS= read -r script; do /bin/bash -n "$script" || exit; done < <(bin/sq-lint.sh --list-files)   # syntax-check the shell surface sq-lint.sh will cover (changed files locally, full set in CI/on main)
bin/sq-lint.sh   # lint that same surface; the single owner CI and the drill gate both run, full set in CI
bin/sq-test-run.sh tests/<subject>.test.sh   # one script (primary local focus path, timed)
bin/sq-test-run.sh --family pure-contract-unit   # ordinary family-scoped local path (serial, timed)
bin/sq-test-run.sh --changed   # conservative changed-file-informed set (never silent full suite)
bin/sq-test-run.sh --proven-isolated --jobs 4   # explicit local parallel of the proven set only (default is serial)
bin/sq-test-run.sh --lane portable-serial   # portable serial remainder (sentry/AFK/tmux/stateful)
bin/sq-test-run.sh --list-lanes   # discover exact lane names, including the current CI serial shards
bin/sq-test-run.sh --check-coverage   # prove portable shards + serial + serial shards + Herdr equal the full inventory
bin/sq-test-run.sh --all   # deliberate complete regression (optional local full walk; not drill Test)
bin/sq-test-isolation-proof.sh --list   # proven parallel candidate set (Phase 2 owner)
bin/sq-test-isolation-proof.sh --jobs 4 --json /tmp/sq-isolation-proof.json   # re-run concurrent isolation proof only
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && SQUAD_STATE_OVERRIDE="$tmp" SQUAD_SIGNAL_GRACE=1 SQUAD_POLL=1 SQUAD_HEARTBEAT=999999 bin/sq-sentry-arm.sh  # sentry re-arm smoke test (prints arm status, then an actionable signal)
```

`bin/sq-test-run.sh` is the single owner of behavior-suite selection, portable CI lane composition, optional local `--jobs` for the proven-isolated set only, per-script timing markers, family totals, the coverage guard, and the optional JSON timing artifact.
Its header and `--help` own the flags, family labels, lanes, and changed-file map; this section only documents the entry points.
`bin/sq-test-isolation-proof.sh` remains the single owner of the Phase 2 concurrent isolation proof and the exact proven candidate set; see `docs/sq-test-isolation-proof.md`.
Portable shard balance evidence lives in `docs/sq-test-portable-shards.md`.
Local drill Test stays intent-targeted and must not wire `commands.test` to `--all` or a `tests/*.test.sh` walk.
Family selection is the ordinary local path; `--all` is deliberate full regression only.
CI owns broad regression across required portable parallel shards, the portable serial lane's separate-runner shards, the Herdr lane, lint, invariants, the coverage guard, and stock macOS Bash compatibility in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
Use `bin/sq-test-run.sh --list-lanes` for exact lane names and `--help` for `--jobs` rules and required gate-skip flags when reproducing a lane locally.
Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so pass one to `bin/sq-test-run.sh` to focus on a subject with canonical timing output.
Tests that need a real optional backend or an explicit opt-in (real herdr/zellij/cmux smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the portable suite remains safe on machines without those tools.
The [Herdr backend guide](docs/herdr-backend.md#destructive-lab-safety) owns the lane's isolation boundary, while [runtime backend verification](docs/verification/runtime-backends.md#herdr) owns active empirical evidence; live harness credential tests remain opt-in.

## Questions

Open an issue on the Squad repository.
