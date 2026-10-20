import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, setDefaultTimeout, test } from "bun:test";

setDefaultTimeout(30_000);
import {
	assertRepoPath,
	blobSize,
	buildManifest,
	countLines,
	diffPatch,
	GitReadError,
	isAncestor,
	listTree,
	MAX_REVIEWABLE_BYTES,
	mergeBase,
	readBlob,
	readTextAt,
	repoFingerprint,
	revParseCommit,
	revParseTree,
	verifyAnchor,
} from "../src/git-read.ts";
import { createReviewFixture, disposeFixture, type ReviewFixture } from "./fixtures/review-fixtures.ts";

let fixture: ReviewFixture;

beforeEach(() => { fixture = createReviewFixture(); });
afterEach(() => { disposeFixture(fixture); });

const sink = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

function state(repo: string): string {
	const status = spawnSync("git", ["--no-pager", "status", "--porcelain=v1", "-uno"], { cwd: repo, encoding: "utf8" }).stdout.trim();
	const head = spawnSync("git", ["--no-pager", "rev-parse", "HEAD"], { cwd: repo, encoding: "utf8" }).stdout.trim();
	const refs = spawnSync("git", ["--no-pager", "for-each-ref", "--format=%(refname) %(objectname)"], { cwd: repo, encoding: "utf8" }).stdout.trim();
	return [status, head, refs].join("\n");
}

function indexDigest(repo: string): string {
	return createHash("sha256").update(readFileSync(join(repo, ".git", "index"))).digest("hex");
}

