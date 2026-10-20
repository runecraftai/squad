import { spawnSync } from "node:child_process";
import { realpathSync, statSync } from "node:fs";
import { digestCanonical } from "./core.ts";

/**
 * Read-only Git adapter. Every invocation is an argv array passed to git without a shell,
 * uses only object/ref reads (`rev-parse`, `merge-base`, `ls-tree`, `cat-file`, `diff`), and
 * disables external diff helpers, text conversion, pagers, prompts and optional index locks.
 * Nothing in this module writes commits, refs, the index, the working tree or the object store.
 */

export class GitReadError extends Error {}

export interface GitTreeEntry { mode: string; type: string; sha: string; path: string }
export interface FileObjectSide { mode: string; blob: string; size: number; reviewable: boolean; reason?: string; contentDigest?: string }
export interface PacketFileEntry {
	path: string;
	status: "added" | "modified" | "deleted";
	base: FileObjectSide | null;
	head: FileObjectSide | null;
}

/** A reviewable object stops here; larger content stays listed as unreviewable instead of being silently truncated. */
export const MAX_REVIEWABLE_BYTES = 512 * 1024;
/** Bounds how many changed paths one packet may carry; unchanged tree entries are filtered before this check. */
export const MAX_MANIFEST_FILES = 5000;

const GIT_ENV = {
	GIT_CONFIG_NOSYSTEM: "1",
	GIT_TERMINAL_PROMPT: "0",
	GIT_OPTIONAL_LOCKS: "0",
	GIT_PAGER: "cat",
	GIT_EXTERNAL_DIFF: "",
	GIT_ASKPASS: "true",
	LC_ALL: "C",
};

function runGit(repo: string, args: string[], maxBuffer = 32 * 1024 * 1024): Buffer {
	const result = spawnSync("git", ["--no-pager", "-c", "core.pager=cat", "-c", "core.quotePath=false", ...args], {
		cwd: repo,
		env: { ...process.env, ...GIT_ENV },
		encoding: "buffer",
		timeout: 30_000,
		maxBuffer,
		shell: false,
	});
	if (result.error) throw new GitReadError(`git ${args[0]} failed: ${result.error.message}`);
	if (result.status !== 0) {
		const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8").trim() : String(result.stderr ?? "").trim();
		throw new GitReadError(`git ${args[0]} failed: ${stderr || `exit ${result.status}`}`);
	}
	return Buffer.isBuffer(result.stdout) ? result.stdout : Buffer.from(result.stdout ?? "");
}

export function assertRepoPath(repo: string): string {
	let resolved: string;
	try { resolved = realpathSync(repo); } catch { throw new GitReadError("repository path does not exist"); }
	if (!statSync(resolved).isDirectory()) throw new GitReadError("repository path is not a directory");
	const gitDir = runGit(resolved, ["rev-parse", "--git-dir"]).toString("utf8").trim();
	if (!gitDir) throw new GitReadError("path is not a Git repository");
	return resolved;
}

/** Resolves an explicit ref to a complete commit id; abbreviated or ambiguous ids never pass. */
export function revParseCommit(repo: string, ref: string): string {
	if (!ref || ref.startsWith("-")) throw new GitReadError("invalid ref");
	// An abbreviated object id is ambiguous by construction; evidence and anchors always name full ids.
	if (/^[0-9a-f]{4,39}$/i.test(ref) && /^[0-9a-f]+$/i.test(ref)) throw new GitReadError("abbreviated object ids are not accepted");
	const value = runGit(repo, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]).toString("utf8").trim();
	if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value)) throw new GitReadError(`ref ${ref} does not resolve to a complete commit id`);
	return value;
}

export function revParseTree(repo: string, commit: string): string {
	assertCommitId(commit);
	const value = runGit(repo, ["rev-parse", "--verify", "--quiet", `${commit}^{tree}`]).toString("utf8").trim();
	if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value)) throw new GitReadError("commit does not resolve to a tree");
	return value;
}

export function mergeBase(repo: string, targetRef: string, headSha: string): string {
	if (!targetRef || targetRef.startsWith("-")) throw new GitReadError("invalid target ref");
	assertCommitId(headSha);
	const value = runGit(repo, ["merge-base", targetRef, headSha]).toString("utf8").trim();
	if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value)) throw new GitReadError("no merge base for the requested refs");
	return value;
}

export function isAncestor(repo: string, ancestor: string, descendant: string): boolean {
	assertCommitId(ancestor); assertCommitId(descendant);
	const result = spawnSync("git", ["--no-pager", "merge-base", "--is-ancestor", ancestor, descendant], { cwd: repo, env: { ...process.env, ...GIT_ENV }, shell: false });
	return result.status === 0;
}

export function assertCommitId(value: string): void {
	if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value)) throw new GitReadError("expected a complete commit id");
}

/** Full recursive tree listing at one commit, parsed from NUL-delimited `ls-tree -r -z` so paths with spaces or Unicode survive intact. */
export function listTree(repo: string, commit: string): GitTreeEntry[] {
	assertCommitId(commit);
	const raw = runGit(repo, ["ls-tree", "-r", "-z", "--full-tree", commit]).toString("utf8");
	const entries: GitTreeEntry[] = [];
	for (const record of raw.split("\0")) {
		if (!record) continue;
		const tab = record.indexOf("\t");
		if (tab < 0) throw new GitReadError("unexpected ls-tree record");
		const [mode, type, sha] = record.slice(0, tab).split(" ");
		if (!mode || !type || !sha) throw new GitReadError("unexpected ls-tree record");
		entries.push({ mode, type, sha, path: record.slice(tab + 1) });
	}
	return entries;
}

