# Squad M6 — sq-gh — Design

**Status:** DELIVERED 2026-08-10; reviewed 2026-08-13 (post-delivery deltas: 0.1.0 baseline reset PR #16, no legacy gh-axi alias, skill dir scrubbed PR #25)
**Source:** `kunchenguid/gh-axi` tag `gh-axi-v0.1.30` (researched read-only)

## Mirrors the M2 tasks-axi fork pattern — ALL DONE

1. **Vendor:** shallow clone at `gh-axi-v0.1.30` → `/tmp/m6-dep-gh-axi`; tracked files copied into `packages/sq-gh/`; `.git/ node_modules/ dist/` excluded. **Done.**
2. **Provenance:** `vendor.json` (URL, tag, sha256, date). **Done.**
3. **Rename (names only):** per spec.md rename table — `bin/sq-gh.ts`, package.json name/bin/files, `skills/sq-gh`, release-please `package-name: sq-gh`, src name literals. **Done.** Note: package version and `GH_AXI_MIN` are now 0.1.0 (PR #16 clean-baseline reset); vendor.json retains the 0.1.30 upstream pin.
4. **Keep pnpm@11.1.1** inside the package (RISK-10 fidelity); root stays bun. **Done.**
5. **Tests:** `pnpm install --frozen-lockfile && pnpm build && pnpm test` (vitest) green in-workspace + CI `axi-tools` matrix. **Done.**

## Distro wiring (with umbrella T-M6-U2/U3) — ALL DONE

- `bin/sq-bootstrap.sh`: `COMMON_TOOLS` + `install_cmd` (`npm install -g ./packages/sq-gh && sq-gh setup hooks`), floor `tool_version_at_least sq-gh "$GH_AXI_MIN"` with `GH_AXI_MIN=0.1.0`. **Done.**
- `bin/sq-pr-merge.sh`: `sq-gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ...` — **done.**
- `bin/sq-teardown.sh`: `sq-gh pr list --state all --head "$branch" --limit 1` — **done.**
- Legacy alias `gh-axi` → `sq-gh` per OQ-M6-01 default (a): **NOT created** (review 2026-08-13) — only the mandatory `tasks-axi` alias exists; deferred prose naming `gh-axi` stays in the guard keep-list.
- Tests: fakebin stubs `gh-axi` → `sq-gh`. **Done.**
- `bin/sq-brief.sh` prose "Use gh-axi…" → deferred (roadmap item).

## Verification — DONE

Per-tool: build+test green, pack dry-run lists `dist/bin/sq-gh.js`, name grep on name-surfaces → 0, turbo `--filter=sq-gh` green, `sq-bootstrap.sh` MISSING line prints the workspace install for `sq-gh`. All re-verified 2026-08-13 (guard green).
