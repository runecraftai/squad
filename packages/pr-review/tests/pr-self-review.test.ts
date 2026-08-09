import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
	buildSelfReviewChangedLineAnchors,
	buildSelfReviewDelta,
	parseSelfReviewOutput,
	SelfReviewPermitCoordinator,
	SELF_REVIEW_TOOL_NAME,
} from "../lib/pr-self-review.ts";

const roots: string[] = [];

function readFileIfPresent(filePath: string): string | undefined {
	return existsSync(filePath) ? readFileSync(filePath, "utf8") : undefined;
}

afterEach(() => {
	for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function git(root: string, ...args: string[]): string {
	const result = spawnSync("/usr/bin/git", args, { cwd: root, encoding: "utf8" });
	if (result.status !== 0) throw new Error(result.stderr || `git ${args.join(" ")} failed`);
	return result.stdout.trim();
}

function repository(): string {
	const root = mkdtempSync(join(tmpdir(), "pi-self-review-"));
	roots.push(root);
	git(root, "init", "-q");
	writeFileSync(join(root, "tracked.ts"), "export const value = 1;\n");
	git(root, "add", "tracked.ts");
	git(root, "-c", "user.name=Self Review Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial");
	return root;
}

function repositoryWithSubmodule(): string {
	const child = repository();
	const root = repository();
	git(root, "-c", "protocol.file.allow=always", "submodule", "add", "-q", child, "child");
	git(root, "-c", "user.name=Self Review Test", "-c", "user.email=test@example.invalid", "commit", "-qam", "add child");
	return root;
}

function harness(root: string, gitExecutable?: string) {
	let activeTools = ["read", SELF_REVIEW_TOOL_NAME];
	let reviewActive = false;
	const session = { id: "session-1", startedAt: "2026-07-13T00:00:00.000Z" };
	const pi = {
		getActiveTools: () => [...activeTools],
		setActiveTools: (next: string[]) => {
			activeTools = [...next];
		},
	};
	const ctx = {
		cwd: root,
		sessionManager: {
			getSessionId: () => session.id,
			getHeader: () => ({ id: session.id, timestamp: session.startedAt }),
		},
	};
	const coordinator = new SelfReviewPermitCoordinator(pi as any, () => reviewActive, gitExecutable);
	coordinator.hideTool();
	return {
		coordinator,
		ctx,
		session,
		setReviewActive: (active: boolean) => {
			reviewActive = active;
		},
		activeTools: () => [...activeTools],
	};
}

describe("one-shot self-review authority", () => {
	test("binds a clean direct task and atomically rejects concurrent and replayed consumes", async () => {
		const root = repository();
		const h = harness(root);
		expect(h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any)).toBeTrue();
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		expect(h.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);

		writeFileSync(join(root, "tracked.ts"), "export const value = 2;\n");
		writeFileSync(join(root, "new.ts"), "export const added = true;\n");
		expect(h.coordinator.bindToolCall("self-call", h.ctx as any)).toBeTrue();
		const permits = await Promise.all([
			h.coordinator.consume("self-call", h.ctx as any),
			h.coordinator.consume("self-call", h.ctx as any),
		]);
		const winners = permits.filter(Boolean);
		expect(winners).toHaveLength(1);
		expect(h.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
		expect(await h.coordinator.consume("self-call", h.ctx as any)).toBeUndefined();

		const permit = winners[0]!;
		const captured = await buildSelfReviewDelta(permit);
		expect(captured.fileCount).toBe(2);
		expect(captured.delta).toContain("tracked.ts");
		expect(captured.delta).toContain("new.ts");
		expect(captured.delta).toContain("export const value = 2;");
		expect(captured.delta).toContain("export const added = true;");
		h.coordinator.finish(permit);
	});

	test("rejects extension, queued, dirty-start, session-changed, and /pr-review-overlap authority", async () => {
		const root = repository();
		const h = harness(root);
		expect(h.coordinator.noteTopLevelInput("extension", undefined, h.ctx as any)).toBeFalse();
		expect(h.coordinator.noteTopLevelInput("rpc", "followUp", h.ctx as any)).toBeFalse();

		writeFileSync(join(root, "tracked.ts"), "dirty before task\n");
		expect(h.coordinator.noteTopLevelInput("rpc", undefined, h.ctx as any)).toBeTrue();
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeFalse();
		expect(h.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);

		git(root, "checkout", "--", "tracked.ts");
		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		expect(h.coordinator.bindToolCall("changed-session", h.ctx as any)).toBeTrue();
		h.session.startedAt = "2026-07-14T00:00:00.000Z";
		expect(await h.coordinator.consume("changed-session", h.ctx as any)).toBeUndefined();

		h.session.startedAt = "2026-07-13T00:00:00.000Z";
		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		expect(h.coordinator.bindToolCall("review-overlap", h.ctx as any)).toBeTrue();
		h.setReviewActive(true);
		expect(await h.coordinator.consume("review-overlap", h.ctx as any)).toBeUndefined();
		expect(h.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
	});

	test("fails closed instead of reviewing an outer-only diff for a dirty submodule", async () => {
		const root = repositoryWithSubmodule();
		const h = harness(root);
		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		writeFileSync(join(root, "child", "tracked.ts"), "export const value = 2;\n");
		h.coordinator.bindToolCall("submodule", h.ctx as any);
		const permit = (await h.coordinator.consume("submodule", h.ctx as any))!;
		await expect(buildSelfReviewDelta(permit)).rejects.toThrow("submodule commit or worktree is changed or dirty");
		h.coordinator.finish(permit);
	});

	test("consumes the permit but fails closed if HEAD moves or there is no delta", async () => {
		const root = repository();
		const h = harness(root);
		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		h.coordinator.bindToolCall("empty", h.ctx as any);
		const emptyPermit = (await h.coordinator.consume("empty", h.ctx as any))!;
		await expect(buildSelfReviewDelta(emptyPermit)).rejects.toThrow("no Git-visible working-tree delta");
		expect(await h.coordinator.consume("empty", h.ctx as any)).toBeUndefined();
		h.coordinator.finish(emptyPermit);

		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		writeFileSync(join(root, "tracked.ts"), "export const value = 3;\n");
		git(root, "add", "tracked.ts");
		git(root, "-c", "user.name=Self Review Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "move head");
		h.coordinator.bindToolCall("moved-head", h.ctx as any);
		const movedPermit = (await h.coordinator.consume("moved-head", h.ctx as any))!;
		await expect(buildSelfReviewDelta(movedPermit)).rejects.toThrow("HEAD changed");
	});

	test("denies unbound and mismatched dispatches without consuming reusable authority", async () => {
		const root = repository();
		const h = harness(root);
		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		expect(await h.coordinator.consume("direct-dispatch", h.ctx as any)).toBeUndefined();
		expect(h.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);
		expect(h.coordinator.bindToolCall("sole-self-review", h.ctx as any)).toBeTrue();
		expect(await h.coordinator.consume("mutating-sibling", h.ctx as any)).toBeUndefined();
		expect(h.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);
		expect(h.coordinator.bindToolCall("replacement", h.ctx as any)).toBeFalse();
		expect(await h.coordinator.consume("sole-self-review", h.ctx as any)).toBeDefined();
		expect(h.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
	});

	test("binds one injected canonical Git executable through baseline, permit, and delta", async () => {
		const root = repository();
		const wrapper = join(root, "trusted-git");
		const logRoot = mkdtempSync(join(tmpdir(), "pi-self-review-git-log-"));
		roots.push(logRoot);
		const log = join(logRoot, "trusted-git.log");
		writeFileSync(wrapper, `#!/bin/sh\nprintf '%s\\n' "$*" >> '${log}'\nexec /usr/bin/git "$@"\n`, { mode: 0o700 });
		git(root, "add", "trusted-git");
		git(root, "-c", "user.name=Self Review Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "trusted git fixture");
		const h = harness(root, wrapper);
		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		expect(await h.coordinator.beginTask(h.ctx as any)).toBeTrue();
		writeFileSync(join(root, "tracked.ts"), "export const value = 9;\n");
		h.coordinator.bindToolCall("trusted-git", h.ctx as any);
		const permit = (await h.coordinator.consume("trusted-git", h.ctx as any))!;
		expect(permit.gitExecutable).toBe(realpathSync(wrapper));
		await buildSelfReviewDelta(permit);
		const calls = readFileSync(log, "utf8");
		expect(calls).toContain("rev-parse --show-toplevel");
		expect(calls).toContain("status --porcelain=v2");
		expect(calls).toContain("diff --binary");
	});

	test("aborts pending baseline capture promptly when task authority is cleared", async () => {
		const root = repository();
		const hangingGit = join(root, "hanging-git");
		const started = join(root, "hanging-git.started");
		writeFileSync(hangingGit, `#!${process.execPath}\nrequire("node:fs").writeFileSync(${JSON.stringify(started)}, "started");\nsetInterval(() => {}, 1000);\n`, { mode: 0o700 });
		const h = harness(root, hangingGit);
		h.coordinator.noteTopLevelInput("interactive", undefined, h.ctx as any);
		const beginning = h.coordinator.beginTask(h.ctx as any);
		for (let attempts = 0; attempts < 100 && !readFileIfPresent(started); attempts++) {
			await new Promise((resolve) => setTimeout(resolve, 5));
		}
		expect(readFileIfPresent(started)).toBe("started");
		const clearedAt = Date.now();
		h.coordinator.clear();
		expect(await Promise.race([
			beginning,
			new Promise<"late">((resolve) => setTimeout(() => resolve("late"), 500)),
		])).toBeFalse();
		expect(Date.now() - clearedAt).toBeLessThan(500);
	});
});

const validFinding = {
	title: "[P2] Preserve the permit until settlement",
	severity: "P2",
	blocking: false,
	impact: "Queued continuation loses its one-shot review authority.",
	trigger: "Pi emits agent_end before an automatic continuation.",
	evidence: "The changed handler clears the coordinator at agent_end.",
	path: "extensions/review-table.ts",
	startLine: 574,
	endLine: 576,
	side: "RIGHT",
	inDiff: true,
	prRelated: true,
	confidence: 0.98,
};

const validDelta = [
	"diff --git a/extensions/review-table.ts b/extensions/review-table.ts",
	"index 1111111..2222222 100644",
	"--- a/extensions/review-table.ts",
	"+++ b/extensions/review-table.ts",
	"@@ -573,4 +574,4 @@",
	"-old one",
	"-old two",
	"-old three",
	"+new one",
	"+new two",
	"+new three",
	" unchanged",
	"",
].join("\n");
const validAnchors = buildSelfReviewChangedLineAnchors(validDelta);
const parse = (text: string) => parseSelfReviewOutput(text, validAnchors);

describe("self-review output validation", () => {
	test("accepts only the exact empty or P0-P2 evidence schema", () => {
		expect(parse('{"findings":[]}')).toEqual({ findings: [] });
		expect(parse(JSON.stringify({ findings: [validFinding] }))).toEqual({ findings: [validFinding] });
	});

	test("rejects malformed JSON, prose wrappers, and extra or missing fields", () => {
		expect(() => parse("NO FINDINGS.")).toThrow("strict JSON");
		expect(() => parse('```json\n{"findings":[]}\n```')).toThrow("strict JSON");
		expect(() => parse(JSON.stringify({ findings: [], summary: "none" }))).toThrow("exactly");
		const { evidence: _evidence, ...missingEvidence } = validFinding;
		expect(() => parse(JSON.stringify({ findings: [missingEvidence] }))).toThrow("exactly");
		expect(() => parse(JSON.stringify({ findings: [{ ...validFinding, suggestion: "nit" }] }))).toThrow("exactly");
	});

	test("rejects P3/nit leakage and inconsistent evidence metadata", () => {
		expect(() => parse(JSON.stringify({ findings: [{ ...validFinding, title: "[P3] Rename this", severity: "P3" }] }))).toThrow("P0, P1, or P2");
		expect(() => parse(JSON.stringify({ findings: [{ ...validFinding, title: "[P1] Preserve authority" }] }))).toThrow("match its severity");
		expect(() => parse(JSON.stringify({ findings: [{ ...validFinding, blocking: true }] }))).toThrow("blocking");
		expect(() => parse(JSON.stringify({ findings: [{ ...validFinding, inDiff: false }] }))).toThrow("in-diff");
		expect(() => parse(JSON.stringify({ findings: [{ ...validFinding, path: "../outside.ts" }] }))).toThrow("repo-relative");
		expect(() => parse(JSON.stringify({ findings: [{ ...validFinding, confidence: 1.1 }] }))).toThrow("between 0 and 1");
	});

	test("requires the complete claimed range on changed lines in one exact path/side hunk", () => {
		expect(parse(JSON.stringify({ findings: [{ ...validFinding, side: "LEFT", startLine: 573, endLine: 575 }] })))
			.toEqual({ findings: [{ ...validFinding, side: "LEFT", startLine: 573, endLine: 575 }] });
		for (const finding of [
			{ ...validFinding, path: "lib/other.ts" },
			{ ...validFinding, side: "LEFT", startLine: 576, endLine: 576 },
			{ ...validFinding, startLine: 573, endLine: 574 },
			{ ...validFinding, startLine: 577, endLine: 577 },
		]) {
			expect(() => parse(JSON.stringify({ findings: [finding] }))).toThrow("entirely on changed lines");
		}

		const separatedHunks = buildSelfReviewChangedLineAnchors([
			"diff --git a/file.ts b/file.ts",
			"--- a/file.ts",
			"+++ b/file.ts",
			"@@ -10 +10 @@",
			"-old",
			"+new",
			"@@ -20 +20 @@",
			"-old",
			"+new",
			"",
		].join("\n"));
		const separated = { ...validFinding, path: "file.ts", startLine: 10, endLine: 20 };
		expect(() => parseSelfReviewOutput(JSON.stringify({ findings: [separated] }), separatedHunks))
			.toThrow("one captured diff hunk");
	});

	test("normalizes the delimiter tab from unquoted no-index marker paths", () => {
		const untrackedAnchors = buildSelfReviewChangedLineAnchors([
			"diff --git a/space file.ts b/space file.ts",
			"new file mode 100644",
			"--- /dev/null",
			"+++ b/space file.ts\t",
			"@@ -0,0 +1 @@",
			"+export const added = true;",
			"",
		].join("\n"));
		const untrackedFinding = { ...validFinding, path: "space file.ts", startLine: 1, endLine: 1 };
		expect(parseSelfReviewOutput(JSON.stringify({ findings: [untrackedFinding] }), untrackedAnchors))
			.toEqual({ findings: [untrackedFinding] });
	});

	test("gives binary and no-hunk paths no changed-line anchors", () => {
		const binaryAnchors = buildSelfReviewChangedLineAnchors([
			"diff --git a/image.png b/image.png",
			"index 1111111..2222222 100644",
			"GIT binary patch",
			"literal 0",
			"",
		].join("\n"));
		const binaryFinding = { ...validFinding, path: "image.png", startLine: 1, endLine: 1 };
		expect(() => parseSelfReviewOutput(JSON.stringify({ findings: [binaryFinding] }), binaryAnchors))
			.toThrow("entirely on changed lines");
	});
});
