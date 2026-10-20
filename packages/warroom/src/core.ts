import { createHash, randomUUID } from "node:crypto";
import { Database } from "bun:sqlite";
import { type DiffLine, lineDiff } from "./diff.ts";
import { migrate } from "./schema.ts";
import { buildTimeline, type TimelineEntry } from "./timeline.ts";

export type ApprovalKind = "plan-approval" | "execution-authorization" | "code-review-acceptance" | "merge-permission";
export type CommentTarget = "plan-range" | "diagram-node" | "code-range" | "review";
export type CommentKind = "comment" | "suggestion";
export type Provenance = "drill" | "manual" | "fixture";
export type PacketStatus = "ready" | "stale" | "accepted" | "changes-requested";

export interface ArtifactRef { digest: string; byteLength: number; mediaType: string; relativePath?: string }
export interface CurrentnessCheck { verified: boolean; checkedAt: string; headSha: string; baseSha: string }


export type Command =
	| { type: "initiative.create"; id?: string; title: string; workingName?: string }
	| { type: "revision.create"; id?: string; initiativeId: string; kind: "plan" | "code"; content: string }
	| { type: "decision.record"; id?: string; initiativeId: string; revisionId: string; statement: string; rationale: string; selectedAlternatives?: string[] }
	| {
		type: "approval.record";
		id?: string;
		initiativeId: string;
		kind: ApprovalKind;
		revisionId: string;
		decision: "approved" | "rejected" | "changes-requested";
		evidenceId?: string;
		packetId?: string;
		packetDigest?: string;
		evidenceDigest?: string;
		scopeDigest?: string;
		declaration?: string;
		actorConfirmed?: boolean;
		currentness?: CurrentnessCheck;
	}
	| {
		type: "comment.add";
		id?: string;
		initiativeId: string;
		revisionId: string;
		body: string;
		targetType?: CommentTarget;
		packetId?: string;
		path?: string;
		side?: "base" | "head";
		startLine?: number;
		endLine?: number;
		blobSha?: string;
		context?: string;
		snapshotDigest?: string;
		kind?: CommentKind;
		suggestion?: string;
	}
	| { type: "comment.resolve"; id?: string; initiativeId: string; commentId: string }
	| { type: "validation.record"; id?: string; initiativeId: string; revisionId: string; provider: string; result: string }
	| { type: "question.ask"; id?: string; initiativeId: string; revisionId: string; prompt: string; context?: string }
	| { type: "question.answer"; id?: string; initiativeId: string; questionId: string; answer: string }
	| {
		type: "review.capture.record";
		id?: string;
		initiativeId: string;
		revisionId: string;
		captureId: string;
		captureVersion: number;
		captureJson: string;
		captureDigest: string;
		provenance: Provenance;
		runId: string;
		repoId: string;
		drillVersion: string;
		drillBuildSha?: string;
		drillBaseSha: string;
		submittedHeadSha?: string;
		reviewedHeadSha?: string;
		deliveredHeadSha: string;
		runStatus: string;
		ciReady: boolean;
		ciReadyNoCi: boolean;
		eligible: boolean;
		ineligibility?: string;
		capturedAt: string;
		artifacts?: ArtifactRef[];
	}
	| {
		type: "review.packet.create";
		id?: string;
		initiativeId: string;
		revisionId: string;
		evidenceId: string;
		planRevisionId: string;
		repoId: string;
		repoFingerprint: string;
		repoPath?: string;
		targetRef: string;
		targetObservedSha?: string;
		headRef?: string;
		reviewBaseSha: string;
		headSha: string;
		baseTree: string;
		headTree: string;
		manifestDigest: string;
		patchDigest: string;
		scopeDigest: string;
		packetDigest: string;
	}
	| { type: "review.supersede"; id?: string; initiativeId: string; packetId: string; supersededBy?: string; reason: string; observedHeadSha?: string; observedBaseSha?: string };

export interface EventRecord { sequence: number; id: string; initiative_id: string; type: string; actor: string; occurred_at: string; payload_version: number; payload: string }
export interface Actor { id: string }
export interface RevisionComparison {
	revisionA: { id: string; kind: string; digest: string };
	revisionB: { id: string; kind: string; digest: string };
	sameIdentity: boolean;
	identicalContent: boolean;
	diff: DiffLine[];
}

export class Warroom {
	readonly db: Database;
	constructor(path = ":memory:", private readonly actor: Actor = { id: "local" }, db?: Database) {
		this.db = db ?? new Database(path, { create: true });
		migrate(this.db);
	}

