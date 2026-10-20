import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import {
	type Actor,
	artifactPath,
	assertDigest,
	digestContent,
	packetDigestOf,
	scopeDigestOf,
	type Warroom,
} from "./core.ts";
import { captureDigest, captureJson, type CollectedLog, readDrillRun, type DrillCapture } from "./drill-evidence.ts";
import {
	assertRepoPath,
	buildManifest,
	diffPatch,
	GitReadError,
	mergeBase,
	repoFingerprint,
	revParseCommit,
	revParseTree,
	type PacketFileEntry,
} from "./git-read.ts";

/**
 * Review service: the one transactional path from a captured snapshot to a human acceptance.
 *
 * It never writes Git, never runs validation, never answers Drill findings, never publishes to a
 * forge and never emits merge permission. It computes a complete immutable packet, stores its
 * bytes privately by digest, re-checks currentness against the local source before acceptance,
 * and lets the core reject any acceptance that skips these fields, whether it arrives from the
 * review endpoint, the CLI or the generic command API.
 */

export interface CaptureRequest {
	repo: string;
	drillDb: string;
	drillLogs?: string;
	repoId: string;
	runId: string;
	targetRef: string;
	headRef: string;
	planRevisionId: string;
	/**
	 * Operational provenance asserted by whoever names the database. A fixture capture is stored
	 * visibly as a fixture and is always ineligible for human acceptance, so synthetic data can
	 * exercise the flow without ever masquerading as a real Drill result.
	 */
	provenance?: "drill" | "fixture";
}

export interface CaptureResult {
	packetId: string;
	packetDigest: string;
	evidenceId: string;
	evidenceDigest: string;
	manifestDigest: string;
	scopeDigest: string;
	patchDigest: string;
	repoFingerprint: string;
	reviewBaseSha: string;
	headSha: string;
	targetObservedSha: string;
	reused: boolean;
}

export interface PacketFileSide { mode: string; blob: string; size: number; reviewable: boolean; reason?: string; contentDigest?: string | null }
export interface PacketFile { path: string; status: "added" | "modified" | "deleted"; base: PacketFileSide | null; head: PacketFileSide | null }
export interface PacketManifest { version: number; baseSha: string; headSha: string; files: PacketFile[] }

export interface PacketCheck {
	packetId: string;
	status: "ready" | "stale" | "unknown" | "missing" | "corrupt";
	currentness: "verified" | "unverified";
	reasons: string[];
	evidenceEligible: boolean;
	evidenceReasons: string[];
	unreviewableFiles: string[];
	observations: Record<string, unknown>;
	packet?: any;
	capture?: any;
	manifest?: PacketManifest;
}

export class ReviewError extends Error {}

/** Content-addressed private artifact store: write a temporary file, verify, then publish atomically. */
export class ArtifactStore {
	constructor(readonly root: string) {}

	absolutePath(digest: string): string {
		assertDigest(digest, "artifact");
		return join(resolve(this.root), artifactPath(digest));
	}

	write(content: Buffer | string, mediaType: string): { digest: string; byteLength: number; mediaType: string } {
		const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content, "utf8");
		const digest = createHash("sha256").update(bytes).digest("hex");
		const target = this.absolutePath(digest);
		if (!existsSync(target)) {
			mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
			const temporary = `${target}.tmp-${process.pid}`;
			writeFileSync(temporary, bytes, { mode: 0o600 });
			renameSync(temporary, target);
		}
		const stored = statSync(target);
		if (stored.size !== bytes.byteLength) throw new ReviewError("artifact was not stored with its exact bytes");
		return { digest, byteLength: bytes.byteLength, mediaType };
	}

	read(digest: string): Buffer {
		if (!existsSync(this.absolutePath(digest))) throw new ReviewError(`artifact ${digest.slice(0, 12)} is missing`);
		return readFileSync(this.absolutePath(digest));
	}

	readText(digest: string): string { return this.read(digest).toString("utf8"); }

	verify(digest: string, expectedBytes?: number): boolean {
		try {
			const path = this.absolutePath(digest);
			if (!existsSync(path)) return false;
			if (expectedBytes !== undefined && statSync(path).size !== expectedBytes) return false;
			const bytes = readFileSync(path);
			if (expectedBytes !== undefined && bytes.byteLength !== expectedBytes) return false;
			return createHash("sha256").update(bytes).digest("hex") === digest;
		} catch {
			return false;
		}
	}
}

