import { spawnSync } from "node:child_process";
import { renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test, setDefaultTimeout } from "bun:test";

setDefaultTimeout(30_000);
import { digestContent, scopeDigestOf, Warroom } from "../src/core.ts";
import { migrations } from "../src/schema.ts";
import {
	acceptReview,
	anchorComment,
	ArtifactStore,
	captureReview,
	checkPacket,
	listPacketFiles,
	readPacketFile,
	requestReviewChanges,
	resolveComment,
	supersedePacket,
} from "../src/review.ts";
import { captureFixture, createReviewFixture, disposeFixture, reopenWarroom, type ReviewFixture } from "./fixtures/review-fixtures.ts";

let fixture: ReviewFixture;

beforeEach(() => { fixture = createReviewFixture(); });
afterEach(() => { disposeFixture(fixture); });

function git(args: string[]): string {
	const result = spawnSync("git", ["--no-pager", ...args], { cwd: fixture.repo, encoding: "utf8" });
	if (result.status !== 0) throw new Error(result.stderr);
	return result.stdout.trim();
}

/** Acceptance flows opt out of unreviewable objects: this slice blocks total acceptance when any exist. */
function useAcceptableFixture(): void {
	disposeFixture(fixture);
	fixture = createReviewFixture({ withUnreviewable: false });
}

function packetRow(packetId: string): any {
	return fixture.warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(packetId);
}

function approvalRows(packetId: string): any[] {
	return fixture.warroom.db.query("SELECT * FROM approvals WHERE packet_id=? ORDER BY created_at").all(packetId);
}

