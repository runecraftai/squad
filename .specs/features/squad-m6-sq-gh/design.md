# Squad M6 — sq-gh — Design

**Status:** Ready for Execute (umbrella pattern locked; OQ-M6 defaults recommended)
**Source:** `kunchenguid/gh-axi` tag `gh-axi-v0.1.30` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern

1. **Vendor:** shallow clone at `gh-axi-v0.1.30` → `/tmp/m6-dep-gh-axi`; copy tracked files (133 blobs: `bin/`, `src/` (20 files), `test/` (20 test files), `scripts/build-skill.ts`, `.airlock/lint.sh`, release-please files, tsconfig, eslint, LICENSE, docs) into `packages/sq-gh/`; exclude `.git/ node_modules/ dist/`.
2. **Provenance:** `vendor.json` (URL, tag, sha256 of package.json + source, date).
3. **Rename (names only):** per spec.md rename table. Notable points:
   - `bin/gh-axi.ts` → `bin/sq-gh.ts`; tsc emits `dist/bin/sq-gh.js` (dist gitignored; `npm pack` picks it up after build).
   - `package.json` bin map + `files` (`skills/gh-axi` → `skills/sq-gh`); rename the packaged skill dir too.
   - `release-please-config.json` `package-name` → `sq-gh`; `.release-please-manifest.json` `".": "0.1.30"` kept.
   - `src/version.ts` name check + `src/skill.ts` bin references follow the new name where they encode the NAME; prose strings defer.
4. **Keep pnpm@11.1.1** inside the package (RISK-10 fidelity); root stays bun.
5. **Tests:** `pnpm install --frozen-lockfile && pnpm build && pnpm test` (vitest, ~20 suites). Fix only environment/strictness breaks, documented (M5 precedent).

## Distro wiring (with umbrella T-M6-U2/U3)

- `bin/sq-bootstrap.sh`: `COMMON_TOOLS` + `install_cmd` (`npm install -g ./packages/sq-gh && sq-gh setup hooks`), floor `tool_version_at_least sq-gh "$GH_AXI_MIN"` with `GH_AXI_MIN=0.1.30`.
- `bin/sq-pr-merge.sh`: `sq-gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ...`
- `bin/sq-teardown.sh`: `sq-gh pr list --state all --head "$branch" --limit 1`
- Legacy alias `gh-axi` → `sq-gh` per OQ-M6-01 default (a) (CI + bootstrap install).
- Tests: fakebin stubs `gh-axi` → `sq-gh` (e.g., `tests/sq-pr-merge.test.sh`, `tests/sq-teardown.test.sh`); prose assertions deferred (keep-list).
- `bin/sq-brief.sh` prose "Use gh-axi…" → deferred (roadmap item).

## Verification

Per-tool: build+test green, pack dry-run lists `dist/bin/sq-gh.js`, name grep on name-surfaces → 0, turbo `--filter=sq-gh` green, `sq-bootstrap.sh` MISSING line prints the workspace install for `sq-gh`.
