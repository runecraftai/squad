# Squad Inception — Context & Decisions

All decisions below are **FINAL** (user-confirmed). They were captured before planning and are treated as locked: no re-research, no re-asking. New conflicts discovered during planning are recorded as open risks (RISK-*) rather than silently changing a decision.

## AD — Architecture Decisions

| ID | Decision | Detail | Rationale / Source |
| --- | --- | --- | --- |
| AD-001 | **Name & identity** | Name **Squad**; prefix `sq-`; env `SQUAD_*`; project root `/home/rehem/Projects/squad/`; tagline **"Talk to one agent. Deploy with a squad."** | User-confirmed branding |
| AD-002 | **Total author removal (MIT caveat)** | TOTAL removal of all upstream author mentions — "o produto será nosso". No `NOTICE.md`, no author name anywhere (docs, LICENSE, CHANGELOG, badges, URLs, module paths, history). **Legal caveat (flagged once, then owned):** MIT *requires* retaining the copyright notice in copies; removing it is a deviation from the MIT license terms and carries residual legal risk. This is a documented, accepted risk, not an oversight. | User order; flagged as RISK-01 |
| AD-003 | **Roles** | Human = **commander**; liaison agent = **sergeant at arms**; crewmates = **operators**; secondmates = **XOs** | User-confirmed vocabulary |
| AD-004 | **Go handling** | Keep Go source in the monorepo with turbo build tasks; CI builds binaries → GitHub Releases. **TS port is a FUTURE roadmap item** — explicitly "ou não": recorded as open/optional, NOT committed (no design, no tasks, no dates) | User decision |
| AD-005 | **Go module paths** | `go.mod` module paths of the forks must be renamed (they cannot retain `github.com/kunchenguid/*` under AD-002). Exact new path NOT decided by the user — **open decision**: default recommendation `github.com/<squad-org>/squad/packages/<name>` (or a `squad.dev/...` vanity path); executor picks one and records it. See RISK-02 | Forced by AD-002; recorded as open |
| AD-006 | **tasks-axi npm name** | Fork must publish to npm under a Squad-owned name. `tasks-axi` is taken upstream — **open decision**: default recommendation `sq-tasks-axi` (bin `sq-tasks-axi`); availability must be verified at publish time. See RISK-04 | Forced by AD-002 + upstream ownership |
| AD-007 | **Publication paths** | tasks-axi fork → npm; Go binaries → GitHub Releases; **distro → git clone** (no npm tarball for the distro) | User decision |
| AD-008 | **Specs language** | English (all `.specs/` artifacts) | User decision |
| AD-009 | **Tests** | Keep all ~133 tests (132 `*.test.sh` + 1 `*.test.py`), rebranded (`sq-*`), green in CI; same coverage as upstream baseline | User decision |
| AD-010 | **Git history** | Single squashed import, no history, fresh repo; upstream authors absent from history (import commit authored by the Squad owner, no co-authors) | User decision |
| AD-011 | **Repo hygiene** | `data/ state/ config/ projects/ .env` gitignored (commander-private), same as upstream; `.no-mistakes/`, `.lavish/`, secondmate home markers also gitignored | User decision |
| AD-012 | **Tooling-convention filenames kept** | `AGENTS.md` filename KEPT (tooling convention); `CLAUDE.md` symlink, `.tasks.toml`, `.no-mistakes.yaml`, `.claude/skills` symlink also kept; content rebranded | User decision |
| AD-013 | **Harness adapters** | Non-Pi harness adapters (claude/codex/opencode/grok) kept working; Pi primary via adapted tracked extensions (`.pi/extensions/`) | User decision |
| AD-014 | **Runecraft scope** | v1 = `@runecraft/pr-review` integration (P1) wired into the Pi-primary strike flow; v1.1 = `@runecraft/goal-loop-audit` (P2); both as workspace packages wired via Pi extension layer + bin scripts | User decision |
| AD-015 | **Vocab table** | See design.md §2 — the complete default-accepted mapping (captain→commander, firstmate→sergeant at arms, crewmate→operator, fleet→unit, ship→strike, scout→recon, secondmate→XO, treehouse→FOB, watch→sentry, wake-queue→stand-to queue, `/ahoy`→`/reporting`, `/bearings`→`/sitrep`, `/stow`→`/debrief`, `fm-`→`sq-`, `FM_*`→`SQUAD_*`, read-only boundary→the perimeter) | User decision ("defaults accepted, complete the table") |

## Assumptions (delegated planning — made by the planner, NOT user-confirmed)

