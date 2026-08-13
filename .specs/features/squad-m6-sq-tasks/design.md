# Squad M6 — sq-tasks — Design

**Status:** DELIVERED 2026-08-10; reviewed 2026-08-13 (post-delivery delta: `SQUAD_TASKS_AXI_MIN` reset to 0.1.0 by PR #16)
**Source:** local `packages/tasks-axi` (M2 fork, v0.2.5; upstream kunchenguid/tasks-axi unchanged at 0.2.5)

## Rename mechanics (names only) — ALL DONE

1. **Directory:** `git mv packages/tasks-axi packages/sq-tasks` (preserves tracked files). **Done.**
2. **package.json:** `name` `sq-tasks-axi` → `sq-tasks`; `bin` map + output path → `dist/bin/sq-tasks.js`; `files` → `skills/sq-tasks`. **Done.**
3. **Source bin entry:** `bin/sq-tasks-axi.ts` → `bin/sq-tasks.ts` (tsc emits `dist/bin/sq-tasks.js`; `dist/` gitignored, rebuilt at prepack). **Done.**
4. **Packaged skill dir:** `skills/tasks-axi` → `skills/sq-tasks` (directory-name rule, A-M6-01); content prose defers. **Done** (PR #25 scrub).
5. **release-please-config.json** `package-name` → `sq-tasks`; `.release-please-manifest.json` `".": "0.1.0"` (baseline reset). **Done.**
6. **src name literals:** `src/version.ts` name check + fixtures encoding `sq-tasks-axi` → `sq-tasks`; prose defers. **Done.**
7. **vendor.json (OQ-M6-06 (a)):** added for the M2 copy (upstream tag v0.2.5 provenance) — closes the M2 gap. **Done.** Note: its notes field originally claimed "SQUAD_TASKS_AXI_MIN stays 0.2.4"; corrected during this review (2026-08-13) to the 0.1.0 baseline fact (PR #16).

## Distro lib rename (commander-mandated) — ALL DONE

- `bin/sq-tasks-axi-lib.sh` → `bin/sq-tasks-lib.sh` (via `git mv`); resolver `fm_tasks_axi_cmd` prefers `sq-tasks` → fallback `tasks-axi`; `SQUAD_TASKS_AXI_MIN=0.1.0` (reset by PR #16). **Done.**
- Source-path updates in: `bin/sq-bootstrap.sh`, `bin/sq-public-followup.sh`, `bin/sq-public-followup-lib.sh`, `bin/sq-public-followup-emit.sh`, `bin/sq-unit-snapshot.sh`, `bin/sq-x-poll.sh`, plus the later-added sources (sq-backlog-handoff.sh, sq-backlog-receive.sh, sq-decision-hold.sh, sq-remote-doctor.sh, sq-teardown.sh, sq-session-start.sh, sq-test-run.sh). **Done.**
- The M2 "fork-first resolver + bare `tasks-axi` call sites" contract (T-M2-05) is preserved: runtime call sites keep invoking `tasks-axi` so PATH shadowing keeps working; only the resolver's preferred name changed. **Done.**

## CI + bootstrap — ALL DONE

- Bootstrap: `COMMON_TOOLS` `tasks-axi` → `sq-tasks`; `install_cmd` branch `sq-tasks|sq-quota` → `npm install -g ./packages/sq-tasks`; compatibility probe unchanged in shape. **Done.**
- CI: `tasks-axi` job → `sq-tasks` (path `packages/sq-tasks`, `sq-tasks --version`, alias `tasks-axi`); the three test-lane install steps update path + alias. **Done.**
- `config/backlog-backend=tasks-axi` protocol value, the `tasks-axi` alias itself are durable deferred contracts — unchanged by M6. **Confirmed.**

## Verification — DONE

Per-tool: rename greps (name-surfaces → 0), pnpm build+test green (429/1 baseline), pack dry-run lists `dist/bin/sq-tasks.js`, resolver unit behavior (`fm_tasks_axi_cmd` with fake `sq-tasks` on PATH), CI alias smoke (`tasks-axi` → `sq-tasks`), umbrella guard. Regression batch (sq-decision-hold-lifecycle, sq-public-followup, sq-backend conformance/orca/zellij recon teardowns) green with the renamed fork active. Re-verified 2026-08-13 (guard green).