function manifestJson(manifest: PacketManifest): string { return JSON.stringify(manifest); }

function stableIds(input: { initiativeId: string; repoFingerprint: string; repoId: string; runId: string; baseSha: string; headSha: string }) {
	const evidenceId = `ev-${digestContent(JSON.stringify(input)).slice(0, 24)}`;
	return { evidenceId };
}

/**
 * Captures one real Drill-validated change: derives base/head from the named repository objects,
 * requires the Drill row to match the delivered head, stores every immutable byte, then imports
 * the packet through the core's single transactional command path. Repeating it is a no-op.
 */
export function captureReview(warroom: Warroom, dataDir: string, request: CaptureRequest): CaptureResult {
	const repoPath = assertRepoPath(request.repo);
	const headSha = revParseCommit(repoPath, request.headRef);
	const targetObservedSha = revParseCommit(repoPath, request.targetRef);
	let collectedLogs: CollectedLog[] = [];
	const capture = readDrillRun({
		dbPath: request.drillDb,
		runId: request.runId,
		repoId: request.repoId,
		logsRoot: request.drillLogs,
		onLogs: (logs) => { collectedLogs = logs; },
	});
	const provenance = request.provenance ?? "drill";
	if (provenance !== capture.provenance) {
		capture.provenance = provenance;
		if (provenance === "fixture") {
			capture.eligibility = { eligible: false, reasons: [...capture.eligibility.reasons, "fixture capture, not a real Drill execution"] };
		}
	}
	if (capture.run.id !== request.runId) throw new ReviewError("Drill run identity does not match the requested run");
	if (capture.run.deliveredHeadSha !== headSha) throw new ReviewError(`the Drill run delivered ${capture.run.deliveredHeadSha ?? "no head"}, not the requested head ${headSha}`);
	if (capture.run.headSha !== headSha) throw new ReviewError("the Drill run head does not match the requested head ref");
	const reviewBaseSha = mergeBase(repoPath, request.targetRef, headSha);
	const baseTree = revParseTree(repoPath, reviewBaseSha);
	const headTree = revParseTree(repoPath, headSha);
	const store = new ArtifactStore(dataDir);
	const manifest = materializeManifest(repoPath, store, reviewBaseSha, headSha);
	const manifestText = manifestJson(manifest);
	const manifestDigest = digestContent(manifestText);
	const scopeDigest = scopeDigestOf(manifest.files as any);
	const patchBytes = diffPatch(repoPath, reviewBaseSha, headSha);
	const patch = store.write(patchBytes, "text/x-diff");
	store.write(manifestText, "application/json");
	const captureText = captureJson(capture);
	const evidenceDigest = captureDigest(capture);
	store.write(captureText, "application/json");
	const logArtifacts = collectedLogs.map((log) => ({ ...store.write(log.content, "text/plain"), stepName: log.stepName }));

	const state = warroom.state(initiativeOfPlan(warroom, request.planRevisionId));
	const planRevision = state.revisions.find((revision) => revision.id === request.planRevisionId);
	if (!planRevision || planRevision.kind !== "plan") throw new ReviewError("plan revision does not exist");
	if (state.initiative?.currentPlanRevisionId !== planRevision.id) throw new ReviewError("plan revision is not current");
	const repo = repoFingerprint(repoPath);
	const identity = { initiativeId: state.initiative.id, repoFingerprint: repo.fingerprint, repoId: repo.repoId, runId: request.runId, baseSha: reviewBaseSha, headSha };
	const { evidenceId } = stableIds(identity);
	const existingCapture = warroom.db.query("SELECT capture_digest FROM evidence_captures WHERE id=?").get(evidenceId) as { capture_digest: string } | null;
	const effectiveEvidenceDigest = existingCapture?.capture_digest ?? evidenceDigest;
	const packetDigest = packetDigestOf({
		repoId: repo.repoId,
		repoFingerprint: repo.fingerprint,
		targetRef: request.targetRef,
		reviewBaseSha,
		headSha,
		baseTree,
		headTree,
		manifestDigest,
		scopeDigest,
		patchDigest: patch.digest,
		planRevisionId: planRevision.id,
		planDigest: planRevision.digest,
		evidenceId,
		evidenceDigest: effectiveEvidenceDigest,
	});
	const existing = warroom.state(state.initiative.id).packets.find((packet) => packet.packetDigest === packetDigest);
	if (existing) {
		return {
			packetId: existing.id,
			packetDigest,
			evidenceId: existing.evidenceId,
			evidenceDigest: existing.evidenceDigest,
			manifestDigest: existing.manifestDigest,
			scopeDigest: existing.scopeDigest,
			patchDigest: existing.patchDigest,
			repoFingerprint: existing.repoFingerprint,
			reviewBaseSha: existing.reviewBaseSha,
			headSha: existing.headSha,
			targetObservedSha: existing.targetObservedSha ?? targetObservedSha,
			reused: true,
		};
	}
	const codeRevisionId = `rv-${digestContent(`${state.initiative.id}:${manifestDigest}:${headSha}:${reviewBaseSha}`).slice(0, 24)}`;
	const packetId = `pk-${packetDigest.slice(0, 24)}`;
	const artifacts = [
		{ digest: evidenceDigest, byteLength: Buffer.byteLength(captureText, "utf8"), mediaType: "application/json" },
		{ digest: manifestDigest, byteLength: Buffer.byteLength(manifestText, "utf8"), mediaType: "application/json" },
		{ digest: patch.digest, byteLength: patch.byteLength, mediaType: "text/x-diff" },
		...logArtifacts.map((log) => ({ digest: log.digest, byteLength: log.byteLength, mediaType: log.mediaType })),
	];
	for (const file of manifest.files) {
		for (const side of [file.base, file.head]) {
			if (side?.contentDigest) artifacts.push({ digest: side.contentDigest, byteLength: side.size, mediaType: "text/plain" });
		}
	}
	const uniqueArtifacts = uniqueByDigest(artifacts);

	const hasRevision = warroom.db.query("SELECT 1 FROM revisions WHERE id=?").get(codeRevisionId);
	if (!hasRevision) {
		warroom.command({ type: "revision.create", id: codeRevisionId, initiativeId: state.initiative.id, kind: "code", content: manifestText });
	}
	const hasCapture = warroom.db.query("SELECT 1 FROM evidence_captures WHERE id=?").get(evidenceId);
	// A repeated capture of the same run and head is a no-op: the stored bytes stay authoritative.
	if (!hasCapture) {
		warroom.command({
			type: "review.capture.record",
			id: evidenceId,
			initiativeId: state.initiative.id,
			revisionId: codeRevisionId,
			captureId: evidenceId,
			captureVersion: capture.captureVersion,
			captureJson: captureText,
			captureDigest: evidenceDigest,
			provenance,
			runId: capture.run.id,
			repoId: capture.repo.id,
			drillVersion: capture.run.drillVersion,
			drillBuildSha: capture.run.drillBuildSha ?? undefined,
			drillBaseSha: capture.run.baseSha,
			submittedHeadSha: capture.run.submittedHeadSha ?? undefined,
			reviewedHeadSha: capture.run.reviewApprovedHeadSha ?? undefined,
			deliveredHeadSha: headSha,
			runStatus: capture.run.status,
			ciReady: capture.coverage.ci === "ready",
			ciReadyNoCi: capture.coverage.ci === "no-ci",
			eligible: capture.eligibility.eligible,
			ineligibility: capture.eligibility.reasons.join("; ") || undefined,
			capturedAt: capture.capturedAt,
			artifacts: uniqueArtifacts,
		});
	}
	warroom.command({
		type: "review.packet.create",
		id: packetId,
		initiativeId: state.initiative.id,
		revisionId: codeRevisionId,
		evidenceId,
		planRevisionId: planRevision.id,
		repoId: repo.repoId,
		repoFingerprint: repo.fingerprint,
		repoPath,
		targetRef: request.targetRef,
		targetObservedSha,
		headRef: request.headRef,
		reviewBaseSha,
		headSha,
		baseTree,
		headTree,
		manifestDigest,
		patchDigest: patch.digest,
		scopeDigest,
		packetDigest,
	});
	return {
		packetId,
		packetDigest,
		evidenceId,
		evidenceDigest,
		manifestDigest,
		scopeDigest,
		patchDigest: patch.digest,
		repoFingerprint: repo.fingerprint,
		reviewBaseSha,
		headSha,
		targetObservedSha,
		reused: false,
	};
}