describe("review packet capture", () => {
	test("captures repository, complete base/head, full manifest, plan and evidence digests", () => {
		const result = captureFixture(fixture, "h1");
		const packet = packetRow(result.packetId);
		expect(packet).toBeDefined();
		expect(packet.head_sha).toBe(fixture.h1);
		expect(packet.review_base_sha).toBe(fixture.baseSha);
		expect(packet.target_ref).toBe("main");
		expect(packet.head_ref).toBe("h1");
		expect(packet.packet_digest).toBe(result.packetDigest);
		expect(packet.scope_digest).toBe(result.scopeDigest);
		expect(packet.evidence_digest).toBe(result.evidenceDigest);

		const files = listPacketFiles(fixture.warroom, result.packetId);
		expect(files.map((file) => file.path)).toEqual([
			"config/settings.json",
			"docs/binary.bin",
			"docs/empty.txt",
			"docs/guide.md",
			"docs/path with spaces e acentuação.txt",
			"docs/readme-link",
			"legacy/new-name.ts",
			"legacy/old-name.ts",
			"src/hello.ts",
			"tests/hello.test.ts",
		]);
		// The scope digest covers the complete file list, including unreviewable objects.
		expect(scopeDigestOf(files)).toBe(packet.scope_digest);

		// Every immutable artifact is present and verifies at its digest.
		const store = new ArtifactStore(fixture.dataDir);
		expect(store.verify(packet.manifest_digest)).toBe(true);
		expect(store.verify(packet.patch_digest)).toBe(true);
		expect(store.verify(packet.evidence_digest)).toBe(true);

		// File navigation returns the exact bytes of the correct object on each side.
		const hello = readPacketFile(fixture.warroom, fixture.dataDir, result.packetId, "src/hello.ts", "head");
		expect(hello.text).toContain("hello, ${name}!");
		expect(hello.lineCount).toBe(4);
		const baseHello = readPacketFile(fixture.warroom, fixture.dataDir, result.packetId, "src/hello.ts", "base");
		expect(baseHello.text).toContain("hello ${name}");

		const evidence = fixture.warroom.db.query("SELECT * FROM validation_evidence WHERE id=?").get(packet.evidence_id) as any;
		expect(evidence.provenance).toBe("fixture");
		expect(evidence.capture_digest).toBe(result.evidenceDigest);
		expect(evidence.run_status).toBe("running");
		expect(evidence.delivered_head_sha).toBe(fixture.h1);
	});

	test("a plan change on the same head accepts the newly captured packet, not the first packet for that revision", () => {
		useAcceptableFixture();
		const first = captureFixture(fixture, "h1", "drill");
		fixture.warroom.command({ type: "revision.create", id: "plan-2", initiativeId: "i1", kind: "plan", content: "# Plan v2\n\nChanged scope.\n" });
		const second = captureReview(fixture.warroom, fixture.dataDir, {
			repo: fixture.repo,
			drillDb: fixture.drillDb,
			drillLogs: fixture.drillLogs,
			repoId: fixture.repoId,
			runId: fixture.run1,
			targetRef: "main",
			headRef: "h1",
			planRevisionId: "plan-2",
			provenance: "drill",
		});
		expect(second.packetId).not.toBe(first.packetId);
		expect(packetRow(first.packetId).code_revision_id).toBe(packetRow(second.packetId).code_revision_id);
		expect(checkPacket(fixture.warroom, fixture.dataDir, second.packetId).status).toBe("ready");
		const accepted = acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: second.packetId,
			packetDigest: second.packetDigest,
			scopeDigest: second.scopeDigest,
			declaration: "I reviewed the new plan snapshot.",
			actorConfirmed: true,
		});
		expect(accepted.check.packet.id).toBe(second.packetId);
		expect(packetRow(second.packetId).status).toBe("accepted");
	});

	test("the same run and head can be captured under a second initiative", () => {
		captureFixture(fixture, "h1", "fixture");
		fixture.warroom.command({ type: "initiative.create", id: "i2", title: "Second initiative" });
		fixture.warroom.command({ type: "revision.create", id: "plan-i2", initiativeId: "i2", kind: "plan", content: "# Second plan\n" });
		const second = captureReview(fixture.warroom, fixture.dataDir, {
			repo: fixture.repo,
			drillDb: fixture.drillDb,
			drillLogs: fixture.drillLogs,
			repoId: fixture.repoId,
			runId: fixture.run1,
			targetRef: "main",
			headRef: "h1",
			planRevisionId: "plan-i2",
			provenance: "fixture",
		});
		expect(second.reused).toBe(false);
		expect(packetRow(second.packetId).initiative_id).toBe("i2");
		expect(checkPacket(fixture.warroom, fixture.dataDir, second.packetId).status).toBe("ready");
	});

	test("records the human review base and the Drill base separately when they differ", () => {
		const result = captureFixture(fixture, "h2");
		const packet = packetRow(result.packetId);
		const evidence = fixture.warroom.db.query("SELECT * FROM validation_evidence WHERE id=?").get(packet.evidence_id) as any;
		expect(packet.review_base_sha).toBe(fixture.baseSha);
		expect(evidence.drill_base_sha).toBe(fixture.h1);
		expect(packet.review_base_sha).not.toBe(evidence.drill_base_sha);
		const capture = JSON.parse((fixture.warroom.db.query("SELECT capture_json FROM evidence_captures WHERE id=?").get(packet.evidence_id) as any).capture_json);
		expect(capture.run.baseSha).toBe(fixture.h1);
		expect(capture.run.headSha).toBe(fixture.h2);
	});

	test("repeating the same capture is idempotent and never duplicates events", () => {
		const first = captureFixture(fixture, "h1");
		const before = fixture.warroom.events(fixture.initiativeId).length;
		const second = captureFixture(fixture, "h1");
		expect(second.reused).toBe(true);
		expect(second.packetId).toBe(first.packetId);
		expect(fixture.warroom.events(fixture.initiativeId).length).toBe(before);
	});

	test("refuses a free or legacy validation response as packet evidence", () => {
		fixture.warroom.command({ type: "revision.create", id: "legacy-code", initiativeId: "i1", kind: "code", content: "free text pretending to be code" });
		fixture.warroom.command({ type: "validation.record", id: "free-evidence", initiativeId: "i1", revisionId: "legacy-code", provider: "trust-me", result: "passed" });
		const evidence = fixture.warroom.db.query("SELECT * FROM validation_evidence WHERE id='free-evidence'").get() as any;
		expect(evidence.provenance).toBe("legacy");
		expect(evidence.eligible).toBe(0);
		expect(() => fixture.warroom.command({
			type: "review.packet.create",
			initiativeId: "i1",
			revisionId: "legacy-code",
			evidenceId: "free-evidence",
			planRevisionId: "plan-1",
			repoId: "repo-1",
			repoFingerprint: "f".repeat(64),
			targetRef: "main",
			reviewBaseSha: fixture.baseSha,
			headSha: fixture.h1,
			baseTree: fixture.baseSha,
			headTree: fixture.h1,
			manifestDigest: digestContent("free text pretending to be code"),
			patchDigest: "a".repeat(64),
			scopeDigest: "b".repeat(64),
			packetDigest: "c".repeat(64),
		})).toThrow(/valid JSON|captured validation evidence/);
	});

	test("a fixture capture is visible but never eligible for human acceptance", () => {
		const result = captureFixture(fixture, "h1", "fixture");
		const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
		expect(check.status).toBe("ready");
		expect(check.currentness).toBe("verified");
		expect(check.evidenceEligible).toBe(false);
		expect(check.evidenceReasons.join()).toContain("evidence-provenance-not-drill");
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "I reviewed it",
			actorConfirmed: true,
		})).toThrow(/evidence is not eligible/);
		expect(approvalRows(result.packetId)).toHaveLength(0);
	});
});

