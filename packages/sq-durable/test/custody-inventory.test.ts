import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { inventoryViolations, LEGACY_WRITERS, type LegacyWriter, scanLegacyWriters, scanText } from "../src/adapter/legacy-writers.js";
import { REPO_ROOT } from "./custody-helpers.js";
import { cleanup, cli, tempDir } from "./helpers.js";

afterEach(cleanup);

/** A copy of the repository's bin/ in a scratch repo, so a test can add a writer without touching the real tree. */
function scratchRepo(): string {
	const repo = join(tempDir(), "repo");
	mkdirSync(repo, { recursive: true });
	cpSync(join(REPO_ROOT, "bin"), join(repo, "bin"), { recursive: true });
	return repo;
}

describe("legacy writer inventory, derived from the code", () => {
	it("is complete for the repository: every writer bin/ contains passes through custody", () => {
		expect(inventoryViolations(REPO_ROOT)).toEqual([]);
	});

	it("knows the writers the plan names and the ones the code adds", () => {
		const scanned = new Set(scanLegacyWriters(REPO_ROOT).map((writer) => writer.path));
		for (const path of ["bin/sq-exec-state.sh", "bin/sq-spawn.sh", "bin/sq-teardown.sh", "bin/sq-sentry.sh", "bin/sq-stall-detect.sh", "bin/sq-backlog-handoff.sh", "bin/sq-send.sh", "bin/sq-decision-hold.sh"]) {
			expect(scanned.has(path), path).toBe(true);
		}
		const inventoried = new Set(LEGACY_WRITERS.map((entry) => entry.path));
		for (const path of scanned) expect(inventoried.has(path), path).toBe(true);
		for (const path of ["bin/sq-merge-local.sh", "bin/sq-pr-merge.sh"]) {
			expect(LEGACY_WRITERS.find((entry) => entry.path === path)?.consults).toEqual(["landing"]);
		}
	});

	it("fails when a new writer of a task record appears without passing through custody", () => {
		const repo = scratchRepo();
		expect(inventoryViolations(repo)).toEqual([]);
		writeFileSync(
			join(repo, "bin", "sq-new-writer.sh"),
			['#!/usr/bin/env bash', 'STATE="$SQUAD_BASE/state"', 'ID=$1', 'printf "x=1\\n" >> "$STATE/$ID.meta"', ""].join("\n"),
		);
		const violations = inventoryViolations(repo);
		expect(violations).toHaveLength(1);
		expect(violations[0]).toContain("bin/sq-new-writer.sh writes task records without passing through custody");
	});

	it("fails for every other way a writer can escape custody", () => {
		const repo = scratchRepo();
		// A new status append, a new writer call and a new indirect record write in files the inventory already knows.
		writeFileSync(join(repo, "bin", "sq-status-writer.sh"), 'status_line_append "$STATE/$ID.status" "working: x"\n');
		writeFileSync(join(repo, "bin", "sq-claimer.sh"), '"$SCRIPT_DIR/sq-exec-state.sh" claim "$ID"\n');
		writeFileSync(join(repo, "bin", "sq-meta-writer.sh"), 'meta="$STATE/$id.meta"\nmv -f "$tmp" "$meta"\n');
		const sentry = join(repo, "bin", "sq-sentry.sh");
		writeFileSync(sentry, `${readFileSync(sentry, "utf8")}\nrm -f "$STATE/$id.meta"\n`);
		const timeout = join(repo, "bin", "sq-timeout-lib.sh");
		writeFileSync(timeout, readFileSync(timeout, "utf8").replace('rm -f "$status_file" 2>/dev/null || true', ":"));
		const merge = join(repo, "bin", "sq-merge-local.sh");
		writeFileSync(merge, readFileSync(merge, "utf8").replace('durable_custody_check "$ID" landing || exit 3', ":"));
		const violations = inventoryViolations(repo).join("\n");
		expect(violations).toContain("bin/sq-status-writer.sh writes task records without passing through custody");
		expect(violations).toContain("bin/sq-claimer.sh writes task records without passing through custody");
		expect(violations).toContain("bin/sq-meta-writer.sh writes task records without passing through custody");
		expect(violations).toMatch(/bin\/sq-sentry\.sh:\d+ writes a task record outside custody review: rm -f "\$STATE\/\$id\.meta"/);
		expect(violations).toContain("bin/sq-timeout-lib.sh pins a write line that no longer exists");
		expect(violations).toContain("bin/sq-merge-local.sh is inventoried as consulting landing but has no durable_custody_check call naming it");
	});

	it("does not accept a consultation or a source that survives only as comment or heredoc text", () => {
		const repo = scratchRepo();
		const replace = (file: string, pattern: RegExp, replacement: string) => {
			const path = join(repo, "bin", file);
			writeFileSync(path, readFileSync(path, "utf8").replace(pattern, replacement));
		};
		replace("sq-check-register.sh", /^durable_custody_check "\$ID" metadata/m, '# durable_custody_check "$ID" metadata');
		replace(
			"sq-x-lib.sh",
			/^  durable_custody_check "\$\{id%\.meta\}" metadata$/m,
			'  cat <<EOF\n  durable_custody_check "${id%.meta}" metadata\nEOF',
		);
		replace("sq-mcp-link.sh", /^\. "\$SCRIPT_DIR\/sq-durable-custody\.sh"$/m, "");
		const violations = inventoryViolations(repo).join("\n");
		expect(violations).toContain("bin/sq-check-register.sh is inventoried as consulting metadata but has no durable_custody_check call naming it");
		expect(violations).toContain("bin/sq-x-lib.sh is inventoried as consulting metadata but has no durable_custody_check call naming it");
		expect(violations).toContain("bin/sq-mcp-link.sh consults custody but never sources bin/sq-durable-custody.sh");
	});

	it("does not accept a consultation that survives only inside a quoted assignment", () => {
		const repo = scratchRepo();
		const file = join(repo, "bin", "sq-pr-check.sh");
		writeFileSync(
			file,
			readFileSync(file, "utf8").replace(/^durable_custody_check "\$ID" metadata/m, 'msg=\'durable_custody_check "$ID" metadata\''),
		);
		expect(inventoryViolations(repo).join("\n")).toContain(
			"bin/sq-pr-check.sh is inventoried as consulting metadata but has no durable_custody_check call naming it",
		);
	});

	it("accepts a consultation in command position after a keyword, a list separator or a case label", () => {
		const repo = scratchRepo();
		const rewrite = (file: string, pattern: RegExp, replacement: string) => {
			const path = join(repo, "bin", file);
			writeFileSync(path, readFileSync(path, "utf8").replace(pattern, replacement));
		};
		rewrite("sq-pr-check.sh", /^durable_custody_check "\$ID" metadata/m, 'if ! durable_custody_check "$ID" metadata; then exit 3; fi');
		rewrite("sq-mcp-link.sh", /^durable_custody_check "\$ID" metadata \|\| exit 3$/m, 'case "$ID" in *) durable_custody_check "$ID" metadata || exit 3 ;; esac');
		rewrite("sq-check-register.sh", /^durable_custody_check "\$ID" metadata \|\| exit 3$/m, ': && durable_custody_check "$ID" metadata || exit 3');
		expect(inventoryViolations(repo)).toEqual([]);
	});

	it("fails when a delegate stops consulting, or an entry outlives its writer", () => {
		const inventory: LegacyWriter[] = LEGACY_WRITERS.map((entry) =>
			entry.path === "bin/sq-spawn.sh" ? { ...entry, consults: [] } : entry,
		);
		inventory.push({ path: "bin/sq-lint.sh", consults: [], note: "not a writer" });
		const violations = inventoryViolations(REPO_ROOT, inventory).join("\n");
		expect(violations).toContain("bin/sq-remote-xo-control.sh delegates to bin/sq-spawn.sh, which consults no custody");
		expect(violations).toContain("bin/sq-lint.sh is inventoried but neither writes task records nor consults custody");
	});

	it("reads code, not the text a script writes or documents", () => {
		const hits = scanText(
			[
				'BRIEF="$DATA/$ID/brief.md"',
				'cat > "$BRIEF" <<EOF',
				'echo "{state}: x" >> $STATUS_FILE',
				"EOF",
				'echo "run bin/sq-pr-check.sh <id> <url>"',
				"hb=$(( HEARTBEAT * (1 << streak) ))",
				'"$SCRIPT_DIR/sq-exec-state.sh" heartbeat "$id"',
				"  bin/sq-merge-local.sh|bin/sq-teardown.sh|\\",
				'grep x "$STATE/$id.meta" 2>/dev/null',
				"printf 'x=1\\n' >> \"$STATE/$id.meta\"",
				'mv -f -- "$tmp" "$(path_for "$id")"',
			].join("\n"),
			"sq-test.sh",
		);
		expect(hits.map((hit) => `${hit.line} ${hit.signature}`)).toEqual(["2 record-write", "7 writer-call", "10 record-write", "11 record-write"]);
	});

	it("prints the derived inventory from the command line", async () => {
		const result = await cli(["custody", "inventory", "--repo", REPO_ROOT, "--json"]);
		expect(result.code).toBe(0);
		expect(result.json.violations).toEqual([]);
		expect(result.json.scanned.map((writer: { path: string }) => writer.path)).toContain("bin/sq-exec-state.sh");
	});
});