	command(command: Command): EventRecord {
		const id = command.id ?? randomUUID();
		const now = new Date().toISOString();
		const payload = { ...command, id };
		const initiativeId = command.type === "initiative.create" ? id : command.initiativeId;
		return this.db.transaction(() => {
			this.validate(command);
			const event = this.db.query(`INSERT INTO events(id, initiative_id, type, actor, occurred_at, payload_version, payload)
				VALUES (?, ?, ?, ?, ?, 1, ?) RETURNING *`).get(id, initiativeId, command.type, this.actor.id, now, JSON.stringify(payload)) as EventRecord;
			this.project(command, id, now);
			return event;
		})();
	}

	events(initiativeId?: string): EventRecord[] {
		return (initiativeId
			? this.db.query("SELECT * FROM events WHERE initiative_id = ? ORDER BY sequence").all(initiativeId)
			: this.db.query("SELECT * FROM events ORDER BY sequence").all()) as EventRecord[];
	}

	state(initiativeId: string) {
		const events = this.events(initiativeId);
		const initiatives = new Map<string, any>();
		const revisions = new Map<string, any>();
		const decisions: any[] = [], approvals: any[] = [], comments: any[] = [], evidence: any[] = [], questions: any[] = [], packets: any[] = [], captures: any[] = [];
		for (const event of events) {
			const p = JSON.parse(event.payload);
			switch (event.type) {
			case "initiative.create": initiatives.set(p.id, { id: p.id, title: p.title, workingName: p.workingName ?? "Runecraft Warroom", phase: "discover" }); break;
			case "revision.create": {
				const digest = digestContent(p.content);
				const revision = { id: p.id, initiativeId: p.initiativeId, kind: p.kind, digest, content: p.content, stale: false };
				for (const prior of revisions.values()) if (prior.initiativeId === p.initiativeId && prior.kind === p.kind) prior.stale = true;
				revisions.set(p.id, revision);
				if (p.kind === "plan") initiatives.get(p.initiativeId).currentPlanRevisionId = p.id;
				for (const a of approvals) if (a.revisionId !== p.id && revisions.get(a.revisionId)?.stale) a.superseded = true;
				for (const c of comments) if (c.revisionId !== p.id && revisions.get(c.revisionId)?.stale) { c.state = "outdated"; c.anchorStatus = "outdated"; }
				for (const e of evidence) if (e.revisionId !== p.id && revisions.get(e.revisionId)?.stale && e.provenance === "legacy") e.stale = true;
				for (const q of questions) if (q.revisionId !== p.id && revisions.get(q.revisionId)?.stale) q.status = "outdated";
				for (const packet of packets) {
					const reason = p.kind === "plan" ? "plan-changed" : "revision-superseded";
					const bound = p.kind === "plan" ? packet.planRevisionId : packet.codeRevisionId;
					if (bound !== p.id && revisions.get(bound)?.stale && packet.status !== "stale") {
						packet.status = "stale";
						packet.staleReason = reason;
					}
				}
				break;
			}
			case "decision.record": decisions.push({ ...p, sourceRevisionId: p.revisionId }); break;
			case "approval.record": {
				const approval = {
					...p,
					actor: event.actor,
					createdAt: event.occurred_at,
					superseded: false,
					supersededAt: null,
					subjectDigest: revisions.get(p.revisionId)?.digest,
					packetId: p.packetId ?? null,
					packetDigest: p.packetDigest ?? null,
					evidenceDigest: p.evidenceDigest ?? null,
					scopeDigest: p.scopeDigest ?? null,
					declaration: p.declaration ?? null,
					actorConfirmed: p.actorConfirmed === true,
					staleReason: null,
				};
				approvals.push(approval);
				if (p.packetId) {
					const packet = packets.find((item) => item.id === p.packetId);
					if (packet && p.kind === "code-review-acceptance" && packet.status !== "stale") packet.status = p.decision === "approved" ? "accepted" : "changes-requested";
				}
				break;
			}
			case "comment.add": comments.push({ ...p, createdBy: event.actor, createdAt: event.occurred_at, state: "open", anchorStatus: "current", targetType: p.targetType ?? "review", kind: p.kind ?? "comment" }); break;
			case "comment.resolve": {
				const comment = comments.find((item) => item.id === p.commentId);
				if (comment) { comment.state = "resolved"; comment.resolvedAt = event.occurred_at; comment.resolvedBy = event.actor; }
				break;
			}
			case "validation.record": evidence.push({ ...p, digest: revisions.get(p.revisionId)?.digest, stale: false, provenance: "legacy", eligible: false }); break;
			case "review.capture.record": {
				captures.push({ ...p, capturedAt: p.capturedAt });
				evidence.push({
					id: p.captureId,
					initiativeId: p.initiativeId,
					revisionId: p.revisionId,
					digest: revisions.get(p.revisionId)?.digest,
					provider: "drill",
					providerVersion: p.drillVersion,
					result: p.runStatus,
					capturedAt: p.capturedAt,
					stale: false,
					provenance: p.provenance,
					captureId: p.captureId,
					captureDigest: p.captureDigest,
					eligible: p.eligible === true,
					ineligibility: p.ineligibility ?? null,
					deliveredHeadSha: p.deliveredHeadSha,
					drillBaseSha: p.drillBaseSha,
					submittedHeadSha: p.submittedHeadSha ?? null,
					reviewedHeadSha: p.reviewedHeadSha ?? null,
					runStatus: p.runStatus,
				});
				break;
			}
			case "review.packet.create": {
				packets.push({
					...p,
					codeRevisionId: p.revisionId,
					evidenceDigest: evidence.find((item) => item.id === p.evidenceId)?.captureDigest ?? null,
					status: "ready",
					supersededAt: null,
					supersededBy: null,
					staleReason: null,
				});
				break;
			}
			case "review.supersede": {
				const packet = packets.find((item) => item.id === p.packetId);
				if (packet) {
					packet.status = "stale";
					packet.supersededAt = event.occurred_at;
					packet.supersededBy = p.supersededBy ?? null;
					packet.staleReason = p.reason;
				}
				for (const approval of approvals) {
					if (approval.packetId !== p.packetId) continue;
					approval.staleReason = p.reason;
					approval.superseded = true;
					approval.supersededAt = event.occurred_at;
				}
				break;
			}
			case "question.ask": questions.push({ ...p, status: "open" }); break;
			case "question.answer": {
				const question = questions.find((item) => item.id === p.questionId);
				if (question) { question.status = "answered"; question.answer = p.answer; question.answeredBy = event.actor; question.answeredAt = event.occurred_at; }
				break;
			}
			}
		}
		return { initiative: initiatives.get(initiativeId), revisions: [...revisions.values()], decisions, approvals, comments, evidence, questions, packets, captures };
	}