describe("human acceptance", () => {
	test("records a scoped acceptance with actor, declaration, packet, scope and evidence digests", () => {
		useAcceptableFixture();
		const result = captureFixture(fixture, "h1", "drill");
		const before = fixture.warroom.events(fixture.initiativeId).length;
		const accepted = acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "I reviewed every file at this exact head.",
			actorConfirmed: true,
		});
		expect(accepted.approvalId).toBeTruthy();
		expect(fixture.warroom.events(fixture.initiativeId).length).toBe(before + 1);
		const approvals = approvalRows(result.packetId);
		expect(approvals).toHaveLength(1);
		const approval = approvals[0];
		expect(approval.kind).toBe("code-review-acceptance");
		expect(approval.decision).toBe("approved");
		expect(approval.actor).toBe("operator");
		expect(approval.actor_confirmed).toBe(1);
		expect(approval.packet_digest).toBe(result.packetDigest);
		expect(approval.evidence_digest).toBe(result.evidenceDigest);
		expect(approval.scope_json).toBe(result.scopeDigest);
		expect(approval.declaration).toContain("every file");
		// Acceptance never emits merge permission.
		expect(fixture.warroom.state("i1").approvals.some((item: any) => item.kind === "merge-permission")).toBe(false);
		expect(fixture.warroom.packetRow(result.packetId).status).toBe("accepted");
	});

	test("refuses acceptance with a partial scope, stale snapshot token, missing declaration or unconfirmed authority", () => {
		useAcceptableFixture();
		const result = captureFixture(fixture, "h1", "drill");
		const base = { packetId: result.packetId, packetDigest: result.packetDigest, scopeDigest: result.scopeDigest, declaration: "Reviewed", actorConfirmed: true };
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, { ...base, scopeDigest: "0".repeat(64) })).toThrow(/complete packet scope/);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, { ...base, packetDigest: "0".repeat(64) })).toThrow(/does not match the current snapshot/);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, { ...base, declaration: "   " })).toThrow(/explicit declaration/);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, { ...base, actorConfirmed: false })).toThrow(/explicit human confirmation/);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, base)).not.toThrow();
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, base)).toThrow(/already accepted/);
	});

	test("the core rejects a bypass that skips the packet, evidence and currentness fields", () => {
		const result = captureFixture(fixture, "h1", "drill");
		const packet = packetRow(result.packetId);
		expect(() => fixture.warroom.command({
			type: "approval.record",
			initiativeId: "i1",
			kind: "code-review-acceptance",
			revisionId: packet.code_revision_id,
			decision: "approved",
			evidenceId: packet.evidence_id,
		})).toThrow(/exact review packet/);
		expect(() => fixture.warroom.command({
			type: "approval.record",
			initiativeId: "i1",
			kind: "code-review-acceptance",
			revisionId: packet.code_revision_id,
			decision: "approved",
			evidenceId: packet.evidence_id,
			packetId: packet.id,
			packetDigest: packet.packet_digest,
			evidenceDigest: packet.evidence_digest,
			scopeDigest: packet.scope_digest,
			declaration: "Reviewed",
			actorConfirmed: true,
		})).toThrow(/verified current snapshot/);
		expect(approvalRows(result.packetId)).toHaveLength(0);
	});

	test("comments and change requests never register an acceptance", () => {
		const result = captureFixture(fixture, "h1", "drill");
		const commentId = anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 1,
			endLine: 3,
			blobSha: listPacketFiles(fixture.warroom, result.packetId).find((file) => file.path === "src/hello.ts")!.head!.blob,
			kind: "suggestion",
			suggestion: "return `hello, ${name}!`;",
			body: "Please validate the name first.",
		});
		expect(commentId).toBeTruthy();
		resolveComment(fixture.warroom, commentId);
		const request = requestReviewChanges(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "Fix the validation before merge.",
			actorConfirmed: true,
		});
		expect(request.approvalId).toBeTruthy();
		const approvals = approvalRows(result.packetId);
		expect(approvals).toHaveLength(1);
		expect(approvals[0].decision).toBe("changes-requested");
		expect(approvals.some((approval) => approval.decision === "approved")).toBe(false);
		expect(fixture.warroom.state("i1").approvals.some((item: any) => item.kind === "merge-permission")).toBe(false);
	});

	test("repeated change requests on one packet get distinct approval ids instead of a storage collision", () => {
		const result = captureFixture(fixture, "h1", "drill");
		const base = { packetId: result.packetId, packetDigest: result.packetDigest, scopeDigest: result.scopeDigest, declaration: "Still not right.", actorConfirmed: true };
		const first = requestReviewChanges(fixture.warroom, fixture.dataDir, base);
		const second = requestReviewChanges(fixture.warroom, fixture.dataDir, base);
		expect(first.approvalId).not.toBe(second.approvalId);
		expect((fixture.warroom.db.query("SELECT id FROM approvals WHERE packet_id=? ORDER BY rowid").all(result.packetId) as Array<{ id: string }>).map((approval) => approval.id)).toEqual([first.approvalId, second.approvalId]);
	});

	test("a deleted per-file content artifact is reported as corrupt and blocks acceptance", () => {
		useAcceptableFixture();
		const result = captureFixture(fixture, "h1", "drill");
		const hello = listPacketFiles(fixture.warroom, result.packetId).find((file) => file.path === "src/hello.ts")!;
		const store = new ArtifactStore(fixture.dataDir);
		rmSync(store.absolutePath(hello.head!.contentDigest!));
		const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
		expect(check.status).toBe("corrupt");
		expect(check.reasons.some((reason) => reason.startsWith("content-artifact-missing:src/hello.ts:head"))).toBe(true);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "I reviewed every file.",
			actorConfirmed: true,
		})).toThrow(/not acceptable/);
		expect(approvalRows(result.packetId)).toHaveLength(0);
	});
});