function uniqueByDigest<T extends { digest: string }>(items: T[]): T[] {
	const seen = new Map<string, T>();
	for (const item of items) if (!seen.has(item.digest)) seen.set(item.digest, item);
	return [...seen.values()];
}

function materializeManifest(repoPath: string, store: ArtifactStore, baseSha: string, headSha: string): PacketManifest {
	const raw: PacketFileEntry[] = buildManifest(repoPath, baseSha, headSha);
	const files: PacketFile[] = raw.map((file) => ({
		path: file.path,
		status: file.status,
		base: withContent(file.base, store),
		head: withContent(file.head, store),
	}));
	return { version: 1, baseSha, headSha, files };
}

function withContent(side: PacketFileEntry["base"], store: ArtifactStore): PacketFileSide | null {
	if (!side) return null;
	let contentDigest: string | null = null;
	if (side.reviewable) {
		if (!side.content) throw new ReviewError("reviewable object bytes are unavailable");
		contentDigest = store.write(side.content, "text/plain").digest;
	}
	return { mode: side.mode, blob: side.blob, size: side.size, reviewable: side.reviewable, reason: side.reason, contentDigest };
}

export function initiativeOfPlan(warroom: Warroom, planRevisionId: string): string {
	const row = warroom.db.query("SELECT initiative_id FROM revisions WHERE id=?").get(planRevisionId) as { initiative_id: string } | null;
	if (!row) throw new ReviewError("plan revision does not exist");
	return row.initiative_id;
}

