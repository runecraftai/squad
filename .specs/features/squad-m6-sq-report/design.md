# Squad M6 — sq-report — Design

**Status:** Ready for Execute (umbrella pattern locked; two verify-at-execute points flagged)
**Source:** `kunchenguid/lavish-axi` tag `lavish-axi-v0.1.48` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern (with JS specifics)

1. **Vendor:** shallow clone at the tag → `/tmp/m6-dep-lavish-axi`; copy tracked files (335 blobs incl. `src/` (24), `test/` (24 suites), `scripts/` (build.js/build-plugin.js/build-skill.js), `lavish-editor-marketing/` (≈76 MB — marketing site + renders), `plugin.json`, `THIRD-PARTY-NOTICES.md`, `.tool-versions`, tsconfig, prettier, LICENSE, docs, skills/) into `packages/sq-report/`; exclude `.git/ node_modules/ dist/`. Measure the repo-size delta (RISK-M6-02); pruning is a recorded future option, not an M6 decision.
2. **Provenance:** `vendor.json`.
3. **Rename (names only):** per spec.md table. Notable points:
   - `bin/lavish-axi.js` → `bin/sq-report.js`. The published bin output is `dist/cli.mjs` (generic name) — only the `bin` KEY changes to `sq-report`; no output-file rename.
   - release-please `package-name` → `sq-report`; manifest `0.1.48` kept. release-please extra-file JSONPath `plugin.json $.version` KEPT (version state).
   - `plugin.json`: verify at execute — rename only fields that encode the `lavish-axi` NAME (e.g., manifest `name`/`id`); display names and version JSONPath stay (prose/branding defer).
   - src name literals (cli.js/plugin.js/skill.js bin references) follow the new name where they encode the NAME; prose defers.
   - `skills/lavish` KEPT (no `-axi`; "Lavish" is the product/brand name — deferred rebrand). `files[]` entries unchanged.
4. **Keep** pnpm@11.1.1, engines node>=22 (CI node 22 OK), JS toolchain (no tsc; `tsconfig.json` exists for typecheck in `check`), `THIRD-PARTY-NOTICES.md` (legal, untouched).
5. **Tests:** `pnpm build && pnpm test` (vitest, ~24 suites incl. server/whiteboard/mermaid/html-app/export-bundle/telemetry). Browser-tagged suites may need the same env handling as upstream CI — verify at execute. Fix only environment/strictness breaks, documented.
6. **Turbo lint mapping (verify at execute):** upstream has NO `lint` script (has `format`/`format:check` via prettier). Map turbo `lint` to `format:check` or declare lint=none for this package so `turbo run lint` stays green.

## Distro wiring (umbrella T-M6-U2/U3)

- `bin/sq-bootstrap.sh`: COMMON_TOOLS entry + `install_cmd` branch (`npm install -g ./packages/sq-report && sq-report setup hooks` — **verify** `setup hooks` exists in lavish-axi's CLI; upstream install_cmd today groups lavish-axi with the setup-hooks tools, but the subcommand must be confirmed at execute; drop the second half if absent), floor `tool_version_at_least sq-report "$LAVISH_AXI_MIN"` with `LAVISH_AXI_MIN=0.1.48`.
- `bin/sq-procevent-lavish.sh`: `command -v sq-report`; `sq-report poll "$real"`; register id `lavish` KEPT (protocol id, deferred). Script filename `sq-procevent-lavish.sh` has no `-axi` → stays (deferred rebrand would rename to sq-procevent-report.sh).
- `bin/sq-procevent-lib.sh` comment mentioning `lavish-axi poll` → prose, deferred.
- Legacy alias `lavish-axi` → `sq-report` per OQ-M6-01 default (a).
- Tests: fakebins `lavish-axi` → `sq-report` (procevent tests etc.); prose-assertion keep-list exempt.

## Verification

Per-tool: build+test green, pack dry-run lists `dist/cli.mjs` under bin `sq-report`, name grep on name-surfaces → 0, turbo `--filter=sq-report` green (lint mapped), bootstrap MISSING line prints the workspace install for `sq-report`, procevent smoke (`sq-report poll` on a scratch html file) works.