describe("currentness and supersession", () => {
	test("a new head makes the old packet stale, supersedes its acceptance and keeps H1 evidence historical", () => {
		useAcceptableFixture();
		const first = captureFixture(fixture, "h1", "drill");
		acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: first.packetId,
			packetDigest: first.packetDigest,
			scopeDigest: first.scopeDigest,
			declaration: "H1 reviewed",
			actorConfirmed: true,
		});
		const second = captureFixture(fixture, "h2", "drill");
		expect(second.packetDigest).not.toBe(first.packetDigest);

		const h1 = checkPacket(fixture.warroom, fixture.dataDir, first.packetId);
		expect(h1.status).toBe("stale");
		expect(h1.reasons).toContain("revision-superseded");
		const h1Approval = fixture.warroom.state("i1").approvals.find((approval: any) => approval.packetId === first.packetId);
		expect(h1Approval.superseded).toBe(true);
		const h1Evidence = fixture.warroom.db.query("SELECT * FROM validation_evidence WHERE id=?").get(first.evidenceId) as any;
		expect(h1Evidence.provenance).toBe("drill");
		expect(h1Evidence.stale).toBe(0);
		expect(h1Evidence.delivered_head_sha).toBe(fixture.h1);

		// The old acceptance can never be reused for the new head.
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: first.packetId,
			packetDigest: first.packetDigest,
			scopeDigest: first.scopeDigest,
			declaration: "reuse H1",
			actorConfirmed: true,
		})).toThrow(/stale|not acceptable/);

		const h2 = checkPacket(fixture.warroom, fixture.dataDir, second.packetId);
		expect(h2.status).toBe("ready");
		expect(h2.currentness).toBe("verified");
		expect(h2.evidenceEligible).toBe(true);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: second.packetId,
			packetDigest: first.packetDigest,
			scopeDigest: first.scopeDigest,
			declaration: "wrong snapshot",
			actorConfirmed: true,
		})).toThrow(/does not match/);
		const accepted = acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: second.packetId,
			packetDigest: second.packetDigest,
			scopeDigest: second.scopeDigest,
			declaration: "H2 reviewed",
			actorConfirmed: true,
		});
		expect(accepted.check.packet.head_sha).toBe(fixture.h2);
	});

	test("changing the plan invalidates the packet link without falsifying historical evidence", () => {
		const result = captureFixture(fixture, "h1", "drill");
		expect(checkPacket(fixture.warroom, fixture.dataDir, result.packetId).status).toBe("ready");
		fixture.warroom.command({ type: "revision.create", id: "plan-2", initiativeId: "i1", kind: "plan", content: "# Plan v2\n\nChanged scope.\n" });
		const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
		expect(check.status).toBe("stale");
		expect(check.reasons).toContain("plan-changed");
		expect(check.evidenceEligible).toBe(true);
		expect(packetRow(result.packetId).stale_reason).toBe("plan-changed");
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "cannot accept",
			actorConfirmed: true,
		})).toThrow(/not acceptable|stale/);
	});

	test("a moved head ref blocks new acceptance and reports the observed head", () => {
		const result = captureFixture(fixture, "h1", "drill");
		git(["-c", "user.name=F", "-c", "user.email=f@example.test", "tag", "-f", "h1", fixture.h2]);
		const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
		expect(check.status).toBe("stale");
		expect(check.reasons).toContain("head-moved");
		expect((check.observations.source as any).observedHeadSha).toBe(fixture.h2);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "stale",
			actorConfirmed: true,
		})).toThrow(/not acceptable|stale/);
	});

	test("a moved target ref blocks new acceptance as a changed base", () => {
		const result = captureFixture(fixture, "h1", "drill");
		git(["branch", "-f", "main", fixture.h1]);
		const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
		expect(check.status).toBe("stale");
		expect(check.reasons).toContain("base-moved");
		expect((check.observations.source as any).observedBaseSha).toBe(fixture.h1);
	});

	test("a missing local source leaves history readable but currentness unverified and blocks acceptance", () => {
		const result = captureFixture(fixture, "h1", "drill");
		const moved = join(fixture.root, "repo-moved");
		renameSync(fixture.repo, moved);
		try {
			const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
			expect(check.status).toBe("ready");
			expect(check.currentness).toBe("unverified");
			expect(check.reasons).toContain("source-unavailable");
			expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
				packetId: result.packetId,
				packetDigest: result.packetDigest,
				scopeDigest: result.scopeDigest,
				declaration: "offline",
				actorConfirmed: true,
			})).toThrow(/currentness is unverified/);
		} finally {
			renameSync(moved, fixture.repo);
		}
		expect(checkPacket(fixture.warroom, fixture.dataDir, result.packetId).currentness).toBe("verified");
	});

	test("an explicit supersession keeps the old packet readable and blocks its acceptance", () => {
		const result = captureFixture(fixture, "h1", "drill");
		requestReviewChanges(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "Fix before acceptance.",
			actorConfirmed: true,
		});
		supersedePacket(fixture.warroom, result.packetId, "replaced by a newer capture");
		const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
		expect(check.status).toBe("stale");
		expect(check.reasons).toContain("replaced by a newer capture");
		expect(check.packet).toBeDefined();
		const approval = fixture.warroom.state("i1").approvals.find((item: any) => item.packetId === result.packetId);
		expect(approval.superseded).toBe(true);
		expect((fixture.warroom.db.query("SELECT superseded_at FROM approvals WHERE packet_id=?").get(result.packetId) as { superseded_at: string | null }).superseded_at).not.toBeNull();
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "late",
			actorConfirmed: true,
		})).toThrow();
	});
});