	/** Ordered, display-friendly reconstruction of one initiative's history. Nothing here is a second source of truth: every field is derived from `events()` and the replayed `state()`. */
	timeline(initiativeId: string): TimelineEntry[] {
		return buildTimeline(this.events(initiativeId), this.state(initiativeId));
	}

	/** Compares two revisions of the same kind within one initiative by content digest and, when they differ, a structural line diff. Never claims Git ancestry or Drill execution. */
	compare(initiativeId: string, revisionIdA: string, revisionIdB: string): RevisionComparison {
		const state = this.state(initiativeId);
		const a = state.revisions.find((item) => item.id === revisionIdA);
		const b = state.revisions.find((item) => item.id === revisionIdB);
		if (!a || !b) throw new Error("revision does not exist");
		if (a.kind !== b.kind) throw new Error("cannot compare revisions of different kinds");
		const identicalContent = a.digest === b.digest;
		return {
			revisionA: { id: a.id, kind: a.kind, digest: a.digest },
			revisionB: { id: b.id, kind: b.kind, digest: b.digest },
			sameIdentity: a.id === b.id,
			identicalContent,
			diff: identicalContent ? [] : lineDiff(a.content, b.content),
		};
	}

	/** Reads one packet row as persisted by the projection, for replay-versus-projection checks. */
	packetRow(packetId: string): any {
		return this.db.query("SELECT * FROM review_packets WHERE id = ?").get(packetId) ?? null;
	}

	close(): void { this.db.close(); }