export function packetManifest(warroom: Warroom, packet: any): PacketManifest {
	const revision = warroom.db.query("SELECT content FROM revisions WHERE id=?").get(packet.code_revision_id) as { content: string } | null;
	if (!revision) throw new ReviewError("review packet revision is missing");
	return JSON.parse(revision.content) as PacketManifest;
}

export function artifactStoreFor(dataDir: string): ArtifactStore { return new ArtifactStore(dataDir); }

/**
 * Re-derives every immutable identity of a packet, checks artifact bytes, then re-reads the
 * recorded local source. Only a packet whose refs still resolve to the recorded base/head is
 * `verified`; a missing or unreachable source stays `unverified` and blocks new acceptance.
 */
export function checkPacket(warroom: Warroom, dataDir: string, packetId: string): PacketCheck {
	const row = warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(packetId) as any;
	if (!row) return { packetId, status: "unknown", currentness: "unverified", reasons: ["review packet does not exist"], evidenceEligible: false, evidenceReasons: [], unreviewableFiles: [], observations: {} };
	const reasons: string[] = [];
	const evidenceReasons: string[] = [];
	const observations: Record<string, unknown> = { capturedAt: row.created_at, targetRef: row.target_ref, headRef: row.head_ref };
	const store = new ArtifactStore(dataDir);
	let manifest: PacketManifest | undefined;
	let capture: any;
	try {
		manifest = packetManifest(warroom, row);
		const revision = warroom.db.query("SELECT digest, content, initiative_id, kind FROM revisions WHERE id=?").get(row.code_revision_id) as { digest: string; content: string; initiative_id: string; kind: string } | null;
		if (!revision) throw new ReviewError("review packet revision is missing");
		const manifestDigest = digestContent(revision.content);
		if (manifestDigest !== row.manifest_digest) reasons.push("manifest-digest-mismatch");
		if (scopeDigestOf(manifest.files as any) !== row.scope_digest) reasons.push("scope-digest-mismatch");
		if (!store.verify(row.manifest_digest)) reasons.push("manifest-artifact-missing");
		if (!store.verify(row.patch_digest)) reasons.push("patch-artifact-missing");
		if (!store.verify(row.evidence_digest)) reasons.push("evidence-artifact-missing");
		for (const file of manifest.files) {
			for (const [label, side] of [["base", file.base], ["head", file.head]] as const) {
				if (!side) continue;
				if (!side.reviewable) continue;
				if (!side.contentDigest || !store.verify(side.contentDigest, side.size)) reasons.push(`content-artifact-missing:${file.path}:${label}`);
			}
		}
		const evidence = warroom.db.query("SELECT * FROM validation_evidence WHERE id=?").get(row.evidence_id) as any;
		if (!evidence) evidenceReasons.push("evidence-missing");
		else {
			capture = JSON.parse(evidence.capture_id ? (warroom.db.query("SELECT capture_json FROM evidence_captures WHERE id=?").get(evidence.capture_id) as any)?.capture_json ?? "{}" : "{}");
			if (evidence.capture_digest !== row.evidence_digest) reasons.push("evidence-digest-mismatch");
			if (evidence.provenance !== "drill") evidenceReasons.push("evidence-provenance-not-drill");
			if (!evidence.eligible) evidenceReasons.push(`evidence-ineligible:${evidence.ineligibility ?? "unknown"}`);
			if (evidence.delivered_head_sha !== row.head_sha) evidenceReasons.push("evidence-head-mismatch");
			observations.evidence = {
				provenance: evidence.provenance,
				runStatus: evidence.run_status,
				eligible: Boolean(evidence.eligible),
				deliveredHeadSha: evidence.delivered_head_sha,
				drillBaseSha: evidence.drill_base_sha,
				submittedHeadSha: evidence.submitted_head_sha,
				reviewedHeadSha: evidence.reviewed_head_sha,
			};
			for (const log of Array.isArray(capture?.logs) ? capture.logs : []) {
				const byteLength = typeof log?.byteLength === "number" ? log.byteLength : undefined;
				if (!log || typeof log.digest !== "string" || !store.verify(log.digest, byteLength)) reasons.push(`log-artifact-missing:${String(log?.stepName ?? "unknown")}`);
			}
		}
		const planDigest = (warroom.db.query("SELECT digest FROM revisions WHERE id=?").get(row.plan_revision_id) as { digest: string } | null)?.digest;
		if (!planDigest) reasons.push("plan-revision-missing");
		const initiative = warroom.db.query("SELECT current_plan_revision_id FROM initiatives WHERE id=?").get(row.initiative_id) as { current_plan_revision_id: string | null } | null;
		if (initiative?.current_plan_revision_id !== row.plan_revision_id) reasons.push("plan-changed");
		const newer = warroom.db.query("SELECT 1 FROM revisions WHERE initiative_id=? AND kind=? AND rowid > (SELECT rowid FROM revisions WHERE id=?) LIMIT 1").get(revision.initiative_id, revision.kind, row.code_revision_id);
		if (newer) reasons.push("revision-superseded");
		const recomputed = packetDigestOf({
			repoId: row.repo_id,
			repoFingerprint: row.repo_fingerprint,
			targetRef: row.target_ref,
			reviewBaseSha: row.review_base_sha,
			headSha: row.head_sha,
			baseTree: row.base_tree,
			headTree: row.head_tree,
			manifestDigest: row.manifest_digest,
			scopeDigest: row.scope_digest,
			patchDigest: row.patch_digest,
			planRevisionId: row.plan_revision_id,
			planDigest: planDigest ?? "",
			evidenceId: row.evidence_id,
			evidenceDigest: row.evidence_digest,
		});
		if (recomputed !== row.packet_digest) reasons.push("packet-digest-mismatch");
	} catch (error) {
		reasons.push(`unreadable:${(error as Error).message}`);
	}
	if (row.status === "stale") reasons.push(row.stale_reason ?? "packet-superseded");
	observations.packetStatus = row.status;

	const unreviewableFiles = manifest ? manifest.files.filter((file) => (file.base && !file.base.reviewable) || (file.head && !file.head.reviewable)).map((file) => file.path) : [];
	const source = verifySource(row);
	reasons.push(...source.reasons);
	observations.source = source.observations;
	const currentness: "verified" | "unverified" = source.state;
	const sourceOnly = new Set(["source-unknown", "source-unavailable", "source-refs-missing"]);
	const blocking = reasons.filter((reason) => !sourceOnly.has(reason) && !reason.startsWith("source-unreadable:"));
	const corrupt = blocking.some((reason) => ["manifest-digest-mismatch", "scope-digest-mismatch", "manifest-artifact-missing", "patch-artifact-missing", "evidence-artifact-missing", "packet-digest-mismatch"].includes(reason) || reason.startsWith("unreadable:") || reason.startsWith("content-artifact-missing:") || reason.startsWith("log-artifact-missing:"));
	let status: PacketCheck["status"] = "ready";
	if (corrupt) status = "corrupt";
	else if (blocking.length > 0) status = "stale";
	if (row.status === "stale" && status !== "corrupt") status = "stale";
	return { packetId, status, currentness, reasons: [...new Set(reasons)], evidenceEligible: evidenceReasons.length === 0, evidenceReasons: [...new Set(evidenceReasons)], unreviewableFiles, observations, packet: row, capture, manifest };
}