describe("read-only Git adapter", () => {
	test("resolves explicit refs to complete object ids and refuses abbreviated or injected refs", () => {
		expect(revParseCommit(fixture.repo, "h1")).toBe(fixture.h1);
		expect(revParseCommit(fixture.repo, "h2")).toBe(fixture.h2);
		expect(revParseTree(fixture.repo, fixture.h1)).toMatch(/^[0-9a-f]{40}$/);
		expect(mergeBase(fixture.repo, "main", fixture.h2)).toBe(fixture.baseSha);
		expect(isAncestor(fixture.repo, fixture.h1, fixture.h2)).toBe(true);
		expect(isAncestor(fixture.repo, fixture.h2, fixture.h1)).toBe(false);
		expect(() => revParseCommit(fixture.repo, fixture.h1.slice(0, 7))).toThrow(GitReadError);
		expect(() => revParseCommit(fixture.repo, "--all")).toThrow(GitReadError);
		expect(() => mergeBase(fixture.repo, "--help", fixture.h1)).toThrow(GitReadError);
		expect(() => assertRepoPath(join(fixture.root, "missing"))).toThrow(GitReadError);
	});

	test("builds the complete manifest: spaces, unicode, deletion/addition rename, tests, docs and config", () => {
		const files = buildManifest(fixture.repo, fixture.baseSha, fixture.h1, sink);
		const byPath = new Map(files.map((file) => [file.path, file]));

		expect(byPath.get("src/hello.ts")?.status).toBe("modified");
		expect(byPath.get("docs/guide.md")?.status).toBe("added");
		expect(byPath.get("tests/hello.test.ts")?.status).toBe("added");
		expect(byPath.get("config/settings.json")?.status).toBe("added");
		// A rename is never collapsed: the old path is a deletion and the new path an addition.
		expect(byPath.get("legacy/old-name.ts")?.status).toBe("deleted");
		expect(byPath.get("legacy/old-name.ts")?.head).toBeNull();
		expect(byPath.get("legacy/new-name.ts")?.status).toBe("added");
		expect(byPath.get("legacy/new-name.ts")?.base).toBeNull();
		// Paths with spaces and Unicode stay byte-exact.
		const spaced = byPath.get("docs/path with spaces e acentuação.txt");
		expect(spaced).toBeDefined();
		expect(spaced?.status).toBe("added");
		expect(readTextAt(fixture.repo, spaced!.head!.blob)).toBe("line one\nline two\nline three\n");
		// An empty text file is reviewable; a binary and a symlink are listed but not reviewable.
		const empty = byPath.get("docs/empty.txt");
		expect(empty?.head?.reviewable).toBe(true);
		expect(empty?.head?.size).toBe(0);
		expect(empty?.head?.contentDigest).toBe(sink(Buffer.from("")));
		expect(byPath.get("src/hello.ts")?.head?.contentDigest).toBeTruthy();
		expect(byPath.get("docs/binary.bin")?.head?.reviewable).toBe(false);
		expect(byPath.get("docs/binary.bin")?.head?.reason).toBe("binary");
		expect(byPath.get("docs/readme-link")?.head?.reviewable).toBe(false);
		expect(byPath.get("docs/readme-link")?.head?.reason).toBe("symlink");
		// Unchanged files never enter the packet scope.
		expect(byPath.has("README.md")).toBe(false);
	});

	test("exposes exact bytes for each side and the full patch, including both rename paths", () => {
		const files = buildManifest(fixture.repo, fixture.baseSha, fixture.h1, sink);
		const hello = files.find((file) => file.path === "src/hello.ts")!;
		expect(readTextAt(fixture.repo, hello.base!.blob)).toContain("hello ${name}");
		expect(readTextAt(fixture.repo, hello.head!.blob)).toContain("hello, ${name}!");
		expect(blobSize(fixture.repo, hello.head!.blob)).toBe(Buffer.byteLength(readTextAt(fixture.repo, hello.head!.blob), "utf8"));
		expect(countLines(readTextAt(fixture.repo, hello.head!.blob))).toBe(4);

		const patch = diffPatch(fixture.repo, fixture.baseSha, fixture.h1).toString("utf8");
		expect(patch).toContain("deleted file mode");
		expect(patch).toContain("new file mode");
		expect(patch).toContain("legacy/old-name.ts");
		expect(patch).toContain("legacy/new-name.ts");
		expect(patch).toContain("docs/path with spaces e acentuação.txt");
		expect(patch).toContain("GIT binary patch");
	});

	test("lists every tree entry and never mutates HEAD, refs, index, status or working tree", () => {
		const before = state(fixture.repo);
		const indexBefore = indexDigest(fixture.repo);

		const entries = listTree(fixture.repo, fixture.h1);
		expect(entries.some((entry) => entry.path === "docs/path with spaces e acentuação.txt")).toBe(true);
		buildManifest(fixture.repo, fixture.baseSha, fixture.h2, sink);
		diffPatch(fixture.repo, fixture.baseSha, fixture.h2);
		repoFingerprint(fixture.repo);
		readBlob(fixture.repo, entries[0].sha);

		expect(indexDigest(fixture.repo)).toBe(indexBefore);
		expect(state(fixture.repo)).toBe(before);
	});

	test("identifies a repository by content lineage and re-reads the same fingerprint stably", () => {
		const first = repoFingerprint(fixture.repo);
		const copy = join(fixture.root, "copy");
		const cloned = spawnSync("git", ["clone", "-q", "--no-local", fixture.repo, copy], { encoding: "utf8" });
		expect(cloned.status).toBe(0);
		const second = repoFingerprint(copy);
		expect(second.rootCommit).toBe(first.rootCommit);
		expect(repoFingerprint(fixture.repo).fingerprint).toBe(first.fingerprint);
	});

	test("verifies anchors against the exact object and line range", () => {
		const files = buildManifest(fixture.repo, fixture.baseSha, fixture.h1, sink);
		const hello = files.find((file) => file.path === "src/hello.ts")!;
		expect(verifyAnchor(fixture.repo, hello, "head", 1, 3, hello.head!.blob)).toEqual({ ok: true, lineCount: 4 });
		expect(verifyAnchor(fixture.repo, hello, "head", 1, 9, hello.head!.blob).ok).toBe(false);
		expect(verifyAnchor(fixture.repo, hello, "base", 1, 3, hello.head!.blob).ok).toBe(false);
	});

	test("marks oversized content unreviewable instead of truncating it", () => {
		const repo = join(fixture.root, "large");
		spawnSync("git", ["init", "-q", "-b", "main", repo]);
		spawnSync("git", ["-c", "user.name=F", "-c", "user.email=f@example.test", "-C", repo, "commit", "-q", "--allow-empty", "-m", "base"]);
		const base = spawnSync("git", ["-C", repo, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim();
		writeFileSync(join(repo, "big.txt"), "x".repeat(MAX_REVIEWABLE_BYTES + 1));
		spawnSync("git", ["-C", repo, "add", "-A"]);
		spawnSync("git", ["-c", "user.name=F", "-c", "user.email=f@example.test", "-C", repo, "commit", "-q", "-m", "big"]);
		const head = spawnSync("git", ["-C", repo, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim();
		const files = buildManifest(repo, base, head, sink);
		expect(files).toHaveLength(1);
		expect(files[0].head?.reviewable).toBe(false);
		expect(files[0].head?.reason).toBe("too-large");
		rmSync(repo, { recursive: true, force: true });
	});
});
