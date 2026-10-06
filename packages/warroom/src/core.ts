import { createHash, randomUUID } from "node:crypto";
import { Database } from "bun:sqlite";
import { type DiffLine, lineDiff } from "./diff.ts";
import { migrate } from "./schema.ts";
import { buildTimeline, type TimelineEntry } from "./timeline.ts";

export type ApprovalKind = "plan-approval" | "execution-authorization" | "code-review-acceptance" | "merge-permission";
export type Command =
	| { type: "initiative.create"; id?: string; title: string; workingName?: string }
	| { type: "revision.create"; id?: string; initiativeId: string; kind: "plan" | "code"; content: string }
	| { type: "decision.record"; id?: string; initiativeId: string; revisionId: string; statement: string; rationale: string; selectedAlternatives?: string[] }
	| { type: "approval.record"; id?: string; initiativeId: string; kind: ApprovalKind; revisionId: string; decision: "approved" | "rejected" | "changes-requested"; evidenceId?: string }
	| { type: "comment.add"; id?: string; initiativeId: string; revisionId: string; body: string }
	| { type: "validation.record"; id?: string; initiativeId: string; revisionId: string; provider: string; result: string }
	| { type: "question.ask"; id?: string; initiativeId: string; revisionId: string; prompt: string; context?: string }
	| { type: "question.answer"; id?: string; initiativeId: string; questionId: string; answer: string };

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
		const decisions: any[] = [], approvals: any[] = [], comments: any[] = [], evidence: any[] = [], questions: any[] = [];
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
				for (const c of comments) if (c.revisionId !== p.id && revisions.get(c.revisionId)?.stale) c.state = "outdated";
				for (const e of evidence) if (e.revisionId !== p.id && revisions.get(e.revisionId)?.stale) e.stale = true;
				for (const q of questions) if (q.revisionId !== p.id && revisions.get(q.revisionId)?.stale) q.status = "outdated";
				break;
			}
			case "decision.record": decisions.push({ ...p, sourceRevisionId: p.revisionId }); break;
			case "approval.record": approvals.push({ ...p, superseded: false, subjectDigest: revisions.get(p.revisionId).digest }); break;
			case "comment.add": comments.push({ ...p, state: "open" }); break;
			case "validation.record": evidence.push({ ...p, digest: revisions.get(p.revisionId).digest, stale: false }); break;
			case "question.ask": questions.push({ ...p, status: "open" }); break;
			case "question.answer": {
				const question = questions.find((item) => item.id === p.questionId);
				if (question) { question.status = "answered"; question.answer = p.answer; question.answeredBy = event.actor; question.answeredAt = event.occurred_at; }
				break;
			}
			}
		}
		return { initiative: initiatives.get(initiativeId), revisions: [...revisions.values()], decisions, approvals, comments, evidence, questions };
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

	close(): void { this.db.close(); }

	private validate(command: Command): void {
		if (command.type === "initiative.create") return;
		const state = this.state(command.initiativeId);
		if (!state.initiative) throw new Error("initiative does not exist");
		if (command.type === "revision.create") return;
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
				const setClause = table === "comments" ? "state='outdated'" : table === "questions" ? "status='outdated'" : "stale=1";
				this.db.query(`UPDATE ${table} SET ${setClause} WHERE initiative_id=? AND revision_id IN (SELECT id FROM revisions WHERE initiative_id=? AND kind=? AND id<>?)`).run(command.initiativeId, command.initiativeId, command.kind, id);
			}
			break;
		}
		case "decision.record": this.db.query("INSERT INTO decisions(id,initiative_id,source_revision_id,statement,rationale,selected_alternatives,decided_by,decided_at) VALUES(?,?,?,?,?,?,?,?)").run(id, command.initiativeId, command.revisionId, command.statement, command.rationale, JSON.stringify(command.selectedAlternatives ?? []), this.actor.id, now); break;
		case "approval.record": this.db.query("INSERT INTO approvals(id,initiative_id,kind,subject_revision_id,subject_digest,evidence_revision_id,decision,actor,created_at) VALUES(?,?,?,?,?,?,?,?,?)").run(id, command.initiativeId, command.kind, command.revisionId, digestContent(this.revisionContent(command.revisionId)), command.evidenceId || null, command.decision, this.actor.id, now); break;
		case "comment.add": this.db.query("INSERT INTO comments(id,initiative_id,revision_id,body,state,created_by,created_at) VALUES(?,?,?,?,'open',?,?)").run(id, command.initiativeId, command.revisionId, command.body, this.actor.id, now); break;
		case "validation.record": this.db.query("INSERT INTO validation_evidence(id,initiative_id,revision_id,digest,provider,result,captured_at,stale) VALUES(?,?,?,?,?,?,?,0)").run(id, command.initiativeId, command.revisionId, digestContent(this.revisionContent(command.revisionId)), command.provider, command.result, now); break;
		case "question.ask": this.db.query("INSERT INTO questions(id,initiative_id,revision_id,prompt,context,status,created_by,created_at) VALUES(?,?,?,?,?,'open',?,?)").run(id, command.initiativeId, command.revisionId, command.prompt, command.context ?? "", this.actor.id, now); break;
		case "question.answer": this.db.query("UPDATE questions SET status='answered', answer=?, answered_by=?, answered_at=? WHERE id=?").run(command.answer, this.actor.id, now, command.questionId); break;
		}
	}

	private revisionContent(id: string): string { return (this.db.query("SELECT content FROM revisions WHERE id=?").get(id) as { content: string }).content; }
}

export function digestContent(content: string): string { return createHash("sha256").update(content, "utf8").digest("hex"); }
