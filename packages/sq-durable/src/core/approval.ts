import type { Tx } from "@earendil-works/pi-durable";
import { digestOf, type Json, plainCopy } from "./canonical.js";
import { DomainError } from "./errors.js";
import type { Documents } from "./model.js";

/** The exact action an approval authorizes: a name and its concrete arguments. */
export type ApprovalAction = { name: string; args: { [key: string]: Json } };

export type Decision = "approve" | "reject";

/** Recorded by the service only, in the same commit that checks the approval is still pending. */
export type DecisionReceipt = {
	receiptId: string;
	approvalId: string;
	revision: string;
	decision: Decision;
	/** Surface-generated ID of the human act that produced the first recorded decision. */
	responseId: string;
	origin: string;
	seq: number;
	recordedAt: number;
	incarnation: string;
};

/** A different decision offered after one was recorded; kept for audit, never applied. */
export type RejectedAttempt = {
	responseId: string;
	decision: Decision;
	origin: string;
	reason: string;
	at: number;
	seq: number;
};

/** Written once per approval, in the commit that moves the gate from waiting to its effect. */
export type ContinuationReceipt = {
	receiptId: string;
	approvalId: string;
	revision: string;
	decisionReceiptId: string;
	decisionSeq: number;
	effectKey: string;
	gateTaskId: number;
	seq: number;
	recordedAt: number;
	incarnation: string;
};

export type ApprovalStatus = "absent" | "pending" | "approved" | "rejected" | "cancelled" | "superseded";

/** Durable approval record; its key is the approval ID. */
export type ApprovalDocument = {
	status: ApprovalStatus;
	approvalId: string;
	missionId: string;
	revision: string;
	action: ApprovalAction;
	actionDigest: string;
	requestedSeq: number;
	requestedAt: number;
	/** Presentation record: the approval may be shown only from this commit on, and only on these surfaces. */
	presentation: { surfaces: string[]; presentableSince: number } | null;
	decision: DecisionReceipt | null;
	rejectedAttempts: RejectedAttempt[];
	continuation: ContinuationReceipt | null;
};

const ACTION_NAME = /^[a-z][a-z0-9._-]{0,63}$/;
const REVISION = /^[A-Za-z0-9._:-]{1,128}$/;
const RESPONSE_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const MAX_REJECTED_ATTEMPTS = 50;

export function validateAction(action: ApprovalAction): void {
	if (typeof action !== "object" || action === null) throw new DomainError("invalid", "action must be an object");
	if (typeof action.name !== "string" || !ACTION_NAME.test(action.name)) {
		throw new DomainError("invalid", `action name ${JSON.stringify(action.name)} is not valid`);
	}
	if (typeof action.args !== "object" || action.args === null || Array.isArray(action.args)) {
		throw new DomainError("invalid", "action args must be a JSON object");
	}
	digestOf(action as unknown as Json);
}

export function validateRevision(revision: string): void {
	if (typeof revision !== "string" || !REVISION.test(revision)) {
		throw new DomainError("invalid", `revision ${JSON.stringify(revision)} is not valid`);
	}
}

/** One approval per mission, action and revision: a resend of the same request finds the same approval. */
export function approvalIdFor(missionId: string, actionName: string, revision: string): string {
	return `${missionId}/${actionName}/${revision}`;
}

/** What a surface sends for one human act. */
export type AnswerRequest = {
	readonly approvalId: string;
	readonly revision: string;
	readonly decision: Decision;
	readonly responseId: string;
	readonly origin: string;
	/** When present, the answer binds to this exact action; a different one is refused. */
	readonly actionDigest?: string;
};

export type AnswerResult =
	| { readonly outcome: "recorded" | "duplicate"; readonly receipt: DecisionReceipt }
	| { readonly outcome: "conflict"; readonly receipt: DecisionReceipt; readonly attempt: RejectedAttempt };

export function validateAnswer(answer: AnswerRequest): void {
	if (answer.decision !== "approve" && answer.decision !== "reject") {
		throw new DomainError("invalid", `decision must be approve or reject, got ${JSON.stringify(answer.decision)}`);
	}
	if (typeof answer.responseId !== "string" || !RESPONSE_ID.test(answer.responseId)) {
		throw new DomainError("invalid", `responseId ${JSON.stringify(answer.responseId)} is not valid`);
	}
	if (typeof answer.approvalId !== "string" || answer.approvalId.length === 0) {
		throw new DomainError("invalid", "approvalId is required");
	}
	validateRevision(answer.revision);
}

/**
 * Record a decision in one commit. The first decision recorded for an approval and revision wins:
 * - same decision again, with any responseId: the original receipt, no write;
 * - different decision: refused as a conflict and kept as a rejected attempt;
 * - old revision or a different action: refused with no write.
 */
export async function answerInTx(
	tx: Tx,
	answer: AnswerRequest,
	at: { readonly documents: Documents; readonly now: number; readonly incarnation: string },
): Promise<AnswerResult> {
	validateAnswer(answer);
	const { Index, Mission, Approval } = at.documents;
	const approval = await tx.doc(Approval, answer.approvalId, null);
	if (approval.status === "absent") {
		throw new DomainError("not_found", `approval ${answer.approvalId} does not exist`);
	}
	if (answer.revision !== approval.revision) {
		throw new DomainError(
			"stale_revision",
			`approval ${answer.approvalId} asks about revision ${approval.revision}, not ${answer.revision}; nothing was recorded`,
			{ expected: approval.revision, offered: answer.revision },
		);
	}
	if (answer.actionDigest !== undefined && answer.actionDigest !== approval.actionDigest) {
		throw new DomainError("action_mismatch", `approval ${answer.approvalId} is for a different action; nothing was recorded`, {
			expected: approval.actionDigest,
			offered: answer.actionDigest,
		});
	}
	const recorded = approval.decision;
	if (recorded !== null) {
		if (recorded.decision === answer.decision) return { outcome: "duplicate", receipt: plainCopy(recorded) };
		const index = await tx.doc(Index);
		index.seq += 1;
		const attempt: RejectedAttempt = {
			responseId: answer.responseId,
			decision: answer.decision,
			origin: answer.origin,
			reason: `decision ${recorded.decision} was already recorded at seq ${recorded.seq}`,
			at: at.now,
			seq: index.seq,
		};
		approval.rejectedAttempts.push(attempt);
		if (approval.rejectedAttempts.length > MAX_REJECTED_ATTEMPTS) approval.rejectedAttempts.shift();
		return { outcome: "conflict", receipt: plainCopy(recorded), attempt };
	}
	if (approval.status !== "pending") {
		throw new DomainError("closed", `approval ${answer.approvalId} is ${approval.status} and takes no decision`);
	}
	const index = await tx.doc(Index);
	index.seq += 1;
	const receipt: DecisionReceipt = {
		receiptId: `dec-${digestOf({ approvalId: approval.approvalId, revision: approval.revision, seq: index.seq }).slice(0, 24)}`,
		approvalId: approval.approvalId,
		revision: approval.revision,
		decision: answer.decision,
		responseId: answer.responseId,
		origin: answer.origin,
		seq: index.seq,
		recordedAt: at.now,
		incarnation: at.incarnation,
	};
	approval.decision = receipt;
	approval.status = answer.decision === "approve" ? "approved" : "rejected";
	const mission = await tx.doc(Mission, approval.missionId, null);
	if (mission.status === "absent") throw new DomainError("not_found", `mission ${approval.missionId} does not exist`);
	if (mission.status === "awaiting_approval") mission.status = answer.decision === "approve" ? "approved" : "rejected";
	return { outcome: "recorded", receipt: plainCopy(receipt) };
}
