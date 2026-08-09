# Squad — State

**Updated:** M0 execution (session 1)

## Progress

| Milestone | Status | Notes |
| --- | --- | --- |
| M0 — Import & Scaffold | ✅ done (baseline documented; 9 env/decision-attributable failures, 0 source defects — see T-M0-05) | T-M0-01..05 all done |
| M1 — Rebrand Sweep | ⬜ planned | |
| M2 — Deps as Workspace Packages | ⬜ planned | |
| M3 — Pi Adapters + pr-review | ⬜ planned | |
| M4 — Publication & CI | ⬜ planned | |
| M5 — goal-loop-audit + Roadmap note | ⬜ planned | |

## Task log

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