describe("anchored comments and replay", () => {
	test("comments on code, plan and a flow node survive restart and keep their snapshot context", () => {
		const result = captureFixture(fixture, "h1", "drill");
		const files = listPacketFiles(fixture.warroom, result.packetId);
		const hello = files.find((file) => file.path === "src/hello.ts")!;
		const codeComment = anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 1,
			endLine: 3,
			blobSha: hello.head!.blob,
			kind: "comment",
			body: "This greeting is the whole change.",
		});
		const suggestion = anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 2,
			endLine: 2,
			blobSha: hello.head!.blob,
			kind: "suggestion",
			suggestion: "\treturn `hello, ${name}!`;",
			body: "Suggested text; it is never applied automatically.",
		});
		const planComment = anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			targetType: "plan-range",
			revisionId: "plan-1",
			kind: "comment",
			body: "The plan criteria are met by the added test.",
		});
		const nodeComment = anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			targetType: "diagram-node",
			context: "node:hello",
			kind: "comment",
			body: "This node links to src/hello.ts.",
		});
		expect(new Set([codeComment, suggestion, planComment, nodeComment]).size).toBe(4);

		// A suggestion is stored text only; the repository object is untouched.
		const headBefore = git(["rev-parse", "h1"]);
		expect(git(["rev-parse", "h1"])).toBe(headBefore);

		fixture.warroom.close();
		fixture.warroom = reopenWarroom(fixture);
		const state = fixture.warroom.state("i1");
		const comments = state.comments.filter((comment: any) => comment.packetId === result.packetId);
		expect(comments).toHaveLength(4);
		const storedSuggestion = comments.find((comment: any) => comment.kind === "suggestion");
		expect(storedSuggestion.suggestion).toContain("hello, ${name}");
		expect(storedSuggestion.snapshotDigest).toBe(result.packetDigest);
		expect(storedSuggestion.blobSha).toBe(hello.head!.blob);
		expect(state.comments.find((comment: any) => comment.id === nodeComment).context).toBe("node:hello");

		resolveComment(fixture.warroom, codeComment);
		expect(fixture.warroom.state("i1").comments.find((comment: any) => comment.id === codeComment).state).toBe("resolved");
		expect(fixture.warroom.state("i1").approvals.filter((item: any) => item.kind === "code-review-acceptance")).toHaveLength(0);
	});

	test("anchors never travel to another snapshot and a stale packet refuses new comments", () => {
		const first = captureFixture(fixture, "h1", "drill");
		const hello = listPacketFiles(fixture.warroom, first.packetId).find((file) => file.path === "src/hello.ts")!;
		anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: first.packetId,
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 1,
			endLine: 2,
			blobSha: hello.head!.blob,
			kind: "comment",
			body: "H1 anchor",
		});
		const second = captureFixture(fixture, "h2", "drill");
		const h2Hello = listPacketFiles(fixture.warroom, second.packetId).find((file) => file.path === "src/hello.ts")!;
		expect(h2Hello.head!.blob).not.toBe(hello.head!.blob);
		// The H1 comment stays attached to its own snapshot, marked outdated, never relocated.
		const h1Comment = fixture.warroom.state("i1").comments.find((comment: any) => comment.packetId === first.packetId);
		expect(h1Comment.state).toBe("outdated");
		expect(h1Comment.anchorStatus).toBe("outdated");
		expect(h1Comment.snapshotDigest).toBe(first.packetDigest);
		// Anchoring the H2 packet to the H1 object is rejected, not silently accepted.
		expect(() => anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: second.packetId,
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 1,
			endLine: 2,
			blobSha: hello.head!.blob,
			kind: "comment",
			body: "carried over",
		})).toThrow(/blob does not match/);
		// A stale packet cannot receive new comments at all.
		expect(() => anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: first.packetId,
			targetType: "review",
			kind: "comment",
			body: "late",
		})).toThrow(/stale/);
		// Line ranges outside the real object are refused.
		expect(() => anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: second.packetId,
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 4,
			endLine: 99,
			blobSha: h2Hello.head!.blob,
			kind: "comment",
			body: "out of range",
		})).toThrow(/out of bounds/);
	});

	test("replay and projection agree after restart, and a partial failure leaves no approval", () => {
		const result = captureFixture(fixture, "h1", "drill");
		const files = listPacketFiles(fixture.warroom, result.packetId);
		anchorComment(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 1,
			endLine: 2,
			blobSha: files.find((file) => file.path === "src/hello.ts")!.head!.blob,
			kind: "comment",
			body: "persisted",
		});
		const timelineBeforeRestart = fixture.warroom.timeline("i1");
		fixture.warroom.close();
		fixture.warroom = reopenWarroom(fixture);
		const replayed = fixture.warroom.state("i1");
		const projected = packetRow(result.packetId);
		const replayedPacket = replayed.packets.find((packet: any) => packet.id === result.packetId);
		for (const key of ["headSha", "reviewBaseSha", "manifestDigest", "scopeDigest", "patchDigest", "packetDigest", "evidenceDigest", "evidenceId", "planRevisionId", "status"]) {
			expect(replayedPacket[key]).toBe(projected[camelToSnake(key)]);
		}
		expect(fixture.warroom.timeline("i1")).toEqual(timelineBeforeRestart);

		const before = fixture.warroom.events("i1").length;
		const digestBefore = packetRow(result.packetId).packet_digest;
		expect(() => fixture.warroom.command({
			type: "review.packet.create",
			id: "bad-packet",
			initiativeId: "i1",
			revisionId: packetRow(result.packetId).code_revision_id,
			evidenceId: result.evidenceId,
			planRevisionId: "plan-1",
			repoId: "repo-1",
			repoFingerprint: packetRow(result.packetId).repo_fingerprint,
			targetRef: "main",
			reviewBaseSha: result.reviewBaseSha,
			headSha: result.headSha,
			baseTree: "1".repeat(40),
			headTree: "2".repeat(40),
			manifestDigest: "3".repeat(64),
			patchDigest: result.patchDigest,
			scopeDigest: result.scopeDigest,
			packetDigest: "4".repeat(64),
		})).toThrow();
		expect(fixture.warroom.events("i1").length).toBe(before);
		expect(packetRow(result.packetId).packet_digest).toBe(digestBefore);
		expect(fixture.warroom.db.query("SELECT 1 FROM review_packets WHERE id='bad-packet'").get()).toBeNull();
	});
});

