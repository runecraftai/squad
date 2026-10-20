import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { digestContent, Warroom } from "../src/core.ts";
import { migrate } from "../src/schema.ts";

function seeded() {
	const warroom = new Warroom();
	warroom.command({ type: "initiative.create", id: "i1", title: "Proof" });
	warroom.command({ type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "plan one" });
	warroom.command({ type: "revision.create", id: "c1", initiativeId: "i1", kind: "code", content: "code one" });
	warroom.command({ type: "validation.record", id: "v1", initiativeId: "i1", revisionId: "c1", provider: "local", result: "passed" });
	return warroom;
}

function supersession(w: Warroom, approvalId: string) {
	const derived = w.state("i1").approvals.find((a) => a.id === approvalId)?.superseded;
	const persisted = w.db.query("SELECT superseded_at, superseded_by FROM approvals WHERE id=?").get(approvalId) as { superseded_at: string | null; superseded_by: string | null };
	return { derived, persisted };
}

describe("Warroom canonical core", () => {
	test("migration can be applied repeatedly", () => {
		const db = new Database(":memory:");
		migrate(db);
		migrate(db);
		expect(db.query("SELECT version FROM schema_migrations").all()).toEqual([{ version: 1 }, { version: 2 }, { version: 3 }]);
		db.close();
	});

	test("commands append events and projections can be replayed", () => {
		const w = seeded();
		const before = w.events().length;
		w.command({ type: "decision.record", id: "d1", initiativeId: "i1", revisionId: "p1", statement: "Choose", rationale: "Reason" });
		expect(w.events()).toHaveLength(before + 1);
		expect(w.state("i1").decisions[0].sourceRevisionId).toBe("p1");
		expect(w.events().map((e) => e.sequence)).toEqual([1, 2, 3, 4, 5]);
		w.close();
	});

	test("event log rejects update and delete", () => {
		const w = seeded();
		expect(() => w.db.query("UPDATE events SET type='changed' WHERE sequence=1").run()).toThrow("append-only");
		expect(() => w.db.query("DELETE FROM events WHERE sequence=1").run()).toThrow("append-only");
		w.close();
	});

	test("approval scopes do not imply each other", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "a1", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		let state = w.state("i1");
		for (const scope of ["execution-authorization", "code-review-acceptance", "merge-permission"]) expect(state.approvals.some((a) => a.kind === scope)).toBe(false);
		w.command({ type: "approval.record", id: "a2", initiativeId: "i1", kind: "execution-authorization", revisionId: "p1", decision: "approved" });
		state = w.state("i1");
		expect(state.approvals.some((a) => a.kind === "plan-approval")).toBe(true);
		expect(state.approvals.some((a) => a.kind === "merge-permission")).toBe(false);
		w.command({ type: "approval.record", id: "a3", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved", evidenceId: "v1" });
		state = w.state("i1");
		expect(state.approvals.map((a) => a.kind)).toEqual(["plan-approval", "execution-authorization", "code-review-acceptance"]);
		expect(state.approvals.some((a) => a.kind === "merge-permission")).toBe(false);
		w.close();
	});

	test("rejected and changes-requested reviews do not require passing evidence", () => {
		const w = new Warroom();
		w.command({ type: "initiative.create", id: "i1", title: "Proof" });
		w.command({ type: "revision.create", id: "c1", initiativeId: "i1", kind: "code", content: "unvalidated code" });
		w.command({ type: "validation.record", id: "vf", initiativeId: "i1", revisionId: "c1", provider: "local", result: "failed" });
		w.command({ type: "approval.record", id: "reject", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "rejected", evidenceId: "vf" });
		w.command({ type: "approval.record", id: "changes", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "changes-requested" });
		expect(w.state("i1").approvals.map((approval) => approval.decision)).toEqual(["rejected", "changes-requested"]);
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved", evidenceId: "vf" })).toThrow("does not cover this revision");
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved" })).toThrow("requires validation evidence");
		w.close();
	});

	test("acceptance is bound to exact revision digest and matching validation", () => {
		const w = seeded();
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved" })).toThrow("requires validation");
		w.command({ type: "approval.record", id: "a1", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved", evidenceId: "v1" });
		expect(w.state("i1").approvals[0].subjectDigest).toBe(digestContent("code one"));
		w.command({ type: "revision.create", id: "c2", initiativeId: "i1", kind: "code", content: "code two" });
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c2", decision: "approved", evidenceId: "v1" })).toThrow("does not cover");
		w.close();
	});

	test("non-review approvals reject evidence that does not exist", () => {
		const w = seeded();
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "merge-permission", revisionId: "c1", decision: "approved", evidenceId: "missing" })).toThrow("does not exist");
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved", evidenceId: "missing" })).toThrow("does not exist");
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "merge-permission", revisionId: "c1", decision: "approved", evidenceId: "" })).toThrow("does not exist");
		expect(w.state("i1").approvals).toHaveLength(0);
		w.command({ type: "approval.record", id: "mp", initiativeId: "i1", kind: "merge-permission", revisionId: "c1", decision: "approved", evidenceId: "v1" });
		const persisted = w.db.query("SELECT evidence_revision_id FROM approvals WHERE id='mp'").get() as { evidence_revision_id: string | null };
		expect(persisted.evidence_revision_id).toBe("v1");
		w.close();
	});

	test("changed revision supersedes acceptance, stales evidence, and retains outdated comments", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "a1", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved", evidenceId: "v1" });
		w.command({ type: "comment.add", id: "m1", initiativeId: "i1", revisionId: "c1", body: "Check this" });
		w.command({ type: "revision.create", id: "c2", initiativeId: "i1", kind: "code", content: "code changed" });
		const state = w.state("i1");
		expect(state.approvals.find((a) => a.id === "a1")?.superseded).toBe(true);
		expect(state.evidence.find((e) => e.id === "v1")?.stale).toBe(true);
		expect(state.comments.find((c) => c.id === "m1")?.state).toBe("outdated");
		expect(state.comments).toHaveLength(1);
		expect(state.revisions.find((r) => r.id === "c1")?.stale).toBe(true);
		const projected = w.db.query("SELECT superseded_at, superseded_by FROM approvals WHERE id='a1'").get() as { superseded_at: string | null; superseded_by: string | null };
		expect(projected.superseded_at).not.toBeNull();
		expect(projected.superseded_by).toBe("c2");
		w.close();
	});

	test("restoring identical content creates a new revision identity without reviving approval", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "pa", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		w.command({ type: "revision.create", id: "p3", initiativeId: "i1", kind: "plan", content: "plan one" });
		const state = w.state("i1");
		expect(state.revisions.find((r) => r.id === "p3")?.id).not.toBe("p1");
		expect(state.revisions.find((r) => r.id === "p3")?.digest).toBe(state.revisions.find((r) => r.id === "p1")?.digest);
		expect(state.revisions.find((r) => r.id === "p1")?.stale).toBe(true);
		expect(state.approvals.find((a) => a.id === "pa")?.superseded).toBe(true);
		const persisted = w.db.query("SELECT superseded_at, superseded_by FROM approvals WHERE id='pa'").get() as { superseded_at: string | null; superseded_by: string | null };
		expect(persisted.superseded_at).not.toBeNull();
		expect(persisted.superseded_by).toBe("p2");
		w.close();
	});

	test("plan-approval is superseded when a newer plan revision is created", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "pa", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		const { derived, persisted } = supersession(w, "pa");
		expect(derived).toBe(true);
		expect(persisted.superseded_at).not.toBeNull();
		expect(persisted.superseded_by).toBe("p2");
		w.close();
	});

	test("a later revision does not overwrite the first recorded supersession replacement", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "pa", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		w.command({ type: "revision.create", id: "p3", initiativeId: "i1", kind: "plan", content: "plan three" });
		const replayed = w.state("i1").approvals.find((approval: any) => approval.id === "pa");
		const projected = w.db.query("SELECT superseded_at, superseded_by FROM approvals WHERE id='pa'").get() as { superseded_at: string | null; superseded_by: string | null };
		expect(replayed.superseded).toBe(true);
		expect(replayed.supersededBy).toBe("p2");
		expect(replayed.supersededBy).toBe(projected.superseded_by);
		expect(replayed.supersededAt).toBe(projected.superseded_at);
		w.close();
	});

	test("execution-authorization is superseded when a newer plan revision is created", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "ea", initiativeId: "i1", kind: "execution-authorization", revisionId: "p1", decision: "approved" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		const { derived, persisted } = supersession(w, "ea");
		expect(derived).toBe(true);
		expect(persisted.superseded_at).not.toBeNull();
		expect(persisted.superseded_by).toBe("p2");
		w.close();
	});

	test("code-review-acceptance is superseded when a newer code revision is created", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "cr", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved", evidenceId: "v1" });
		w.command({ type: "revision.create", id: "c2", initiativeId: "i1", kind: "code", content: "code two" });
		const { derived, persisted } = supersession(w, "cr");
		expect(derived).toBe(true);
		expect(persisted.superseded_at).not.toBeNull();
		expect(persisted.superseded_by).toBe("c2");
		w.close();
	});

	test("merge-permission is superseded when a newer code revision is created", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "mp", initiativeId: "i1", kind: "merge-permission", revisionId: "c1", decision: "approved" });
		w.command({ type: "revision.create", id: "c2", initiativeId: "i1", kind: "code", content: "code two" });
		const { derived, persisted } = supersession(w, "mp");
		expect(derived).toBe(true);
		expect(persisted.superseded_at).not.toBeNull();
		expect(persisted.superseded_by).toBe("c2");
		w.close();
	});

	test("supersession is scoped to the changed revision kind", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "pa", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		w.command({ type: "approval.record", id: "cr", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved", evidenceId: "v1" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		const plan = supersession(w, "pa");
		const code = supersession(w, "cr");
		expect(plan.derived).toBe(true);
		expect(plan.persisted.superseded_by).toBe("p2");
		expect(code.derived).toBe(false);
		expect(code.persisted.superseded_at).toBeNull();
		w.close();
	});

	test("an initiative preserves idea, alternatives, two plan revisions, approval and independent authorization across a restart", () => {
		const root = mkdtempSync(join(tmpdir(), "warroom-restart-"));
		const path = join(root, "warroom.db");
		try {
			const first = new Warroom(path, { id: "commander" });
			first.command({ type: "initiative.create", id: "i1", title: "Review before merge", workingName: "Warroom" });
			first.command({ type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "plan v1: local review" });
			first.command({ type: "decision.record", id: "d1", initiativeId: "i1", revisionId: "p1", statement: "Reuse the private package", rationale: "No new repository for this proof.", selectedAlternatives: ["new repository", "public distribution"] });
			first.command({ type: "approval.record", id: "a1", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
			first.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan v2: executable slice" });
			first.command({ type: "approval.record", id: "a2", initiativeId: "i1", kind: "plan-approval", revisionId: "p2", decision: "approved" });
			first.command({ type: "approval.record", id: "a3", initiativeId: "i1", kind: "execution-authorization", revisionId: "p2", decision: "approved" });
			first.close();

			const reopened = new Warroom(path, { id: "commander" });
			const state = reopened.state("i1");
			expect(state.initiative.title).toBe("Review before merge");
			expect(state.initiative.currentPlanRevisionId).toBe("p2");
			expect(state.revisions.filter((revision: any) => revision.kind === "plan").map((revision: any) => revision.id)).toEqual(["p1", "p2"]);
			expect(state.decisions[0].selectedAlternatives).toEqual(["new repository", "public distribution"]);
			expect(state.approvals.find((approval: any) => approval.id === "a1").superseded).toBe(true);
			expect(state.approvals.find((approval: any) => approval.id === "a2").superseded).toBe(false);
			const supersededProjection = reopened.db.query("SELECT superseded_at, superseded_by FROM approvals WHERE id='a1'").get() as { superseded_at: string | null; superseded_by: string | null };
			const supersededReplay = state.approvals.find((approval: any) => approval.id === "a1");
			expect(supersededReplay.supersededAt).toBe(supersededProjection.superseded_at);
			expect(supersededReplay.supersededBy).toBe(supersededProjection.superseded_by);
			expect(supersededReplay.supersededBy).toBe("p2");
			// Approval of the plan never implies execution authorization, and neither implies merge permission.
			expect(state.approvals.find((approval: any) => approval.id === "a3").kind).toBe("execution-authorization");
			expect(state.approvals.some((approval: any) => approval.kind === "merge-permission")).toBe(false);
			expect(reopened.timeline("i1")).toHaveLength(7);
			reopened.close();
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});

	test("a comment cannot bind to a superseded or missing revision", () => {
		const w = seeded();
		w.command({ type: "revision.create", id: "c2", initiativeId: "i1", kind: "code", content: "code two" });
		expect(() => w.command({ type: "comment.add", initiativeId: "i1", revisionId: "c1", body: "too late" })).toThrow(/missing or stale/);
		expect(() => w.command({ type: "comment.add", initiativeId: "i1", revisionId: "missing", body: "nowhere" })).toThrow(/missing or stale/);
		w.command({ type: "comment.add", id: "ok", initiativeId: "i1", revisionId: "c2", body: "current" });
		expect(w.state("i1").comments).toHaveLength(1);
		w.close();
	});

	test("a free validation response is recorded as legacy and never becomes verified or eligible evidence", () => {
		const w = seeded();
		const evidence = w.state("i1").evidence.find((item: any) => item.id === "v1");
		expect(evidence.provenance).toBe("legacy");
		expect(evidence.eligible).toBe(false);
		w.command({ type: "validation.record", id: "v2", initiativeId: "i1", revisionId: "c1", provider: "drill", result: "passed" });
		const forged = w.db.query("SELECT provenance, eligible, capture_id FROM validation_evidence WHERE id='v2'").get() as any;
		expect(forged.provenance).toBe("legacy");
		expect(forged.eligible).toBe(0);
		expect(forged.capture_id).toBeNull();
		w.close();
	});
});