	private validate(command: Command): void {
		if (command.id !== undefined) assertIdentifier(command.id, "command id");
		if (command.type === "initiative.create") return;
		const state = this.state(command.initiativeId);
		if (!state.initiative) throw new Error("initiative does not exist");
		if (command.type === "revision.create") return;
		if (command.type === "review.capture.record") { this.validateCapture(command); return; }
		if (command.type === "review.packet.create") { this.validatePacket(command, state); return; }
		if (command.type === "review.supersede") {
			const packet = state.packets.find((item) => item.id === command.packetId);
			if (!packet) throw new Error("review packet does not exist");
			if (!command.reason) throw new Error("supersession requires a reason");
			if (command.supersededBy && !state.packets.some((item) => item.id === command.supersededBy)) throw new Error("replacement review packet does not exist");
			return;
		}
		if (command.type === "comment.resolve") {
			const comment = state.comments.find((item) => item.id === command.commentId);
			if (!comment) throw new Error("comment does not exist");
			if (comment.state !== "open") throw new Error("comment is not open");
			return;
		}
		if (command.type === "comment.add") { this.validateComment(command, state); return; }
		if (command.type === "question.answer") {
			const question = state.questions.find((item) => item.id === command.questionId);
			if (!question) throw new Error("question does not exist");
			if (question.status !== "open") throw new Error("question is not open");
			const questionRevision = state.revisions.find((item) => item.id === question.revisionId);
			if (!questionRevision || questionRevision.stale) throw new Error("question's revision is missing or stale");
			return;
		}
		const revision = state.revisions.find((item) => item.id === command.revisionId);
		if (!revision || revision.stale) throw new Error("revision is missing or stale");
		if (command.type === "decision.record" && revision.kind !== "plan") throw new Error("decisions must bind to a plan revision");
		if (command.type === "approval.record") {
			const expectedKind = command.kind === "plan-approval" || command.kind === "execution-authorization" ? "plan" : "code";
			if (revision.kind !== expectedKind) throw new Error("approval scope does not match revision kind");
			if (command.kind === "code-review-acceptance") {
				const packet = command.packetId
					? state.packets.find((item) => item.id === command.packetId)
					: state.packets.find((item) => item.codeRevisionId === revision.id);
				if (command.packetId && !packet) throw new Error("review packet does not exist");
				if (packet) { this.validatePacketAcceptance(command, packet, state); return; }
				if (command.decision === "approved" && !command.evidenceId) throw new Error("review acceptance requires validation evidence");
				if (command.evidenceId) {
					const evidence = state.evidence.find((item) => item.id === command.evidenceId);
					if (!evidence || evidence.stale || evidence.revisionId !== revision.id || (command.decision === "approved" && evidence.result !== "passed")) throw new Error("validation evidence does not cover this revision");
				}
			} else if (command.evidenceId != null && !state.evidence.some((item) => item.id === command.evidenceId)) {
				throw new Error("validation evidence does not exist");
			}
		}
		if (command.type === "validation.record" && revision.kind !== "code") throw new Error("validation evidence must bind to a code revision");
	}

	private validateCapture(command: Extract<Command, { type: "review.capture.record" }>): void {
		if (command.captureVersion !== 1) throw new Error("unsupported evidence capture version");
		if (!["drill", "manual", "fixture"].includes(command.provenance)) throw new Error("unsupported evidence provenance");
		assertSha(command.deliveredHeadSha, "delivered head");
		assertSha(command.drillBaseSha, "drill base");
		if (command.submittedHeadSha) assertSha(command.submittedHeadSha, "submitted head");
		if (command.reviewedHeadSha) assertSha(command.reviewedHeadSha, "reviewed head");
		assertDigest(command.captureDigest, "capture digest");
		let parsed: any;
		try { parsed = JSON.parse(command.captureJson); } catch { throw new Error("evidence capture is not valid JSON"); }
		if (parsed?.captureVersion !== 1) throw new Error("evidence capture JSON version is unsupported");
		if (digestContent(command.captureJson) !== command.captureDigest) throw new Error("evidence capture digest does not match its content");
		if (parsed?.provenance !== command.provenance) throw new Error("evidence capture provenance does not match the command");
		if (!command.capturedAt) throw new Error("evidence capture requires a capture timestamp");
		for (const artifact of command.artifacts ?? []) {
			assertDigest(artifact.digest, "artifact digest");
			if (artifact.relativePath !== undefined && artifact.relativePath !== artifactPath(artifact.digest)) throw new Error("artifact path does not match its digest");
			if (!Number.isInteger(artifact.byteLength) || artifact.byteLength < 0) throw new Error("artifact byte length is invalid");
		}
	}

