import type { Task, Tx } from "@earendil-works/pi-durable";
import { type ApprovalAction, approvalIdFor, validateAction, validateRevision } from "./approval.js";
import { digestOf, type Json, plainCopy } from "./canonical.js";
import { type EffectRecord, effectIdFor, initialEffect } from "./effect.js";
import { DomainError } from "./errors.js";
import type { GateInput, GateResult, GateState } from "./gate.js";
import type { Documents } from "./model.js";

export type MissionStatus =
	| "absent"
	| "awaiting_approval"
	| "approved"
	| "effect"
	| "completed"
	| "rejected"
	| "cancelled"
	| "reconcile";

/** Durable mission record; its key is the mission ID, which is also the admission key. */
export type MissionDocument = {
	status: MissionStatus;
	missionId: string;
	/** Custody generation parsed from the ID; it never changes for the life of the mission. */
	generation: number;
	admissionKey: string;
	/** Digest of the canonical admission entry; a resend must match it. */
	entryDigest: string;
	input: { action: ApprovalAction; revision: string } | null;
	approvalId: string;
	gateTaskId: number;
	admittedSeq: number;
	admittedAt: number;
	/** Service incarnation that admitted the mission. */
	incarnation: string;
	effect: EffectRecord | null;
};

/**
 * Mission IDs carry their custody generation: `<prefix><generation>-<slug>`. The scheme admits exactly one prefix and one
 * generation, so a service can never admit a mission under rules it was not configured for.
 */
export type MissionIdScheme = { readonly prefix: string; readonly generation: number };

const SLUG = /^[a-z0-9][a-z0-9._-]{0,62}$/;

export function parseMissionId(
	id: string,
	prefix: string,
): { readonly generation: number; readonly slug: string } | undefined {
	if (!id.startsWith(prefix)) return undefined;
	const match = /^([0-9]+)-(.+)$/.exec(id.slice(prefix.length));
	if (match === null) return undefined;
	const generation = Number(match[1]);
	const slug = match[2] as string;
	if (!Number.isSafeInteger(generation) || !SLUG.test(slug)) return undefined;
	return { generation, slug };
}

export function missionIdFor(scheme: MissionIdScheme, slug: string): string {
	if (!SLUG.test(slug)) throw new DomainError("invalid", `mission slug ${JSON.stringify(slug)} is not valid`);
	return `${scheme.prefix}${scheme.generation}-${slug}`;
}

/** What a caller submits; the caller fixes the mission ID, and with it the admission key, before anything is created. */
export type AdmissionRequest = {
	readonly missionId: string;
	readonly action: ApprovalAction;
	readonly revision: string;
};

export type AdmissionResult = {
	readonly outcome: "created" | "existing";
	readonly missionId: string;
	readonly approvalId: string;
	readonly gateTaskId: number;
	readonly entryDigest: string;
	readonly admittedSeq: number;
};

export function validateAdmission(request: AdmissionRequest, scheme: MissionIdScheme): void {
	const parsed = parseMissionId(request.missionId, scheme.prefix);
	if (parsed === undefined) {
		throw new DomainError(
			"invalid",
			`mission ID ${JSON.stringify(request.missionId)} does not match ${scheme.prefix}<generation>-<slug>`,
		);
	}
	if (parsed.generation !== scheme.generation) {
		throw new DomainError(
			"invalid",
			`mission ID ${request.missionId} has generation ${parsed.generation}; this service admits only generation ${scheme.generation}`,
		);
	}
	validateAction(request.action);
	validateRevision(request.revision);
}

/** Digest of the canonical admission entry: the mission ID and the exact action and revision it asks to approve. */
export function entryDigestOf(request: AdmissionRequest): string {
	return digestOf({
		missionId: request.missionId,
		input: { action: request.action as unknown as Json, revision: request.revision },
	});
}

export type AdmissionContext = {
	readonly documents: Documents;
	/** The gate task; admission only creates it. */
	readonly gate: Task<GateInput, GateState, GateResult, object>;
	readonly scheme: MissionIdScheme;
	readonly now: number;
	readonly incarnation: string;
	readonly conversationId: number;
};

/**
 * Verify-and-create inside one commit. The caller runs this in a single Session commit, whose serialized mutation line
 * makes the read and the writes it conditions indivisible; a throw rolls everything back.
 *
 * - Filled mission, same digest: return the recorded IDs and create nothing.
 * - Filled mission, other digest: refuse as a conflict, with no write.
 * - New mission: create mission, approval, gate task and presentation record together.
 */
export async function admitInTx(tx: Tx, request: AdmissionRequest, at: AdmissionContext): Promise<AdmissionResult> {
	validateAdmission(request, at.scheme);
	const digest = entryDigestOf(request);
	const { Index, Mission, Approval } = at.documents;
	const mission = await tx.doc(Mission, request.missionId, null);
	if (mission.status !== "absent") {
		if (mission.entryDigest !== digest) {
			throw new DomainError(
				"conflict",
				`mission ${request.missionId} was already admitted with different content; nothing was written`,
				{ missionId: request.missionId, recordedDigest: mission.entryDigest, offeredDigest: digest },
			);
		}
		return {
			outcome: "existing",
			missionId: mission.missionId,
			approvalId: mission.approvalId,
			gateTaskId: mission.gateTaskId,
			entryDigest: mission.entryDigest,
			admittedSeq: mission.admittedSeq,
		};
	}
	const approvalId = approvalIdFor(request.missionId, request.action.name, request.revision);
	const approval = await tx.doc(Approval, approvalId, null);
	if (approval.status !== "absent") {
		throw new DomainError("conflict", `approval ${approvalId} exists without its mission; refusing to admit`);
	}
	const index = await tx.doc(Index);
	index.seq += 1;
	const seq = index.seq;
	const gateTaskId = (await tx.createTask(
		at.gate,
		{ missionId: request.missionId, approvalId },
		// Background: an abort of the root conversation never cascades into an approval. No abandonOnRestart: the gate
		// must survive every restart.
		{ ownership: { kind: "conversation" }, background: true, conversationId: at.conversationId as never },
	)) as unknown as number;
	const actionDigest = digestOf(request.action as unknown as Json);
	Object.assign(approval, {
		status: "pending",
		approvalId,
		missionId: request.missionId,
		revision: request.revision,
		action: plainCopy(request.action),
		actionDigest,
		requestedSeq: seq,
		requestedAt: at.now,
		presentation: { surfaces: ["terminal"], presentableSince: seq },
		decision: null,
		rejectedAttempts: [],
		continuation: null,
	});
	const parsed = parseMissionId(request.missionId, at.scheme.prefix);
	Object.assign(mission, {
		status: "awaiting_approval",
		missionId: request.missionId,
		generation: parsed?.generation ?? at.scheme.generation,
		admissionKey: request.missionId,
		entryDigest: digest,
		input: { action: plainCopy(request.action), revision: request.revision },
		approvalId,
		gateTaskId,
		admittedSeq: seq,
		admittedAt: at.now,
		incarnation: at.incarnation,
		effect: initialEffect(effectIdFor(request.missionId, request.action.name)),
	});
	index.missions.push(request.missionId);
	return { outcome: "created", missionId: request.missionId, approvalId, gateTaskId, entryDigest: digest, admittedSeq: seq };
}