| # | Assumption | Notes |
| --- | --- | --- |
| A-01 | `.specs/` planning corpus is committed as part of the initial squashed import commit (M0) | It is tracked content of the Squad repo, not upstream content |
| A-02 | `bin/backends/` (tmux/herdr/zellij/orca/cmux) mechanism and filenames stay intact; only content refs rebranded | Backend names are tool names, not vocabulary |
| A-03 | Vocab applies to script names when the name contains a mapped word (`fm-watch.sh`→`sq-sentry.sh`, `fm-wake-drain.sh`→`sq-stand-to-drain.sh`); otherwise mechanical `fm-`→`sq-` prefix swap | See design.md §2 rule |
| A-04 | `skills/` public dir `stow` → `debrief` (mapping `/stow`→`/debrief` applied to the public installer skill) | Public `skills/` holds only `stow` upstream |
| A-05 | Private data filenames rebrand per vocab: `data/captain.md`→`commander.md`, `captain-shared.md`→`commander-shared.md`, `secondmates.md`→`XOs.md` | Gitignored material, but seeds create them; keep consistent |
| A-06 | State dir names (`state/<id>.wake-queue` → stand-to queue) follow the vocab table; `.wake-queue` internals renamed to `.stand-to-queue` where referenced by scripts | Consistency with AD-015 |
| A-07 | Runecraft packages are vendored from the local harness clone `/home/rehem/Projects/harness` (pinned versions, provenance recorded), not from npm | Mirrors harness F1/F5 vendoring practice |
| A-08 | pr-review's live-PR validation is a 1× documented manual validation (needs `gh` auth + test repo), NOT a CI gate | Mirrors harness F5 decision; honest gate boundary |
| A-09 | Go build toolchain: `go 1.25.x` as upstream (`go.mod`); CI ubuntu-latest + macos-latest with the pinned toolchain | Verified from clones (`go 1.25.5` / `go 1.25.0`) |

## Open Questions (recorded, NOT blocking)

| # | Question | Where it lands |
| --- | --- | --- |
| OQ-01 | Exact new Go module path for fob / no-mistakes forks (AD-005) | ✅ **Resolved at M2 (finalized at M4):** `github.com/runecraftai/squad/packages/fob` and `github.com/runecraftai/squad/packages/no-mistakes` |
| OQ-02 | Exact npm package name for the tasks-axi fork (AD-006) | ✅ **Resolved at M2:** `sq-tasks-axi` (bin `sq-tasks-axi`); availability re-verified at M4 publish |
| OQ-03 | Squad GitHub org / repository URL (needed for README clone URL, Release assets, badge links) | ✅ **Resolved at M4:** `github.com/runecraftai/squad` (public repo created 2026-08-10; org login `runecraftai`) |

## Decisions explicitly NOT made (by user order)

- **TS port of the Go deps** — open/optional ("ou não"), NOT committed (AD-004)
- **Upstream sync process** — accepted cost after total-removal fork (RISK-03)

## Risks

| # | Risk | Severity | Mitigation / Status |
| --- | --- | --- | --- |
| RISK-01 | **Legal: MIT requires retaining the copyright notice; AD-002 removes all attribution** | High (legal) | Flagged once here and in design.md §9. Accepted by user order ("o produto será nosso"). No mitigation beyond documentation; revisit only at commander's explicit request |
| RISK-02 | Module path rename breaks Go internal imports / tooling that assumes `github.com/kunchenguid/*` | Medium | Mechanical rename verified by `go build`/`go test` gates in M2 |
| RISK-03 | Upstream sync becomes impractical after total-removal fork (diff noise, no upstream in history) | Medium | Accepted cost; recorded; revisit if upstream mechanics become indispensable |
| RISK-04 | npm name collision for the tasks-axi fork | Low | Verify availability at publish (AD-006); fallback name candidates recorded |
| RISK-05 | Rebrand sweep misses cross-references (65KB AGENTS.md + 130 bin files (128 .sh + 2 .mjs) + 19 skills are deeply interlinked) | Medium | Sweep order (design.md §2) + repo-wide grep guards + full suite gate at end of M1; no partial green states |
| RISK-06 | Test assertions that encode upstream identity (e.g., `FM_HOME`, `bin/fm-*` paths, vocab in output checks) break after rename | Medium | M1-10 rebrands assertions as part of the sweep; baseline diff reviewed before suite run |
| RISK-07 | Runecraft packages' peer deps (`@earendil-works/pi-*`) not resolvable in the Squad workspace | Low | Mirror harness workspace strategy; bun workspaces hoist peers; validated in M3 |
| RISK-08 | pi-signed marker (`FM_PI_HARNESS=pi-signed`) rename to `SQUAD_PI_HARNESS` could break detection if any external tool reads the old name | Low | Internal-only env; verified by `sq-harness.sh` tests (harness-detection suite) |

## Session memory note

- Task works well with faster/cheaper models once the sweep tables (design.md §2/§3) are frozen — the work is mechanical replacement + verification, not reasoning.
- Decision capture: prefer recording decisions here (context.md) over re-asking; all AD-* are locked.