describe("additive migration", () => {
	test("a version 2 database keeps its old events and rows when version 3 is applied", () => {
		const path = join(fixture.root, "legacy.sqlite");
		const db = new Database(path);
		db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)");
		for (const migration of migrations.filter((item) => item.version <= 2)) {
			db.exec(migration.sql);
			db.query("INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)").run(migration.version, new Date().toISOString());
		}
		db.query("INSERT INTO initiatives(id,title,working_name,phase,created_at,updated_at) VALUES('old','Old initiative','Warroom','discover','2020-01-01T00:00:00.000Z','2020-01-01T00:00:00.000Z')").run();
		db.query("INSERT INTO revisions(id,initiative_id,kind,digest,previous_revision_id,content,created_by,created_at) VALUES('old-plan','old','plan',?,NULL,'legacy plan','someone','2020-01-01T00:00:00.000Z')").run(digestContent("legacy plan"));
		db.query("INSERT INTO approvals(id,initiative_id,kind,subject_revision_id,subject_digest,evidence_revision_id,decision,actor,created_at) VALUES('old-approval','old','plan-approval','old-plan',?,NULL,'approved','someone','2020-01-01T00:00:00.000Z')").run(digestContent("legacy plan"));
		db.query("INSERT INTO comments(id,initiative_id,revision_id,body,state,created_by,created_at) VALUES('old-comment','old','old-plan','legacy comment','open','someone','2020-01-01T00:00:00.000Z')").run();
		db.close();

		const warroom = new Warroom(path, { id: "operator" });
		expect((warroom.db.query("SELECT id FROM revisions ORDER BY id").all() as Array<{ id: string }>).map((row) => row.id)).toEqual(["old-plan"]);
		expect((warroom.db.query("SELECT id FROM approvals").all() as Array<{ id: string }>).map((row) => row.id)).toEqual(["old-approval"]);
		expect((warroom.db.query("SELECT body FROM comments").get() as { body: string }).body).toBe("legacy comment");
		const legacyComment = warroom.db.query("SELECT target_type, anchor_status FROM comments").get() as { target_type: string; anchor_status: string };
		expect(legacyComment.target_type).toBe("review");
		expect(legacyComment.anchor_status).toBe("current");
		const columns = (warroom.db.query("PRAGMA table_info(comments)").all() as Array<{ name: string }>).map((column) => column.name);
		expect(columns).toContain("snapshot_digest");
		const versions = (warroom.db.query("SELECT version FROM schema_migrations ORDER BY version").all() as Array<{ version: number }>).map((row) => row.version);
		expect(versions).toEqual([1, 2, 3]);
		warroom.close();
	});
});