	private validatePacket(command: Extract<Command, { type: "review.packet.create" }>, state: ReturnType<Warroom["state"]>): void {
		const revision = state.revisions.find((item) => item.id === command.revisionId);
		if (!revision || revision.kind !== "code") throw new Error("review packet requires a code revision");
		if (revision.stale) throw new Error("review packet revision is stale");
		const evidence = state.evidence.find((item) => item.id === command.evidenceId);
		if (!evidence) throw new Error("review packet requires validation evidence");
		if (evidence.revisionId !== revision.id) throw new Error("validation evidence does not cover this revision");
		if (!evidence.captureId) throw new Error("review packet requires captured validation evidence, not a free response");
		const plan = state.revisions.find((item) => item.id === command.planRevisionId);
		if (!plan || plan.kind !== "plan") throw new Error("review packet requires a plan revision");
		if (state.initiative?.currentPlanRevisionId !== plan.id) throw new Error("review packet requires the current plan revision");
		for (const [label, value] of [["review base", command.reviewBaseSha], ["head", command.headSha], ["base tree", command.baseTree], ["head tree", command.headTree]] as const) assertSha(value, label);
		for (const [label, value] of [["manifest", command.manifestDigest], ["patch", command.patchDigest], ["scope", command.scopeDigest], ["packet", command.packetDigest]] as const) assertDigest(value, label);
		if (digestContent(revision.content) !== command.manifestDigest) throw new Error("review packet manifest digest does not match the code revision content");
		let manifest: any;
		try { manifest = JSON.parse(revision.content); } catch { throw new Error("review packet manifest is not valid JSON"); }
		if (!Array.isArray(manifest?.files)) throw new Error("review packet manifest has no file list");
		if (scopeDigestOf(manifest.files) !== command.scopeDigest) throw new Error("review packet scope digest does not match the manifest");
		const expectedDigest = packetDigestOf({
			repoId: command.repoId,
			repoFingerprint: command.repoFingerprint,
			targetRef: command.targetRef,
			reviewBaseSha: command.reviewBaseSha,
			headSha: command.headSha,
			baseTree: command.baseTree,
			headTree: command.headTree,
			manifestDigest: command.manifestDigest,
			scopeDigest: command.scopeDigest,
			patchDigest: command.patchDigest,
			planRevisionId: command.planRevisionId,
			planDigest: plan.digest,
			evidenceId: command.evidenceId,
			evidenceDigest: evidence.captureDigest,
		});
		if (expectedDigest !== command.packetDigest) throw new Error("review packet digest does not match its content");
	}

	private validatePacketAcceptance(command: Extract<Command, { type: "approval.record" }>, packet: any, state: ReturnType<Warroom["state"]>): void {
		if (packet.status === "stale") throw new Error("review packet is stale; a new snapshot must be captured");
		if (command.packetId !== packet.id) throw new Error("review acceptance must name the exact review packet");
		if (packet.codeRevisionId !== command.revisionId) throw new Error("review acceptance packet does not cover this revision");
		if (command.packetDigest !== packet.packetDigest) throw new Error("review acceptance packet digest does not match");
		if (command.evidenceDigest !== packet.evidenceDigest) throw new Error("review acceptance evidence digest does not match");
		if (!command.scopeDigest || command.scopeDigest !== packet.scopeDigest) throw new Error("review acceptance must cover the complete packet scope");
		if (!command.declaration || !command.declaration.trim()) throw new Error("review acceptance requires an explicit declaration");
		if (command.decision === "approved") {
			if (packet.status === "accepted") throw new Error("review packet is already accepted");
			if (command.actorConfirmed !== true) throw new Error("review acceptance requires confirmed human authority");
			if (!command.currentness?.verified) throw new Error("review acceptance requires a verified current snapshot");
			if (command.currentness.headSha !== packet.headSha || command.currentness.baseSha !== packet.reviewBaseSha) throw new Error("review acceptance currentness does not match the packet");
			const evidence = state.evidence.find((item) => item.id === packet.evidenceId);
			if (!evidence || evidence.provenance !== "drill" || !evidence.eligible) throw new Error("review acceptance requires eligible Drill evidence for the delivered head");
			if (evidence.deliveredHeadSha !== packet.headSha) throw new Error("review acceptance evidence does not cover the delivered head");
			if (state.initiative?.currentPlanRevisionId !== packet.planRevisionId) throw new Error("review acceptance requires the reviewed plan revision to be current");
			const revision = state.revisions.find((item) => item.id === packet.codeRevisionId);
			if (!revision || revision.stale) throw new Error("review acceptance requires the reviewed code revision to be current");
			let manifest: any;
			try { manifest = JSON.parse(revision.content); } catch { throw new Error("review packet manifest is unreadable"); }
			const unreviewable = (manifest.files ?? []).filter((file: any) => !(file.head?.reviewable || file.base?.reviewable)).map((file: any) => file.path);
			if (unreviewable.length > 0) throw new Error(`review acceptance is blocked by objects that cannot be reviewed: ${unreviewable.join(", ")}`);
		}
	}

