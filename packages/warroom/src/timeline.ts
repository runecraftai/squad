import type { EventRecord } from "./core.ts";

export interface TimelineEntry {
	sequence: number;
	type: string;
	actor: string;
	occurredAt: string;
	summary: string;
	revisionId?: string;
	stale?: boolean;
	superseded?: boolean;
	outdated?: boolean;
}

/**
 * Pure transform from raw events plus the replayed state they produce into an ordered,
 * display-friendly history. Takes no input beyond what `Warroom.events()` and
 * `Warroom.state()` already expose, so nothing shown here is a second source of truth.
 */
export function buildTimeline(events: EventRecord[], snapshot: { revisions: any[]; approvals: any[]; comments: any[]; evidence: any[]; questions: any[] }): TimelineEntry[] {
	const revisionById = new Map(snapshot.revisions.map((revision) => [revision.id, revision]));
	const approvalById = new Map(snapshot.approvals.map((approval) => [approval.id, approval]));
	const commentById = new Map(snapshot.comments.map((comment) => [comment.id, comment]));
	const evidenceById = new Map(snapshot.evidence.map((item) => [item.id, item]));
	const questionById = new Map(snapshot.questions.map((question) => [question.id, question]));

	return events.map((event): TimelineEntry => {
		const payload = JSON.parse(event.payload);
		const base = { sequence: event.sequence, type: event.type, actor: event.actor, occurredAt: event.occurred_at };
		switch (event.type) {
		case "initiative.create":
			return { ...base, summary: `initiative created: ${payload.title}` };
		case "revision.create": {
			const revision = revisionById.get(payload.id);
			return { ...base, summary: `${payload.kind} revision created`, revisionId: payload.id, stale: revision?.stale ?? false };
		}
		case "decision.record":
			return { ...base, summary: `decision recorded: ${payload.statement}`, revisionId: payload.revisionId };
		case "approval.record": {
			const approval = approvalById.get(payload.id);
			return { ...base, summary: `${payload.kind} ${payload.decision}`, revisionId: payload.revisionId, superseded: approval?.superseded ?? false };
		}
		case "comment.add": {
			const comment = commentById.get(payload.id);
			return { ...base, summary: "comment added", revisionId: payload.revisionId, outdated: comment?.state === "outdated" };
		}
		case "validation.record": {
			const item = evidenceById.get(payload.id);
			return { ...base, summary: `${payload.provider} validation ${payload.result}`, revisionId: payload.revisionId, stale: item?.stale ?? false };
		}
		case "question.ask": {
			const question = questionById.get(payload.id);
			return { ...base, summary: `question asked: ${payload.prompt}`, revisionId: payload.revisionId, outdated: question?.status === "outdated" };
		}
		case "question.answer": {
			const question = questionById.get(payload.questionId);
			return { ...base, summary: "question answered", revisionId: question?.revisionId, outdated: question?.status === "outdated" };
		}
		default:
			return { ...base, summary: event.type };
		}
	});
}