function camelToSnake(value: string): string {
	return value.replace(/[A-Z]/g, (character) => `_${character.toLowerCase()}`);
}

describe("review CLI", () => {
	test("captures a packet and exits non-zero once the source head moves", () => {
		useAcceptableFixture();
		fixture.warroom.close();
		const cli = join(import.meta.dir, "..", "src", "review-cli.ts");
		const cliCwd = join(import.meta.dir, "..");
		const capture = spawnSync("bun", ["run", cli, "capture",
			"--repo", fixture.repo,
			"--drill-db", fixture.drillDb,
			"--drill-logs", fixture.drillLogs,
			"--repo-id", fixture.repoId,
			"--run", fixture.run1,
			"--target-ref", "main",
			"--head-ref", "h1",
			"--plan", "plan-1",
			"--warroom-data", fixture.dataDir,
		], { encoding: "utf8", cwd: cliCwd });
		expect(capture.stderr).toBe("");
		expect(capture.status).toBe(0);
		const result = JSON.parse(capture.stdout);
		expect(result.packetId).toMatch(/^pk-/);
		expect(result.headSha).toBe(fixture.h1);
		expect(result.reused).toBe(false);

		const check = spawnSync("bun", ["run", cli, "check", "--warroom-data", fixture.dataDir, "--packet", result.packetId], { encoding: "utf8", cwd: cliCwd });
		expect(check.status).toBe(0);
		const report = JSON.parse(check.stdout);
		expect(report.status).toBe("ready");
		expect(report.currentness).toBe("verified");
		expect(report.evidenceEligible).toBe(true);

		git(["tag", "-f", "h1", fixture.h2]);
		const stale = spawnSync("bun", ["run", cli, "check", "--warroom-data", fixture.dataDir, "--packet", result.packetId], { encoding: "utf8", cwd: cliCwd });
		expect(stale.status).toBe(1);
		expect(JSON.parse(stale.stdout).reasons).toContain("head-moved");

		const missing = spawnSync("bun", ["run", cli, "check", "--warroom-data", fixture.dataDir, "--packet", "pk-missing"], { encoding: "utf8", cwd: cliCwd });
		expect(missing.status).toBe(1);
		expect(JSON.parse(missing.stdout).status).toBe("unknown");
	});
});

describe("unreviewable objects", () => {
	test("a packet containing a binary or symlink blocks total acceptance and names every path", () => {
		const result = captureFixture(fixture, "h1", "drill");
		const check = checkPacket(fixture.warroom, fixture.dataDir, result.packetId);
		expect(check.status).toBe("ready");
		expect(check.currentness).toBe("verified");
		expect(check.evidenceEligible).toBe(true);
		expect(check.unreviewableFiles).toEqual(["docs/binary.bin", "docs/readme-link"]);
		expect(() => acceptReview(fixture.warroom, fixture.dataDir, {
			packetId: result.packetId,
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "I confirmed the complete scope.",
			actorConfirmed: true,
		})).toThrow(/cannot be reviewed/);
		// The objects stay listed rather than being omitted from the scope.
		expect(listPacketFiles(fixture.warroom, result.packetId).map((file) => file.path)).toContain("docs/binary.bin");
		expect(approvalRows(result.packetId)).toHaveLength(0);
	});
});
