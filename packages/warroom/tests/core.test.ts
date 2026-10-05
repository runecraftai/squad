import { Database } from "bun:sqlite";
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

describe("Warroom canonical core", () => {
	test("migration can be applied repeatedly", () => {
		const db = new Database(":memory:");
		migrate(db);
		migrate(db);
		expect(db.query("SELECT version FROM schema_migrations").all()).toEqual([{ version: 1 }]);
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

	test("acceptance is bound to exact revision digest and matching validation", () => {
		const w = seeded();
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved" })).toThrow("requires validation");
		w.command({ type: "approval.record", id: "a1", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c1", decision: "approved", evidenceId: "v1" });
		expect(w.state("i1").approvals[0].subjectDigest).toBe(digestContent("code one"));
		w.command({ type: "revision.create", id: "c2", initiativeId: "i1", kind: "code", content: "code two" });
		expect(() => w.command({ type: "approval.record", initiativeId: "i1", kind: "code-review-acceptance", revisionId: "c2", decision: "approved", evidenceId: "v1" })).toThrow("does not cover");
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
});