	private validateComment(command: Extract<Command, { type: "comment.add" }>, state: ReturnType<Warroom["state"]>): void {
		const target = command.targetType ?? "review";
		const packet = command.packetId ? state.packets.find((item) => item.id === command.packetId) : undefined;
		if (command.packetId) {
			if (!packet) throw new Error("review packet does not exist");
			if (packet.status === "stale") throw new Error("review packet is stale; comments stay on their own snapshot");
			if (command.snapshotDigest !== packet.packetDigest) throw new Error("comment snapshot digest does not match the review packet");
			if (packet.codeRevisionId !== command.revisionId && packet.planRevisionId !== command.revisionId) throw new Error("comment must bind to a revision of the review packet");
			let manifest: any;
			try { manifest = JSON.parse(state.revisions.find((item) => item.id === packet.codeRevisionId)?.content ?? "{}"); } catch { throw new Error("review packet manifest is unreadable"); }
			if (command.path) {
				const file = (manifest.files ?? []).find((item: any) => item.path === command.path);
				if (!file) throw new Error("comment path is not part of the review packet manifest");
				if (target === "code-range") {
					if (!command.side || !["base", "head"].includes(command.side)) throw new Error("code comments require a base or head side");
					if (!command.blobSha) throw new Error("code comments require the anchored blob");
					const expectedBlob = command.side === "base" ? file.base?.blob ?? null : file.head?.blob ?? null;
					if (expectedBlob !== command.blobSha) throw new Error("comment blob does not match the packet object at that side");
					assertLineRange(command.startLine, command.endLine);
				}
			}
		}
		if (target === "code-range") {
			if (!command.packetId) throw new Error("code comments require a review packet");
			if (!command.path) throw new Error("code comments require a path");
		}
		if (target === "diagram-node" && !command.context) throw new Error("diagram comments require a node identity");
		if (target === "plan-range" && !command.revisionId) throw new Error("plan comments require a plan revision");
		if (command.kind === "suggestion") {
			if (target !== "code-range") throw new Error("suggestions must anchor to a code range");
			if (!command.suggestion || !command.suggestion.trim()) throw new Error("a suggestion requires its proposed text");
		}
		const revision = state.revisions.find((item) => item.id === command.revisionId);
		if (!revision || revision.stale) throw new Error("revision is missing or stale");
	}

