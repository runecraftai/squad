import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import { loadReviewContext, shardUnifiedDiff } from "../lib/pr-review-context.ts";

const roots: string[] = [];
afterEach(() => {
	for (const root of roots.splice(0)) fs.rmSync(root, { recursive: true, force: true });
});

function fixture(): string {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "pr-review-context-test-"));
	roots.push(root);
	return root;
}

describe("unified diff sharding", () => {
	test("keeps file blocks whole and covers each block exactly once", () => {
		const diff = [
			"diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-old\n+new",
			"diff --git a/b.ts b/b.ts\n--- a/b.ts\n+++ b/b.ts\n@@ -1 +1,3 @@\n-old\n+one\n+two\n+three",
			"diff --git a/c.ts b/c.ts\n--- a/c.ts\n+++ b/c.ts\n@@ -1 +1 @@\n-old\n+new",
		].join("\n");
		const shards = shardUnifiedDiff(diff, 3);
		expect(shards).toHaveLength(3);
		for (const path of ["a.ts", "b.ts", "c.ts"]) {
			expect(shards.filter((shard) => shard.includes(`a/${path} b/${path}`))).toHaveLength(1);
		}
	});

	test("does not invent empty shards for a single changed file", () => {
		const diff = "diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-old\n+new";
		expect(shardUnifiedDiff(diff, 2)).toEqual([diff]);
	});
});

describe("review context files", () => {
	test("appends a relative complete diff to compact inline metadata", async () => {
		const root = fixture();
		fs.writeFileSync(path.join(root, "pr.diff"), "diff --git a/a.ts b/a.ts\n+added\n");
		const loaded = await loadReviewContext(root, "PR #7 metadata", "pr.diff");
		expect(loaded.context).toContain("PR #7 metadata");
		expect(loaded.context).toContain("--- Complete PR diff from context_file ---");
		expect(loaded.context).toContain("diff --git a/a.ts b/a.ts");
		expect(loaded.contextFile).toBe(path.join(root, "pr.diff"));
		expect(loaded.contextFileText).toContain("diff --git a/a.ts b/a.ts");
		expect(loaded.contextFileBytes).toBeGreaterThan(0);
	});

	test("preserves inline-only compatibility", async () => {
		expect(await loadReviewContext("/tmp", "  inline diff  ", undefined)).toEqual({
			context: "inline diff",
			contextFileBytes: 0,
		});
	});

	test("rejects empty, non-file, and oversized inputs before dispatch", async () => {
		const root = fixture();
		fs.writeFileSync(path.join(root, "empty.diff"), "");
		fs.writeFileSync(path.join(root, "large.diff"), "12345");
		await expect(loadReviewContext(root, undefined, "empty.diff")).rejects.toThrow("is empty");
		await expect(loadReviewContext(root, undefined, ".")).rejects.toThrow("not a regular file");
		await expect(loadReviewContext(root, undefined, "large.diff", 4)).rejects.toThrow("exceeds 4 bytes");
	});
});