function verifySource(row: any): { state: "verified" | "unverified"; reasons: string[]; observations: Record<string, unknown> } {
	const reasons: string[] = [];
	const repoPath = row.repo_path;
	if (!repoPath) { reasons.push("source-unknown"); return { state: "unverified", reasons, observations: {} }; }
	let repo: string;
	try { repo = assertRepoPath(repoPath); } catch { reasons.push("source-unavailable"); return { state: "unverified", reasons, observations: {} }; }
	if (!row.head_ref || !row.target_ref) { reasons.push("source-refs-missing"); return { state: "unverified", reasons, observations: {} }; }
	try {
		const headNow = revParseCommit(repo, row.head_ref);
		const targetNow = revParseCommit(repo, row.target_ref);
		const baseNow = mergeBase(repo, row.target_ref, headNow);
		const observations = { observedHeadSha: headNow, observedTargetSha: targetNow, observedBaseSha: baseNow, checkedAt: new Date().toISOString() };
		if (headNow !== row.head_sha) reasons.push("head-moved");
		if (baseNow !== row.review_base_sha) reasons.push("base-moved");
		if (!row.target_observed_sha || targetNow !== row.target_observed_sha) reasons.push("target-moved");
		return { state: reasons.length === 0 ? "verified" : "unverified", reasons, observations };
	} catch (error) {
		if (error instanceof GitReadError) { reasons.push(`source-unreadable:${error.message}`); return { state: "unverified", reasons, observations: {} }; }
		throw error;
	}
}

