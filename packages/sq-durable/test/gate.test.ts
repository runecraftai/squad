import { describe, expect, it } from "vitest";
import type { ApprovalDocument } from "../src/core/approval.js";
import { defineGate } from "../src/core/gate.js";
import type { MissionDocument } from "../src/core/mission.js";
import { absentApproval, absentMission, defineDocuments } from "../src/core/model.js";

const DECISION = { receiptId: "dec-1", seq: 2, recordedAt: 1 };

/** Runs the gate's abort handler over in-memory documents, the way Pi runs it in a fresh invocation after an abort mark. */
async function abortAfterDecision(decision: "approved" | "rejected") {
	const documents = defineDocuments("test");
	const approval: ApprovalDocument = { ...absentApproval(), status: decision, approvalId: "ap-1", missionId: "m-1", decision: { ...DECISION } as never };
	const mission: MissionDocument = {
		...absentMission(),
		status: decision,
		missionId: "m-1",
		approvalId: "ap-1",
		effect: { effectId: "e-1", effectKey: null, state: "waiting", attempts: 0, lastAttemptAt: null, receipt: null, reconcileReason: null } as never,
	};
	const docs = new Map<unknown, unknown>([
		[documents.Approval, approval],
		[documents.Mission, mission],
	]);
	let outcome: unknown;
	const runtime = {
		commit: async (fn: (tx: unknown) => Promise<{ outcome: unknown }>) => {
			outcome = (await fn({ doc: async (def: unknown) => docs.get(def) })).outcome;
		},
	};
	const gate = defineGate("test", {
		documents,
		executor: {} as never,
		pollMs: 10,
		incarnation: "i-1",
		checkpoint: () => {},
	});
	await gate.definition.abort?.({ input: { missionId: "m-1", approvalId: "ap-1" } } as never, runtime as never, {} as never);
	return { approval, mission, outcome };
}

describe("gate abort after a recorded decision and before continuation", () => {
	it("keeps a recorded reject: no effect, mission and approval both rejected, decision receipt preserved", async () => {
		const { approval, mission, outcome } = await abortAfterDecision("rejected");
		expect(approval.status).toBe("rejected");
		expect(approval.decision).toEqual(DECISION);
		expect(approval.continuation).toBeNull();
		expect(mission.status).toBe("rejected");
		expect(mission.effect?.state).toBe("skipped");
		expect(mission.effect?.receipt).toBeNull();
		expect(outcome).toMatchObject({ status: "aborted" });
	});

	it("keeps a recorded approve: the cancel wins with no effect, the decision is never overwritten", async () => {
		const { approval, mission, outcome } = await abortAfterDecision("approved");
		expect(approval.status).toBe("approved");
		expect(approval.decision).toEqual(DECISION);
		expect(approval.continuation).toBeNull();
		expect(mission.status).toBe("cancelled");
		expect(mission.effect?.state).toBe("skipped");
		expect(mission.effect?.receipt).toBeNull();
		expect(outcome).toMatchObject({ status: "aborted" });
	});
});
