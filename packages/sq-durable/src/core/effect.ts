import { digestOf } from "./canonical.js";

/** Attempts allowed without a receipt before the effect goes to reconciliation instead of another apply. */
export const MAX_EFFECT_ATTEMPTS = 3;

/** Effect receipt as recorded in the mission document. */
export type EffectReceiptRecord = {
	receiptId: string;
	effectKey: string;
	payloadDigest: string;
	target: string;
	executor: string;
	appliedAt: number;
	/** Decision receipt this effect was applied under. */
	decisionReceiptId: string;
	/** Continuation receipt this effect was applied under. */
	continuationReceiptId: string;
	/** Attempt that recorded the receipt. */
	attempt: number;
	seq: number;
	recordedAt: number;
};

/** Durable state of the mission's one controlled effect. */
export type EffectRecord = {
	/** Logical identity, stable across attempts. */
	effectId: string;
	/** Idempotent key; null until the continuation receipt fixes it. */
	effectKey: string | null;
	state: "waiting" | "pending" | "applied" | "reconcile" | "skipped";
	attempts: number;
	lastAttemptAt: number | null;
	reconcileReason: string | null;
	receipt: EffectReceiptRecord | null;
};

export function effectIdFor(missionId: string, actionName: string): string {
	return `${missionId}/effect/${actionName}`;
}

/** The key depends only on what was approved, so every attempt and every restart derives the same one. */
export function effectKeyFor(input: {
	readonly missionId: string;
	readonly approvalId: string;
	readonly revision: string;
	readonly actionDigest: string;
}): string {
	return digestOf({
		missionId: input.missionId,
		approvalId: input.approvalId,
		revision: input.revision,
		actionDigest: input.actionDigest,
	});
}

export function initialEffect(effectId: string): EffectRecord {
	return {
		effectId,
		effectKey: null,
		state: "waiting",
		attempts: 0,
		lastAttemptAt: null,
		reconcileReason: null,
		receipt: null,
	};
}
