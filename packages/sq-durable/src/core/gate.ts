import { defineTask, type Task } from "@earendil-works/pi-durable";
import type { ContinuationReceipt } from "./approval.js";
import { digestOf, type Json, plainCopy } from "./canonical.js";
import { type EffectReceiptRecord, effectKeyFor, MAX_EFFECT_ATTEMPTS } from "./effect.js";
import { type EffectRequest, type Executor, type ExternalReceipt, verifyReceipt } from "./executor.js";
import type { Documents } from "./model.js";

export type GateInput = { missionId: string; approvalId: string };
export type GateState = { phase: "wait" } | { phase: "effect" };
export type GateResult = { outcome: "applied" | "rejected" | "cancelled" | "superseded" | "reconcile"; receiptId: string | null };

/**
 * What the gate needs from its host. `checkpoint` names a deterministic point in the gate's code; the host may use it
 * for laboratory fault injection, and it must do nothing in production.
 */
export type GateEnvironment = {
	readonly documents: Documents;
	readonly executor: Executor;
	readonly pollMs: number;
	readonly incarnation: string;
	checkpoint(point: string): void;
};

/**
 * Approval gate: one per admission, owned by the root conversation, background, never abandoned on restart.
 *
 * `wait` reads the approval in a commit. Pending: sleep one interval (the engine owns the wait). Rejected or cancelled:
 * end without effect. Approved: write the one continuation receipt and move to `effect` in that same commit.
 *
 * `effect` restarts from its top after any crash, so it always runs: count the attempt, ask the executor whether the
 * key was applied, apply with the same key only when it was not, and commit the effect receipt with the outcome.
 */
