# Squad M6 — sq-tasks — Design

**Status:** Ready for Execute (commander-mandated rename; OQ-M6-06 default (a) recommended)
**Source:** local `packages/tasks-axi` (M2 fork, v0.2.5; upstream kunchenguid/tasks-axi unchanged at 0.2.5)

## Rename mechanics (names only)

1. **Directory:** `git mv packages/tasks-axi packages/sq-tasks` (preserves the 77 tracked files and their history-less state).
2. **package.json:** `name` `sq-tasks-axi` → `sq-tasks`; `bin` map + output path → `dist/bin/sq-tasks.js`; `files` → `skills/sq-tasks`.
3. **Source bin entry:** `bin/sq-tasks-axi.ts` → `bin/sq-tasks.ts` (tsc emits `dist/bin/sq-tasks.js`; `dist/` is gitignored, rebuilt at prepack).
4. **Packaged skill dir:** `skills/tasks-axi` → `skills/sq-tasks` (directory-name rule, A-M6-01); content prose defers.
5. **release-please-config.json** `package-name` → `sq-tasks` (verify current value first — M2 may have set it); `.release-please-manifest.json` `".": "0.2.5"` kept.
6. **src name literals:** `src/version.ts` name check + any fixture/string encoding the bin name `sq-tasks-axi` → `sq-tasks`; prose defers.
7. **vendor.json (OQ-M6-06 default (a)):** add provenance for the M2 copy (upstream tag v0.2.5 / the M2 import, sha256 of package.json + source, date) — closes the M2 gap and makes the provenance convention uniform.

## Distro lib rename (commander-mandated)

- `bin/sq-tasks-axi-lib.sh` → `bin/sq-tasks-lib.sh` (via `git mv`); header comment updated for the new name (name reference); resolver `fm_tasks_axi_cmd` prefers `sq-tasks` → fallback `tasks-axi` (pre-M6 envs + the protocol alias); `SQUAD_TASKS_AXI_MIN=0.2.4` untouched.
- Source-path updates in: `bin/sq-bootstrap.sh` (if it sources the lib), `bin/sq-public-followup.sh`, `bin/sq-public-followup-lib.sh`, `bin/sq-public-followup-emit.sh`, `bin/sq-unit-snapshot.sh`, `bin/sq-x-poll.sh`, and any test sourcing it.
- The M2 "fork-first resolver + bare `tasks-axi` call sites" contract (T-M2-05) is preserved: runtime call sites keep invoking `tasks-axi` so PATH shadowing (fakebin stubs, CI alias) keeps working; only the resolver's preferred name changes.

## CI + bootstrap

- Bootstrap: `COMMON_TOOLS` `tasks-axi` → `sq-tasks`; `install_cmd` branch `sq-tasks|sq-quota` → `npm install -g ./packages/sq-tasks`; compatibility probe unchanged in shape (version floor + `--archive-body` + multi-ID `mv` probes).
- CI: `tasks-axi` job → `sq-tasks` (path `packages/sq-tasks`, `sq-tasks --version`, alias `tasks-axi`); the three test-lane install steps update path + alias `ln -s "$(command -v sq-tasks)" .../tasks-axi`.
- `config/backlog-backend=tasks-axi` protocol value, `SQUAD_TASKS_AXI_MIN`, and the `tasks-axi` alias itself are durable deferred contracts — unchanged by M6.

## Verification

Per-tool: rename greps (name-surfaces → 0), pnpm build+test green (429/1 baseline), pack dry-run lists `dist/bin/sq-tasks.js`, resolver unit behavior (`fm_tasks_axi_cmd` with fake `sq-tasks` on PATH), CI alias smoke (`tasks-axi` → `sq-tasks`), umbrella guard. Regression batch: the M2 gate-unlocked tests (sq-decision-hold-lifecycle, sq-public-followup, sq-backend conformance/orca/zellij recon teardowns) must stay green with the renamed fork active.