export interface AcceptanceRequest {
	packetId: string;
	packetDigest: string;
	scopeDigest: string;
	declaration: string;
	actorConfirmed: boolean;
}

/** The only acceptance path: currentness is re-verified against the source immediately before the command. */
export function acceptReview(warroom: Warroom, dataDir: string, request: AcceptanceRequest): { check: PacketCheck; approvalId: string } {
	const check = checkPacket(warroom, dataDir, request.packetId);
	if (check.status !== "ready") throw new ReviewError(`review packet is not acceptable: ${check.reasons.join(", ") || check.status}`);
	if (check.currentness !== "verified") throw new ReviewError(`review packet currentness is unverified: ${check.reasons.join(", ") || "source unavailable"}`);
	if (!check.evidenceEligible) throw new ReviewError(`review packet evidence is not eligible: ${check.evidenceReasons.join(", ")}`);
	if (check.unreviewableFiles.length > 0) throw new ReviewError(`review packet contains objects that cannot be reviewed: ${check.unreviewableFiles.join(", ")}`);
	if (request.packetDigest !== check.packet.packet_digest) throw new ReviewError("acceptance packet digest does not match the current snapshot");
	if (request.scopeDigest !== check.packet.scope_digest) throw new ReviewError("acceptance must cover the complete packet scope");
	if (!request.declaration.trim()) throw new ReviewError("acceptance requires an explicit declaration");
	if (!request.actorConfirmed) throw new ReviewError("acceptance requires explicit human confirmation");
	const approvalCount = (warroom.db.query("SELECT COUNT(*) AS n FROM approvals").get() as { n: number }).n;
	const approvalId = `ap-${digestContent(`${check.packet.packet_digest}:${approvalCount}`).slice(0, 24)}`;
	warroom.command({
		type: "approval.record",
		id: approvalId,
		initiativeId: check.packet.initiative_id,
		kind: "code-review-acceptance",
		revisionId: check.packet.code_revision_id,
		decision: "approved",
		evidenceId: check.packet.evidence_id,
		packetId: check.packet.id,
		packetDigest: check.packet.packet_digest,
		evidenceDigest: check.packet.evidence_digest,
		scopeDigest: check.packet.scope_digest,
		declaration: request.declaration,
		actorConfirmed: true,
		currentness: {
			verified: true,
			checkedAt: String((check.observations.source as any)?.checkedAt ?? new Date().toISOString()),
			headSha: check.packet.head_sha,
			baseSha: check.packet.review_base_sha,
		},
	});
	return { check, approvalId };
}