export function blobSize(repo: string, blob: string): number {
	const value = Number(runGit(repo, ["cat-file", "-s", blob]).toString("utf8").trim());
	if (!Number.isInteger(value) || value < 0) throw new GitReadError("object size is unavailable");
	return value;
}

export function readBlob(repo: string, blob: string): Buffer {
	if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(blob)) throw new GitReadError("invalid object id");
	return runGit(repo, ["cat-file", "blob", blob]);
}

/** The full patch between two commits. `--no-renames` keeps a rename visible as a deletion plus an addition. */
export function diffPatch(repo: string, baseSha: string, headSha: string): Buffer {
	assertCommitId(baseSha); assertCommitId(headSha);
	return runGit(repo, ["diff", "--no-ext-diff", "--no-textconv", "--full-index", "--no-renames", "--binary", baseSha, headSha, "--"]);
}

export function repoFingerprint(repo: string): { repoId: string; fingerprint: string; remoteRedacted: string | null; rootCommit: string | null } {
	let remote: string | null = null;
	try { remote = runGit(repo, ["config", "--get", "remote.origin.url"]).toString("utf8").trim() || null; } catch { remote = null; }
	const remoteRedacted = remote ? redactUrl(remote) : null;
	let rootCommit: string | null = null;
	try { rootCommit = runGit(repo, ["rev-list", "--max-parents=0", "HEAD"]).toString("utf8").trim().split("\n")[0] || null; } catch { rootCommit = null; }
	const fingerprint = digestCanonical({ remote: remoteRedacted, rootCommit });
	return { repoId: fingerprint.slice(0, 24), fingerprint, remoteRedacted, rootCommit };
}

export function redactUrl(value: string): string {
	return value.replace(/\/\/[^/@]+@/, "//");
}

function classify(repo: string, entry: GitTreeEntry): { side: FileObjectSide; content?: Buffer } {
	if (entry.type === "commit" || entry.mode === "160000") return { side: { mode: entry.mode, blob: entry.sha, size: 0, reviewable: false, reason: "submodule" } };
	if (entry.mode === "120000" || entry.type !== "blob") return { side: { mode: entry.mode, blob: entry.sha, size: 0, reviewable: false, reason: entry.type === "tree" ? "directory" : "symlink" } };
	const size = blobSize(repo, entry.sha);
	if (size > MAX_REVIEWABLE_BYTES) return { side: { mode: entry.mode, blob: entry.sha, size, reviewable: false, reason: "too-large" } };
	const bytes = readBlob(repo, entry.sha);
	if (bytes.includes(0)) return { side: { mode: entry.mode, blob: entry.sha, size, reviewable: false, reason: "binary" } };
	let text: string;
	try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { return { side: { mode: entry.mode, blob: entry.sha, size, reviewable: false, reason: "not-utf8" } }; }
	// Exact bytes remain the source of truth; this only reports whether the object is text for human review.
	void text;
	return { side: { mode: entry.mode, blob: entry.sha, size, reviewable: true }, content: bytes };
}

export type ContentSink = (content: Buffer) => string;

function manifestSide(repo: string, entry: GitTreeEntry, storeContent: ContentSink): FileObjectSide {
	const { side, content } = classify(repo, entry);
	if (content) side.contentDigest = storeContent(content);
	else if (side.reviewable) throw new GitReadError(`reviewable object ${side.blob} produced no content`);
	return side;
}

/** Complete manifest of every path changed between base and head, with both object identities. */
export function buildManifest(repo: string, baseSha: string, headSha: string, storeContent: ContentSink): PacketFileEntry[] {
	const baseEntries = new Map(listTree(repo, baseSha).map((entry) => [entry.path, entry]));
	const headEntries = new Map(listTree(repo, headSha).map((entry) => [entry.path, entry]));
	const paths = [...new Set([...baseEntries.keys(), ...headEntries.keys()])].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
	const files: PacketFileEntry[] = [];
	for (const path of paths) {
		const base = baseEntries.get(path);
		const head = headEntries.get(path);
		if (base && head && base.sha === head.sha && base.mode === head.mode) continue;
		if (files.length >= MAX_MANIFEST_FILES) throw new GitReadError(`manifest exceeds ${MAX_MANIFEST_FILES} changed paths`);
		const status = !base ? "added" : !head ? "deleted" : "modified";
		files.push({
			path,
			status,
			base: base ? manifestSide(repo, base, storeContent) : null,
			head: head ? manifestSide(repo, head, storeContent) : null,
		});
	}
	return files;
}

/** Verifies that a comment anchor still names the exact object and an in-range line interval on that side. */
export function verifyAnchor(repo: string, file: PacketFileEntry, side: "base" | "head", startLine: number, endLine: number, blobSha: string): { ok: boolean; reason?: string; lineCount: number } {
	const object = file[side];
	if (!object) return { ok: false, reason: "side-missing", lineCount: 0 };
	if (object.blob !== blobSha) return { ok: false, reason: "blob-mismatch", lineCount: 0 };
	if (!object.reviewable) return { ok: false, reason: object.reason ?? "unreviewable", lineCount: 0 };
	const text = readBlob(repo, object.blob).toString("utf8");
	const lineCount = text === "" ? 0 : text.split("\n").length;
	if (startLine < 1 || endLine < startLine || endLine > lineCount) return { ok: false, reason: "line-out-of-range", lineCount };
	return { ok: true, lineCount };
}

export function readTextAt(repo: string, blob: string): string {
	return readBlob(repo, blob).toString("utf8");
}

export function countLines(text: string): number {
	return text === "" ? 0 : text.split("\n").length;
}