	private project(command: Command, id: string, now: string): void {
		switch (command.type) {
		case "initiative.create":
			this.db.query("INSERT INTO initiatives(id,title,working_name,phase,created_at,updated_at) VALUES(?,?,?,'discover',?,?)").run(id, command.title, command.workingName ?? "Runecraft Warroom", now, now); break;
		case "revision.create": {
			const previous = (this.db.query("SELECT id FROM revisions WHERE initiative_id=? AND kind=? ORDER BY created_at DESC, rowid DESC LIMIT 1").get(command.initiativeId, command.kind) as { id: string } | null)?.id ?? null;
			const digest = digestContent(command.content);
			this.db.query("INSERT INTO revisions(id,initiative_id,kind,digest,previous_revision_id,content,created_by,created_at) VALUES(?,?,?,?,?,?,?,?)").run(id, command.initiativeId, command.kind, digest, previous, command.content, this.actor.id, now);
			if (command.kind === "plan") this.db.query("UPDATE initiatives SET current_plan_revision_id=?,updated_at=? WHERE id=?").run(id, now, command.initiativeId);
			this.db.query("UPDATE approvals SET superseded_at=?,superseded_by=? WHERE initiative_id=? AND superseded_at IS NULL AND subject_revision_id IN (SELECT id FROM revisions WHERE initiative_id=? AND kind=? AND id<>?)").run(now, id, command.initiativeId, command.initiativeId, command.kind, id);
			for (const table of ["validation_evidence", "comments", "questions"]) {
				const setClause = table === "comments" ? "state='outdated', anchor_status='outdated'" : table === "questions" ? "status='outdated'" : "stale=1";
				const scope = table === "validation_evidence" ? " AND provenance='legacy'" : "";
				this.db.query(`UPDATE ${table} SET ${setClause} WHERE initiative_id=? AND revision_id IN (SELECT id FROM revisions WHERE initiative_id=? AND kind=? AND id<>?)${scope}`).run(command.initiativeId, command.initiativeId, command.kind, id);
			}
			const reason = command.kind === "plan" ? "plan-changed" : "revision-superseded";
			const boundColumn = command.kind === "plan" ? "plan_revision_id" : "code_revision_id";
			this.db.query(`UPDATE review_packets SET status='stale', stale_reason=? WHERE initiative_id=? AND ${boundColumn} IN (SELECT id FROM revisions WHERE initiative_id=? AND kind=? AND id<>?) AND status<>'stale'`).run(reason, command.initiativeId, command.initiativeId, command.kind, id);
			break;
		}
		case "decision.record": this.db.query("INSERT INTO decisions(id,initiative_id,source_revision_id,statement,rationale,selected_alternatives,decided_by,decided_at) VALUES(?,?,?,?,?,?,?,?)").run(id, command.initiativeId, command.revisionId, command.statement, command.rationale, JSON.stringify(command.selectedAlternatives ?? []), this.actor.id, now); break;
		case "approval.record": {
			this.db.query("INSERT INTO approvals(id,initiative_id,kind,subject_revision_id,subject_digest,evidence_revision_id,decision,actor,created_at,packet_id,packet_digest,evidence_digest,scope_json,declaration,actor_confirmed,stale_reason) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
				.run(id, command.initiativeId, command.kind, command.revisionId, digestContent(this.revisionContent(command.revisionId)), command.evidenceId || null, command.decision, this.actor.id, now, command.packetId ?? null, command.packetDigest ?? null, command.evidenceDigest ?? null, command.scopeDigest ?? null, command.declaration ?? null, command.actorConfirmed === true ? 1 : 0, null);
			if (command.packetId && command.kind === "code-review-acceptance") {
				this.db.query("UPDATE review_packets SET status=? WHERE id=? AND status<>'stale'").run(command.decision === "approved" ? "accepted" : "changes-requested", command.packetId);
			}
			break;
		}
		case "comment.add": this.db.query(`INSERT INTO comments(id,initiative_id,revision_id,body,state,created_by,created_at,packet_id,target_type,path,side,start_line,end_line,blob_sha,anchor_context,snapshot_digest,comment_kind,suggestion,anchor_status,resolved_at,resolved_by)
			VALUES(?,?,?,?,'open',?,?,?,?,?,?,?,?,?,?,?,?,?,'current',NULL,NULL)`)
			.run(id, command.initiativeId, command.revisionId, command.body, this.actor.id, now, command.packetId ?? null, command.targetType ?? "review", command.path ?? null, command.side ?? null, command.startLine ?? null, command.endLine ?? null, command.blobSha ?? null, command.context ?? null, command.snapshotDigest ?? null, command.kind ?? "comment", command.suggestion ?? null); break;
		case "comment.resolve": this.db.query("UPDATE comments SET state='resolved', resolved_at=?, resolved_by=? WHERE id=?").run(now, this.actor.id, command.commentId); break;
		case "validation.record": this.db.query("INSERT INTO validation_evidence(id,initiative_id,revision_id,digest,provider,result,captured_at,stale,provenance,eligible) VALUES(?,?,?,?,?,?,?,0,'legacy',0)").run(id, command.initiativeId, command.revisionId, digestContent(this.revisionContent(command.revisionId)), command.provider, command.result, now); break;
		case "question.ask": this.db.query("INSERT INTO questions(id,initiative_id,revision_id,prompt,context,status,created_by,created_at) VALUES(?,?,?,?,?,'open',?,?)").run(id, command.initiativeId, command.revisionId, command.prompt, command.context ?? "", this.actor.id, now); break;
		case "question.answer": this.db.query("UPDATE questions SET status='answered', answer=?, answered_by=?, answered_at=? WHERE id=?").run(command.answer, this.actor.id, now, command.questionId); break;
		case "review.capture.record": {
			this.db.query(`INSERT INTO evidence_captures(id,initiative_id,revision_id,capture_version,capture_json,capture_digest,provenance,run_id,repo_id,drill_version,drill_build_sha,drill_base_sha,submitted_head_sha,reviewed_head_sha,delivered_head_sha,run_status,ci_ready,ci_ready_no_ci,eligible,ineligibility,captured_at,created_by)
				VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
				.run(command.captureId, command.initiativeId, command.revisionId, command.captureVersion, command.captureJson, command.captureDigest, command.provenance, command.runId, command.repoId, command.drillVersion, command.drillBuildSha ?? null, command.drillBaseSha, command.submittedHeadSha ?? null, command.reviewedHeadSha ?? null, command.deliveredHeadSha, command.runStatus, command.ciReady ? 1 : 0, command.ciReadyNoCi ? 1 : 0, command.eligible ? 1 : 0, command.ineligibility ?? null, command.capturedAt, this.actor.id);
			this.db.query("INSERT INTO validation_evidence(id,initiative_id,revision_id,digest,provider,result,captured_at,stale,provenance,capture_id,capture_digest,provider_version,eligible,ineligibility,delivered_head_sha,drill_base_sha,submitted_head_sha,reviewed_head_sha,run_status) VALUES(?,?,?,?,'drill',?,?,0,?,?,?,?,?,?,?,?,?,?,?)")
				.run(command.captureId, command.initiativeId, command.revisionId, digestContent(this.revisionContent(command.revisionId)), command.runStatus, command.capturedAt, command.provenance, command.captureId, command.captureDigest, command.drillVersion, command.eligible ? 1 : 0, command.ineligibility ?? null, command.deliveredHeadSha, command.drillBaseSha, command.submittedHeadSha ?? null, command.reviewedHeadSha ?? null, command.runStatus);
			for (const artifact of command.artifacts ?? []) {
				this.db.query("INSERT OR IGNORE INTO artifacts(digest,byte_length,media_type,relative_path,created_at) VALUES(?,?,?,?,?)").run(artifact.digest, artifact.byteLength, artifact.mediaType, artifactPath(artifact.digest), now);
			}
			break;
		}
		case "review.packet.create": {
			const evidenceDigest = (this.db.query("SELECT capture_digest FROM validation_evidence WHERE id=?").get(command.evidenceId) as { capture_digest: string }).capture_digest;
			this.db.query(`INSERT INTO review_packets(id,initiative_id,code_revision_id,plan_revision_id,plan_digest,repo_id,repo_fingerprint,repo_path,target_ref,target_observed_sha,head_ref,review_base_sha,head_sha,base_tree,head_tree,manifest_digest,patch_digest,scope_digest,evidence_id,evidence_digest,packet_digest,status,created_by,created_at)
				VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'ready',?,?)`)
				.run(id, command.initiativeId, command.revisionId, command.planRevisionId, digestContent(this.revisionContent(command.planRevisionId)), command.repoId, command.repoFingerprint, command.repoPath ?? null, command.targetRef, command.targetObservedSha ?? null, command.headRef ?? null, command.reviewBaseSha, command.headSha, command.baseTree, command.headTree, command.manifestDigest, command.patchDigest, command.scopeDigest, command.evidenceId, evidenceDigest, command.packetDigest, this.actor.id, now);
			break;
		}
		case "review.supersede": {
			this.db.query("UPDATE review_packets SET status='stale', superseded_at=?, superseded_by=?, stale_reason=? WHERE id=?").run(now, command.supersededBy ?? null, command.reason, command.packetId);
			this.db.query("UPDATE approvals SET stale_reason=?, superseded_at=? WHERE packet_id=?").run(command.reason, now, command.packetId);
			break;
		}
		}
	}

	private revisionContent(id: string): string { return (this.db.query("SELECT content FROM revisions WHERE id=?").get(id) as { content: string }).content; }
}

export function digestContent(content: string): string { return createHash("sha256").update(content, "utf8").digest("hex"); }

/** Stable JSON serialization: object keys are sorted at every depth, so equal values always digest equally. */
export function canonicalJson(value: unknown): string {
	if (value === null || typeof value !== "object") return JSON.stringify(value);
	if (Array.isArray(value)) return `[${value.map((item) => canonicalJson(item)).join(",")}]`;
	const entries = Object.keys(value as Record<string, unknown>).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson((value as Record<string, unknown>)[key])}`);
	return `{${entries.join(",")}}`;
}

export function digestCanonical(value: unknown): string { return digestContent(canonicalJson(value)); }

/** Digest of the complete file scope: every path, status and both blob identities. Subsets never match. */
export function scopeDigestOf(files: Array<{ path: string; status: string; baseBlob?: string | null; headBlob?: string | null; base?: { blob: string } | null; head?: { blob: string } | null }>): string {
	return digestCanonical(files.map((file) => ({
		path: file.path,
		status: file.status,
		baseBlob: file.baseBlob ?? file.base?.blob ?? null,
		headBlob: file.headBlob ?? file.head?.blob ?? null,
	})).sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0)));
}

export interface PacketDigestInput {
	repoId: string;
	repoFingerprint: string;
	targetRef: string;
	reviewBaseSha: string;
	headSha: string;
	baseTree: string;
	headTree: string;
	manifestDigest: string;
	scopeDigest: string;
	patchDigest: string;
	planRevisionId: string;
	planDigest: string;
	evidenceId: string;
	evidenceDigest: string;
}

export function packetDigestOf(input: PacketDigestInput): string {
	return digestCanonical({ version: 1, ...input });
}

export function artifactPath(digest: string): string { return `artifacts/sha256/${digest}`; }

export function assertSha(value: string, label: string): void {
	if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value)) throw new Error(`${label} must be a complete commit or tree id`);
}

export function assertDigest(value: string, label: string): void {
	if (!/^[0-9a-f]{64}$/.test(value)) throw new Error(`${label} must be a SHA-256 digest`);
}

/** Command and packet ids become filenames and URL segments, so they stay inside one safe path segment. */
export function assertIdentifier(value: string, label: string): void {
	if (!/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$/.test(value)) throw new Error(`${label} must be a safe identifier`);
}

function assertLineRange(start: number | undefined, end: number | undefined): void {
	if (!Number.isInteger(start) || !Number.isInteger(end) || (start as number) < 1 || (end as number) < (start as number)) throw new Error("comment line range is invalid");
}