export function defineGate(namespace: string, env: GateEnvironment): Task<GateInput, GateState, GateResult, object> {
	const { Index, Mission, Approval } = env.documents;
	return defineTask<GateInput, GateState, GateResult>({
		name: `${namespace}.approval-gate`,
		version: 1,
		initial: () => ({ phase: "wait" }),
		phases: {
			wait: async (task, runtime, context) => {
				env.checkpoint("gate-wait");
				await runtime.commit(async (tx) => {
					const approval = await tx.doc(Approval, task.input.approvalId, null);
					const mission = await tx.doc(Mission, task.input.missionId, null);
					if (approval.status === "absent" || mission.status === "absent") {
						return {
							status: "terminal",
							outcome: { status: "failed", error: { message: `gate ${task.id} lost its mission or approval` } },
						};
					}
					if (approval.status === "pending") {
						return { status: "sleeping", until: runtime.now() + env.pollMs, checkpoint: { phase: "wait" } };
					}
					if (approval.status === "approved" && approval.decision !== null) {
						if (approval.continuation === null) {
							const index = await tx.doc(Index);
							index.seq += 1;
							const effectKey = effectKeyFor({
								missionId: approval.missionId,
								approvalId: approval.approvalId,
								revision: approval.revision,
								actionDigest: approval.actionDigest,
							});
							const receipt: ContinuationReceipt = {
								receiptId: `cont-${digestOf({ approvalId: approval.approvalId, seq: index.seq }).slice(0, 24)}`,
								approvalId: approval.approvalId,
								revision: approval.revision,
								decisionReceiptId: approval.decision.receiptId,
								decisionSeq: approval.decision.seq,
								effectKey,
								gateTaskId: task.id as unknown as number,
								seq: index.seq,
								recordedAt: runtime.now(),
								incarnation: env.incarnation,
							};
							approval.continuation = receipt;
							mission.status = "effect";
							if (mission.effect !== null) {
								mission.effect.effectKey = effectKey;
								mission.effect.state = "pending";
							}
						}
						return { status: "running", checkpoint: { phase: "effect" } };
					}
					const ended = approval.status === "approved" ? "cancelled" : approval.status;
					if (mission.effect !== null) mission.effect.state = "skipped";
					if (mission.status !== "rejected" && mission.status !== "cancelled") {
						mission.status = ended === "rejected" ? "rejected" : "cancelled";
					}
					return {
						status: "terminal",
						outcome: { status: "completed", result: { outcome: ended as GateResult["outcome"], receiptId: null } },
					};
				}, context);
			},
			effect: async (task, runtime, context) => {
				// 1. Count the attempt before touching the executor. A state commit can reset Pi's restart count, so the
				// gate keeps its own limit: past it, reconcile instead of applying again.
				let request: EffectRequest | undefined;
				let continuation: ContinuationReceipt | undefined;
				let attempt = 0;
				await runtime.commit(async (tx) => {
					const approval = await tx.doc(Approval, task.input.approvalId, null);
					const mission = await tx.doc(Mission, task.input.missionId, null);
					const effect = mission.effect;
					if (approval.continuation === null || effect === null || effect.effectKey === null) {
						return {
							status: "terminal",
							outcome: { status: "failed", error: { message: `gate ${task.id} reached effect without a continuation receipt` } },
						};
					}
					if (effect.receipt !== null) {
						return {
							status: "terminal",
							outcome: { status: "completed", result: { outcome: "applied", receiptId: effect.receipt.receiptId } },
						};
					}
					if (effect.attempts >= MAX_EFFECT_ATTEMPTS) {
						const index = await tx.doc(Index);
						index.seq += 1;
						effect.state = "reconcile";
						effect.reconcileReason = `${effect.attempts} attempts without a receipt; reconcile before any new apply`;
						mission.status = "reconcile";
						return {
							status: "terminal",
							outcome: { status: "completed", result: { outcome: "reconcile", receiptId: null } },
						};
					}
					effect.attempts += 1;
					effect.lastAttemptAt = runtime.now();
					attempt = effect.attempts;
					continuation = plainCopy(approval.continuation);
					const payload = {
						missionId: mission.missionId,
						approvalId: approval.approvalId,
						revision: approval.revision,
						action: plainCopy(approval.action) as unknown as Json,
					};
					request = {
						effectId: effect.effectId,
						effectKey: effect.effectKey,
						payloadDigest: digestOf(payload),
						payload,
					};
					return undefined;
				}, context);
				if (request === undefined || continuation === undefined) return;
				env.checkpoint("effect-after-attempt");

				// 2-4. Ask before applying; apply only a key the executor says is absent; ambiguity applies nothing.
				let external: ExternalReceipt;
				try {
					const found = await env.executor.lookup(request.effectKey, runtime.signal);
					if (found.status === "ambiguous") {
						await reconcile(task.input, `executor could not tell whether ${request.effectKey} was applied: ${found.reason}`);
						return;
					}
					if (found.status === "applied") {
						external = found.receipt;
					} else {
						env.checkpoint("effect-before-apply");
						external = await env.executor.apply(request, runtime.signal);
						env.checkpoint("effect-applied-before-receipt");
					}
				} catch (error) {
					if (runtime.signal.aborted) throw error;
					await reconcile(task.input, `executor failed: ${error instanceof Error ? error.message : String(error)}`);
					return;
				}
				if (!verifyReceipt(external, request)) {
					await reconcile(task.input, `executor receipt ${external.receiptId} does not match ${request.effectKey}`);
					return;
				}

				// 5. Effect receipt and outcome in one commit.
				const effectRequest = request;
				const cont = continuation;
				await runtime.commit(async (tx) => {
					const mission = await tx.doc(Mission, task.input.missionId, null);
					const effect = mission.effect;
					if (effect === null) throw new Error(`mission ${task.input.missionId} lost its effect record`);
					const index = await tx.doc(Index);
					index.seq += 1;
					const receipt: EffectReceiptRecord = {
						receiptId: external.receiptId,
						effectKey: effectRequest.effectKey,
						payloadDigest: external.payloadDigest,
						target: external.target,
						executor: env.executor.name,
						appliedAt: external.appliedAt,
						decisionReceiptId: cont.decisionReceiptId,
						continuationReceiptId: cont.receiptId,
						attempt,
						seq: index.seq,
						recordedAt: runtime.now(),
					};
					effect.receipt = receipt;
					effect.state = "applied";
					effect.reconcileReason = null;
					mission.status = "completed";
					return {
						status: "terminal",
						outcome: { status: "completed", result: { outcome: "applied", receiptId: receipt.receiptId } },
					};
				}, context);

				async function reconcile(input: GateInput, reason: string): Promise<void> {
					await runtime.commit(async (tx) => {
						const mission = await tx.doc(Mission, input.missionId, null);
						const index = await tx.doc(Index);
						index.seq += 1;
						if (mission.effect !== null) {
							mission.effect.state = "reconcile";
							mission.effect.reconcileReason = reason;
						}
						mission.status = "reconcile";
						return { status: "terminal", outcome: { status: "completed", result: { outcome: "reconcile", receiptId: null } } };
					}, context);
				}
			},
		},
		abort: async (task, runtime, context) => {
			await runtime.commit(async (tx) => {
				const approval = await tx.doc(Approval, task.input.approvalId, null);
				const mission = await tx.doc(Mission, task.input.missionId, null);
				let reason = "aborted before any decision took effect";
				if (approval.continuation === null) {
					if (approval.status === "pending" || approval.status === "approved") approval.status = "cancelled";
					if (mission.effect !== null) mission.effect.state = "skipped";
					if (mission.status !== "absent") mission.status = "cancelled";
				} else if (mission.effect !== null && mission.effect.receipt === null) {
					reason = "effect possibly started; reconcile";
					mission.effect.state = "reconcile";
					mission.effect.reconcileReason = reason;
					mission.status = "reconcile";
				} else {
					reason = "aborted after the effect receipt was recorded";
				}
				return { status: "terminal", outcome: { status: "aborted", reason } };
			}, context);
		},
	});
}
