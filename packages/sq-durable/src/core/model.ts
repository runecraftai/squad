import { type CheckpointInfo, defineDoc, defineDocFamily } from "@earendil-works/pi-durable";
import type { ApprovalDocument } from "./approval.js";
import type { MissionDocument } from "./mission.js";

/**
 * Store-wide record: store identity and the service commit sequence. `seq` grows by one in every service commit that
 * records something a reader can rely on (admission, decision, continuation, effect receipt, rejected attempt), so
 * receipts can be ordered without reading Pi internals. Idle gate polls never touch it.
 */
export type IndexDocument = {
	storeId: string | null;
	lab: boolean;
	createdAt: number | null;
	seq: number;
	/** Every admitted mission ID, in admission order. */
	missions: string[];
};

const compactEvery = (_value: unknown, _ops: unknown, info: CheckpointInfo): boolean => info.deltasSinceBase >= 16;

/**
 * Durable document definitions over Pi documents. Every one is `session` scoped: it has no fork copy and no task
 * retirement, so no authority disappears when a task ends. The namespace keeps product names out of the core.
 */
export function defineDocuments(namespace: string) {
	const Index = defineDoc<IndexDocument>({
		kind: `${namespace}.index`,
		version: 1,
		scope: "session",
		initial: () => ({ storeId: null, lab: false, createdAt: null, seq: 0, missions: [] }),
		checkpointWhen: compactEvery,
	});
	const Mission = defineDocFamily<MissionDocument, null>({
		kind: `${namespace}.mission`,
		version: 1,
		scope: "session",
		family: true,
		initial: () => absentMission(),
		checkpointWhen: compactEvery,
	});
	const Approval = defineDocFamily<ApprovalDocument, null>({
		kind: `${namespace}.approval`,
		version: 1,
		scope: "session",
		family: true,
		initial: () => absentApproval(),
		checkpointWhen: compactEvery,
	});
	return { Index, Mission, Approval };
}

export type Documents = ReturnType<typeof defineDocuments>;

/** Placeholder a family read yields for an unknown key; status `absent` means nothing was ever admitted there. */
export function absentMission(): MissionDocument {
	return {
		status: "absent",
		missionId: "",
		generation: 0,
		admissionKey: "",
		entryDigest: "",
		input: null,
		approvalId: "",
		gateTaskId: 0,
		admittedSeq: 0,
		admittedAt: 0,
		incarnation: "",
		effect: null,
	};
}

export function absentApproval(): ApprovalDocument {
	return {
		status: "absent",
		approvalId: "",
		missionId: "",
		revision: "",
		action: { name: "", args: {} },
		actionDigest: "",
		requestedSeq: 0,
		requestedAt: 0,
		presentation: null,
		decision: null,
		rejectedAttempts: [],
		continuation: null,
	};
}