export function requestReviewChanges(warroom: Warroom, dataDir: string, request: AcceptanceRequest): { check: PacketCheck; approvalId: string } {
	const check = checkPacket(warroom, dataDir, request.packetId);
	if (check.status === "corrupt" || check.status === "unknown" || check.status === "missing") throw new ReviewError(`review packet is not reviewable: ${check.reasons.join(", ") || check.status}`);
	if (check.packet.status === "stale") throw new ReviewError("review packet is stale; request changes on the current snapshot");
	if (request.packetDigest !== check.packet.packet_digest) throw new ReviewError("request packet digest does not match the current snapshot");
	if (!request.declaration.trim()) throw new ReviewError("a change request requires an explicit declaration");
	const approvalCount = (warroom.db.query("SELECT COUNT(*) AS n FROM approvals").get() as { n: number }).n;
	const approvalId = `ap-${digestContent(`${check.packet.packet_digest}:changes:${approvalCount}`).slice(0, 24)}`;
	warroom.command({
		type: "approval.record",
		id: approvalId,
		initiativeId: check.packet.initiative_id,
		kind: "code-review-acceptance",
		revisionId: check.packet.code_revision_id,
		decision: "changes-requested",
		evidenceId: check.packet.evidence_id,
		packetId: check.packet.id,
		packetDigest: check.packet.packet_digest,
		evidenceDigest: check.packet.evidence_digest,
		scopeDigest: check.packet.scope_digest,
		declaration: request.declaration,
		actorConfirmed: request.actorConfirmed,
	});
	return { check, approvalId };
}

export interface CommentRequest {
	packetId: string;
	targetType: "plan-range" | "diagram-node" | "code-range" | "review";
	revisionId?: string;
	path?: string;
	side?: "base" | "head";
	startLine?: number;
	endLine?: number;
	blobSha?: string;
	context?: string;
	kind: "comment" | "suggestion";
	suggestion?: string;
	body: string;
}

