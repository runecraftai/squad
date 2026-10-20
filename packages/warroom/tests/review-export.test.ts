import { describe, expect, test } from "bun:test";
import { escapeHtml, renderReviewExport } from "../src/review-export.ts";

const hostile = `<script>alert("x")</script><img src="https://evil.example/x.png" onerror="steal()"><style>body{display:none}</style>`;

function input(overrides: Record<string, unknown> = {}) {
	return {
		initiative: { id: "i1", title: hostile },
		packet: {
			id: "pk-1",
			packet_digest: "a".repeat(64),
			evidence_digest: "b".repeat(64),
			scope_digest: "c".repeat(64),
			manifest_digest: "d".repeat(64),
			patch_digest: "e".repeat(64),
			repo_fingerprint: "f".repeat(64),
			target_ref: "main",
			review_base_sha: "1".repeat(40),
			head_sha: "2".repeat(40),
			plan_revision_id: "plan-1",
			plan_digest: "3".repeat(64),
			status: "ready",
			stale_reason: null,
		},
		plan: { id: "plan-1", digest: "3".repeat(64), content: `# Plan\n\n${hostile}` },
		manifest: {
			version: 1,
			baseSha: "1".repeat(40),
			headSha: "2".repeat(40),
			files: [
				{ path: "src/<script>alert(1)</script>.ts", status: "modified" as const, base: { mode: "100644", blob: "4".repeat(40), size: 10, reviewable: true, contentDigest: "5".repeat(64) }, head: { mode: "100644", blob: "6".repeat(40), size: 10, reviewable: true, contentDigest: "7".repeat(64) } },
				{ path: "docs/binary.bin", status: "added" as const, base: null, head: { mode: "100644", blob: "8".repeat(40), size: 6, reviewable: false, reason: "binary", contentDigest: null } },
			],
		},
		capture: {
			captureVersion: 1,
			capturedAt: "2026-01-01T00:00:00.000Z",
			provenance: "drill",
			source: { kind: "drill-sqlite", database: "state.sqlite" },
			repo: { id: "repo-1", workingPath: "/tmp/repo", upstreamUrl: null, defaultBranch: "main" },
			run: { id: "run-1", repoId: "repo-1", branch: "review", headSha: "2".repeat(40), baseSha: "1".repeat(40), submittedHeadSha: "2".repeat(40), reviewApprovedHeadSha: "1".repeat(40), deliveredHeadSha: "2".repeat(40), status: "running", drillVersion: "1.4.2", drillBuildSha: null, prUrl: "https://example.test/pr/1", prState: "open", ciReadyAt: 1, ciReadyNoCi: false, lastPushedSha: "2".repeat(40), awaitingAgentSince: null, createdAt: 1, updatedAt: 1 },
			steps: [{ name: hostile, order: 1, status: "completed", exitCode: 0, skipped: false, startedAt: 1, completedAt: 1, logRecorded: true }],
			rounds: [],
			coverage: { ci: "ready" as const, reviewHead: "recorded" as const, stepsSkipped: [] },
			eligibility: { eligible: true, reasons: [] },
			logs: [],
		},
		comments: [{
			id: "cm-1",
			target_type: "code-range",
			path: "src/<script>alert(1)</script>.ts",
			side: "head",
			start_line: 1,
			end_line: 1,
			body: hostile,
			state: "open",
			comment_kind: "suggestion",
			suggestion: hostile,
			created_by: hostile,
			created_at: "2026-01-01T00:00:00.000Z",
		}],
		approvals: [{
			id: "ap-1",
			kind: "code-review-acceptance",
			decision: "changes-requested",
			actor: hostile,
			created_at: "2026-01-01T00:00:00.000Z",
			declaration: hostile,
			packet_digest: "a".repeat(64),
			scope_json: "c".repeat(64),
			superseded_at: null,
		}],
		timeline: [{ sequence: 1, type: "comment.add", summary: hostile, actor: hostile, occurredAt: "2026-01-01T00:00:00.000Z" }],
		exportedAt: "2026-01-01T00:00:00.000Z",
		contents: {
			"src/<script>alert(1)</script>.ts": { base: `const x = 1; ${hostile}`, head: `const x = 2; ${hostile}` },
		},
		...overrides,
	};
}

describe("static review export", () => {
	test("escapes repository, plan, comment, evidence and log content instead of rendering it", () => {
		const html = renderReviewExport(input() as any);
		expect(html).not.toContain("<script>alert");
		expect(html).not.toContain("<img src=");
		expect(html).not.toMatch(/<[^>]*\son[a-z]+=/i);
		expect(html).not.toContain("<style>body{display:none}");
		expect(html).toContain("&lt;script&gt;alert");
		expect(html).toContain("&lt;img src=&quot;https://evil.example/x.png&quot;");
		expect(escapeHtml(hostile)).not.toContain("<");
	});

	test("loads no remote resource and carries no approval or merge control", () => {
		const html = renderReviewExport(input() as any);
		const tagRefs = [...html.matchAll(/<(?:script|link|img|iframe|object|embed|source|video|audio)\b[^>]*>/gi)].map((match) => match[0]);
		expect(tagRefs).toEqual([]);
		// A URL may appear only as already-escaped text, never as a tag attribute a browser would load.
		expect(html).not.toMatch(/<[^>]*(?:src|href)\s*=\s*["']?https?:/i);
		expect(html.toLowerCase()).not.toContain("<button");
		expect(html.toLowerCase()).not.toContain("<form");
		expect(html).toContain("records no acceptance and authorizes no merge");
		expect(html).not.toContain("merge-permission");
	});

	test("includes the exact revision identities, digests, evidence coverage and the file diff", () => {
		const html = renderReviewExport(input() as any);
		expect(html).toContain("packet pk-1");
		expect(html).toContain("a".repeat(64));
		expect(html).toContain("1".repeat(40));
		expect(html).toContain("2".repeat(40));
		expect(html).toContain("run run-1");
		expect(html).toContain("CI readiness recorded");
		expect(html).toContain("docs/binary.bin");
		expect(html).toContain("binary");
		expect(html).toContain("const x = 1;");
		expect(html).toContain("const x = 2;");
		expect(html).toContain("diff-added");
		expect(html).toContain("diff-removed");
	});

	test("marks an unreviewable side explicitly instead of rendering it as empty", () => {
		const html = renderReviewExport(input({ contents: { "src/<script>alert(1)</script>.ts": { headUnreviewable: true, headReason: "binary" } } }) as any);
		expect(html).toContain("The head side is not reviewable as text (binary)");
		expect(html).toContain("its bytes are not inferred");
	});

	test("marks missing stored text explicitly instead of inferring bytes", () => {
		const html = renderReviewExport(input({ contents: {} }) as any);
		expect(html).toContain("Stored text is unavailable; no bytes are inferred.");
	});

	test("refuses an inline diff that exceeds the bounded work budget instead of stalling the export", () => {
		const large = Array.from({ length: 4000 }, (_, index) => `line-${index}`).join("\n");
		const html = renderReviewExport(input({ contents: { "src/<script>alert(1)</script>.ts": { base: large, head: `${large}\nmore` } } }) as any);
		expect(html).toContain("too large for an inline line diff");
		expect(html).not.toContain('class="diff"');
	});
});
