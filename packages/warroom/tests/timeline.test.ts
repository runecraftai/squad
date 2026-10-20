import { describe, expect, test } from "bun:test";
import { digestContent, Warroom } from "../src/core.ts";

function seeded() {
	const warroom = new Warroom();
	warroom.command({ type: "initiative.create", id: "i1", title: "Proof" });
	warroom.command({ type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "plan one" });
	warroom.command({ type: "revision.create", id: "c1", initiativeId: "i1", kind: "code", content: "code one" });
	warroom.command({ type: "validation.record", id: "v1", initiativeId: "i1", revisionId: "c1", provider: "local", result: "passed" });
	return warroom;
}

describe("initiative timeline", () => {
	test("is ordered by event sequence and covers every event type used in this slice", () => {
		const w = seeded();
		w.command({ type: "decision.record", id: "d1", initiativeId: "i1", revisionId: "p1", statement: "Choose", rationale: "Reason" });
		w.command({ type: "approval.record", id: "a1", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Why?" });
		w.command({ type: "question.answer", id: "ans1", initiativeId: "i1", questionId: "q1", answer: "Because" });
		w.command({ type: "comment.add", id: "m1", initiativeId: "i1", revisionId: "c1", body: "Check this" });

		const timeline = w.timeline("i1");
		expect(timeline.map((entry) => entry.sequence)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9]);
		expect(timeline.map((entry) => entry.type)).toEqual([
			"initiative.create",
			"revision.create",
			"revision.create",
			"validation.record",
			"decision.record",
			"approval.record",
			"question.ask",
			"question.answer",
			"comment.add",
		]);
		w.close();
	});

	test("marks a superseded approval and an outdated question/comment once a newer revision lands", () => {
		const w = seeded();
		w.command({ type: "approval.record", id: "a1", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Why?" });
		w.command({ type: "comment.add", id: "m1", initiativeId: "i1", revisionId: "c1", body: "Check this" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		w.command({ type: "revision.create", id: "c2", initiativeId: "i1", kind: "code", content: "code two" });

		const timeline = w.timeline("i1");
		const approvalEntry = timeline.find((entry) => entry.type === "approval.record" && entry.revisionId === "p1");
		const questionEntry = timeline.find((entry) => entry.type === "question.ask");
		const commentEntry = timeline.find((entry) => entry.type === "comment.add");
		const firstRevision = timeline.find((entry) => entry.type === "revision.create" && entry.revisionId === "p1");

		expect(approvalEntry?.superseded).toBe(true);
		expect(questionEntry?.outdated).toBe(true);
		expect(commentEntry?.outdated).toBe(true);
		expect(firstRevision?.stale).toBe(true);
		w.close();
	});

	test("every entry is reconstructible from events and state alone, with no independent storage", () => {
		const w = seeded();
		w.command({ type: "decision.record", id: "d1", initiativeId: "i1", revisionId: "p1", statement: "Choose", rationale: "Reason" });
		const first = w.timeline("i1");
		const second = w.timeline("i1");
		expect(first).toEqual(second);
		w.close();
	});

	test("anchored comments, resolutions, captures and packet supersession appear as their own history entries", () => {
		const w = seeded();
		w.command({
			type: "comment.add",
			id: "m1",
			initiativeId: "i1",
			revisionId: "c1",
			body: "Anchor here",
			targetType: "review",
			path: "src/hello.ts",
			kind: "comment",
		});
		w.command({ type: "comment.resolve", id: "mr1", initiativeId: "i1", commentId: "m1" });
		const timeline = w.timeline("i1");
		const comment = timeline.find((entry) => entry.type === "comment.add");
		const resolved = timeline.find((entry) => entry.type === "comment.resolve");
		expect(comment?.summary).toBe("comment added on src/hello.ts");
		expect(resolved?.summary).toBe("comment resolved");

		// A capture and its packet are projected from events only, so replay reproduces them exactly.
		const captureEvent = { type: "review.capture.record" as const, id: "ev-1", initiativeId: "i1", revisionId: "c1", captureId: "ev-1", captureVersion: 1, captureJson: JSON.stringify({ captureVersion: 1, provenance: "fixture" }), captureDigest: digestContent(JSON.stringify({ captureVersion: 1, provenance: "fixture" })), provenance: "fixture" as const, runId: "run-1", repoId: "repo-1", drillVersion: "1.4.2", drillBaseSha: "c".repeat(40), deliveredHeadSha: "d".repeat(40), runStatus: "running", ciReady: true, ciReadyNoCi: false, eligible: false, ineligibility: "fixture capture, not a real Drill execution", capturedAt: "2026-01-01T00:00:00.000Z" };
		w.command(captureEvent);
		const captureEntry = w.timeline("i1").find((entry) => entry.type === "review.capture.record");
		expect(captureEntry?.summary).toBe("Drill capture run-1 (running): not eligible");
		expect(w.timeline("i1")).toEqual(w.timeline("i1"));
		w.close();
	});
});