/** Comments are stored text anchored to an immutable snapshot; they never touch repository content. */
export function anchorComment(warroom: Warroom, dataDir: string, request: CommentRequest): string {
	const packet = warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(request.packetId) as any;
	if (!packet) throw new ReviewError("review packet does not exist");
	if (packet.status === "stale") throw new ReviewError("review packet is stale; comments stay on their own snapshot");
	const manifest = packetManifest(warroom, packet);
	const revisionId = request.revisionId ?? packet.code_revision_id;
	if (!request.body || !request.body.trim()) throw new ReviewError("a comment requires its text");
	if (request.targetType === "code-range") {
		const file = manifest.files.find((item) => item.path === request.path);
		if (!file) throw new ReviewError("comment path is not part of the review packet manifest");
		const side = file[request.side ?? "head"];
		if (!side || !side.reviewable) throw new ReviewError("that object is not reviewable on the requested side");
		if (side.blob !== request.blobSha) throw new ReviewError("comment blob does not match the packet object");
		const text = side.contentDigest ? new ArtifactStore(dataDir).readText(side.contentDigest) : null;
		if (text !== null) {
			const lineCount = text === "" ? 0 : text.split("\n").length;
			if (!request.startLine || !request.endLine || request.startLine < 1 || request.endLine < request.startLine || request.endLine > lineCount) throw new ReviewError("comment line range is out of bounds for this object");
		}
	}
	const commentId = `cm-${digestContent(JSON.stringify({ packet: packet.packet_digest, path: request.path ?? null, start: request.startLine ?? null, body: request.body, at: Date.now() })).slice(0, 24)}`;
	warroom.command({
		type: "comment.add",
		id: commentId,
		initiativeId: packet.initiative_id,
		revisionId,
		body: request.body,
		targetType: request.targetType,
		packetId: packet.id,
		path: request.path,
		side: request.side,
		startLine: request.startLine,
		endLine: request.endLine,
		blobSha: request.blobSha,
		context: request.context,
		snapshotDigest: packet.packet_digest,
		kind: request.kind,
		suggestion: request.suggestion,
	});
	return commentId;
}

export function resolveComment(warroom: Warroom, commentId: string): void {
	const comment = warroom.db.query("SELECT initiative_id FROM comments WHERE id=?").get(commentId) as { initiative_id: string } | null;
	if (!comment) throw new ReviewError("comment does not exist");
	warroom.command({ type: "comment.resolve", initiativeId: comment.initiative_id, commentId });
}

export function supersedePacket(warroom: Warroom, packetId: string, reason: string, replacementId?: string): void {
	const packet = warroom.db.query("SELECT initiative_id FROM review_packets WHERE id=?").get(packetId) as { initiative_id: string } | null;
	if (!packet) throw new ReviewError("review packet does not exist");
	warroom.command({ type: "review.supersede", initiativeId: packet.initiative_id, packetId, reason, supersededBy: replacementId });
}

/** File bytes for one manifest path and side: exact stored object bytes, looked up by manifest identity only. */
export function readPacketFile(warroom: Warroom, dataDir: string, packetId: string, path: string, side: "base" | "head"): { file: PacketFile; side: "base" | "head"; text: string; lineCount: number } {
	const packet = warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(packetId) as any;
	if (!packet) throw new ReviewError("review packet does not exist");
	const manifest = packetManifest(warroom, packet);
	const file = manifest.files.find((item) => item.path === path);
	if (!file) throw new ReviewError("path is not part of the review packet manifest");
	const object = file[side];
	if (!object || !object.reviewable || !object.contentDigest) throw new ReviewError("object is not reviewable on the requested side");
	const text = new ArtifactStore(dataDir).readText(object.contentDigest);
	return { file, side, text, lineCount: text === "" ? 0 : text.split("\n").length };
}

export function listPacketFiles(warroom: Warroom, packetId: string): PacketFile[] {
	const packet = warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(packetId) as any;
	if (!packet) throw new ReviewError("review packet does not exist");
	return packetManifest(warroom, packet).files;
}

export function evidenceCapture(warroom: Warroom, packet: any): DrillCapture | null {
	const row = warroom.db.query("SELECT capture_json FROM evidence_captures WHERE id=?").get(packet.evidence_id) as { capture_json: string } | null;
	return row ? (JSON.parse(row.capture_json) as DrillCapture) : null;
}
