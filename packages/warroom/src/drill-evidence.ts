import { createHash } from "node:crypto";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { Database } from "bun:sqlite";
import { canonicalJson } from "./core.ts";
import { redactUrl } from "./git-read.ts";

/**
 * Restricted, read-only reader for one explicitly named Drill run.
 *
 * This is a private, versioned adaptation of Drill's internal SQLite schema, not a Drill API,
 * not a Drill replacement, and not a second validation authority. It opens the database with
 * `readonly: true`, never runs DDL/DML/checkpoint/VACUUM, never changes the file, never runs a
 * validation step, and only copies what the named run recorded. Coverage claims are limited to
 * what those rows actually say: a skipped step is never a success, an absent exit code is never
 * zero, and a running CI monitor is not a green check.
 */

export const CAPTURE_VERSION = 1;

export interface DrillCaptureStep {
	name: string;
	order: number;
	status: string;
	exitCode: number | null;
	skipped: boolean;
	startedAt: number | null;
	completedAt: number | null;
	logRecorded: boolean;
}

export interface DrillCaptureRound {
	stepName: string;
	round: number;
	triggerType: string;
	reviewedHeadSha: string | null;
}

export interface DrillCapture {
	captureVersion: number;
	capturedAt: string;
	provenance: "drill" | "manual" | "fixture";
	source: { kind: "drill-sqlite"; database: string };
	repo: { id: string; workingPath: string; upstreamUrl: string | null; defaultBranch: string | null };
	run: {
		id: string;
		repoId: string;
		branch: string;
		headSha: string;
		baseSha: string;
		submittedHeadSha: string | null;
		reviewApprovedHeadSha: string | null;
		deliveredHeadSha: string | null;
		status: string;
		drillVersion: string;
		drillBuildSha: string | null;
		prUrl: string | null;
		prState: string | null;
		ciReadyAt: number | null;
		ciReadyNoCi: boolean;
		lastPushedSha: string | null;
		awaitingAgentSince: number | null;
		createdAt: number;
		updatedAt: number;
	};
	steps: DrillCaptureStep[];
	rounds: DrillCaptureRound[];
	coverage: { ci: "ready" | "no-ci" | "not-ready"; reviewHead: "recorded" | "absent"; stepsSkipped: string[] };
	eligibility: { eligible: boolean; reasons: string[] };
	logs: Array<{ stepName: string; digest: string; byteLength: number; logPath: string }>;
}

export interface DrillCaptureOptions {
	/** Path to the Drill `state.sqlite` supplied by the run owner. */
	dbPath: string;
	runId: string;
	repoId: string;
	/** Optional authorized logs root; logs outside it are never read. */
	logsRoot?: string;
	now?: Date;
	maxLogBytes?: number;
	/** Receives the exact log bytes whose digests the capture records, so callers store those same bytes. */
	onLogs?: (logs: CollectedLog[]) => void;
}

export interface CollectedLog { stepName: string; digest: string; byteLength: number; logPath: string; content: Buffer }

const REQUIRED_TABLES = ["repos", "runs", "step_results", "step_rounds"];
const REQUIRED_RUN_COLUMNS = [
	"id", "repo_id", "branch", "head_sha", "base_sha", "submitted_head_sha", "drill_version", "drill_build_sha",
	"review_approved_head_sha", "status", "pr_url", "pr_state", "ci_ready_at", "ci_ready_no_ci", "last_pushed_sha",
	"awaiting_agent_since", "created_at", "updated_at",
];

/** Every pipeline step before the pull-request/CI monitor must be recorded; a missing row is not a success. */
const REQUIRED_PRE_CI_STEPS = ["intent", "rebase", "review", "test", "document", "lint", "push", "pr"];
const TERMINAL_FAILURES = new Set(["failed", "cancelled", "canceled", "error", "aborted"]);
const ELIGIBLE_RUN_STATUSES = new Set(["pending", "running", "completed"]);

export class DrillEvidenceError extends Error {}

function openReadOnly(dbPath: string): Database {
	let resolved: string;
	try { resolved = realpathSync(dbPath); } catch { throw new DrillEvidenceError("Drill database does not exist"); }
	if (!statSync(resolved).isFile()) throw new DrillEvidenceError("Drill database is not a file");
	let db: Database;
	try {
		db = new Database(resolved, { readonly: true, create: false });
	} catch (error) {
		throw new DrillEvidenceError(`Drill database cannot be opened read-only: ${(error as Error).message}`);
	}
	return db;
}

function tableColumns(db: Database, table: string): string[] {
	const rows = db.query(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>;
	return rows.map((row) => row.name);
}

function assertSupportedSchema(db: Database): void {
	for (const table of REQUIRED_TABLES) {
		const columns = tableColumns(db, table);
		if (columns.length === 0) throw new DrillEvidenceError(`unsupported Drill database format: missing table ${table}`);
	}
	const runColumns = tableColumns(db, "runs");
	const missing = REQUIRED_RUN_COLUMNS.filter((column) => !runColumns.includes(column));
	if (missing.length > 0) throw new DrillEvidenceError(`unsupported Drill database format: runs is missing ${missing.join(", ")}`);
}

function assertShaOrNull(value: unknown, label: string): string | null {
	if (value === null || value === undefined) return null;
	if (typeof value !== "string" || !/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value)) throw new DrillEvidenceError(`unsupported Drill database format: ${label} is not a complete object id`);
	return value;
}

/** Reads exactly one run row and its recorded steps/rounds. Never scans, sorts by recency, or picks a run. */
export function readDrillRun(options: DrillCaptureOptions): DrillCapture {
	const now = options.now ?? new Date();
	const db = openReadOnly(options.dbPath);
	try {
		assertSupportedSchema(db);
		const repo = db.query("SELECT id, working_path, upstream_url, default_branch FROM repos WHERE id = ?").get(options.repoId) as any;
		if (!repo) throw new DrillEvidenceError(`Drill repository ${options.repoId} does not exist in the named database`);
		const run = db.query("SELECT * FROM runs WHERE id = ? AND repo_id = ?").get(options.runId, options.repoId) as any;
		if (!run) throw new DrillEvidenceError(`Drill run ${options.runId} does not belong to repository ${options.repoId}`);

		const headSha = assertShaOrNull(run.head_sha, "head_sha")!;
		const baseSha = assertShaOrNull(run.base_sha, "base_sha")!;
		const submittedHeadSha = assertShaOrNull(run.submitted_head_sha, "submitted_head_sha");
		const reviewApprovedHeadSha = assertShaOrNull(run.review_approved_head_sha, "review_approved_head_sha");
		const lastPushedSha = assertShaOrNull(run.last_pushed_sha, "last_pushed_sha");

		const stepRows = db.query("SELECT step_name, step_order, status, exit_code, log_path, started_at, completed_at FROM step_results WHERE run_id = ? ORDER BY step_order, rowid").all(options.runId) as any[];
		const roundRows = db.query(`SELECT r.step_name AS step_name, s.round AS round, s.trigger_type AS trigger_type, s.reviewed_head_sha AS reviewed_head_sha
			FROM step_rounds s JOIN step_results r ON r.id = s.step_result_id WHERE r.run_id = ? ORDER BY r.step_order, s.round`).all(options.runId) as any[];

		const steps: DrillCaptureStep[] = stepRows.map((row) => ({
			name: String(row.step_name),
			order: Number(row.step_order),
			status: String(row.status),
			exitCode: typeof row.exit_code === "number" ? row.exit_code : null,
			skipped: String(row.status) === "skipped",
			startedAt: typeof row.started_at === "number" ? row.started_at : null,
			completedAt: typeof row.completed_at === "number" ? row.completed_at : null,
			logRecorded: typeof row.log_path === "string" && row.log_path.length > 0,
		}));
		const rounds: DrillCaptureRound[] = roundRows.map((row) => ({
			stepName: String(row.step_name),
			round: Number(row.round),
			triggerType: String(row.trigger_type),
			reviewedHeadSha: assertShaOrNull(row.reviewed_head_sha, "round reviewed_head_sha"),
		}));

		const reasons: string[] = [];
		if (!ELIGIBLE_RUN_STATUSES.has(String(run.status))) reasons.push(`run status ${String(run.status)} is not eligible`);
		if (run.awaiting_agent_since !== null && run.awaiting_agent_since !== undefined) reasons.push("run is waiting on an agent decision");
		if (run.ci_ready_at === null || run.ci_ready_at === undefined) {
			if (Number(run.ci_ready_no_ci) !== 1) reasons.push("CI readiness was not recorded");
		}
		if (!lastPushedSha) reasons.push("delivered head was not recorded");
		else if (lastPushedSha !== headSha) reasons.push("delivered head does not match the run head");
		if (!submittedHeadSha) reasons.push("submitted head was not recorded");
		if (!run.pr_url) reasons.push("no pull request was observed");
		if (run.pr_state === "merged" || run.pr_state === "closed") reasons.push(`pull request is ${String(run.pr_state)}`);
		const present = new Set(steps.map((step) => step.name));
		for (const required of REQUIRED_PRE_CI_STEPS) if (!present.has(required)) reasons.push(`step ${required} was not recorded`);
		if (run.ci_ready_at !== null && run.ci_ready_at !== undefined && !present.has("ci")) reasons.push("CI readiness was recorded without a ci step");
		const skipped = steps.filter((step) => step.skipped).map((step) => step.name);
		const failed = steps.filter((step) => TERMINAL_FAILURES.has(step.status));
		for (const step of failed) reasons.push(`step ${step.name} is ${step.status}`);
		// The CI step monitors the pull request after readiness; it is expected to keep running until merge or close.
		// Every other step must be finished, because an unfinished earlier step means the recorded run is incomplete.
		const unfinished = steps.filter((step) => step.name !== "ci" && !step.skipped && !["completed"].includes(step.status));
		for (const step of unfinished) reasons.push(`step ${step.name} is ${step.status}, not completed`);

		const logs = collectLogs(options.logsRoot, stepRows, options.maxLogBytes ?? 1024 * 1024);
		options.onLogs?.(logs);
		const capture: DrillCapture = {
			captureVersion: CAPTURE_VERSION,
			capturedAt: now.toISOString(),
			provenance: "drill",
			source: { kind: "drill-sqlite", database: "state.sqlite" },
			repo: {
				id: String(repo.id),
				workingPath: String(repo.working_path),
				upstreamUrl: typeof repo.upstream_url === "string" ? redactUrl(repo.upstream_url) : null,
				defaultBranch: typeof repo.default_branch === "string" ? repo.default_branch : null,
			},
			run: {
				id: String(run.id),
				repoId: String(run.repo_id),
				branch: String(run.branch),
				headSha,
				baseSha,
				submittedHeadSha,
				reviewApprovedHeadSha,
				deliveredHeadSha: lastPushedSha,
				status: String(run.status),
				drillVersion: String(run.drill_version ?? "unknown"),
				drillBuildSha: typeof run.drill_build_sha === "string" ? run.drill_build_sha : null,
				prUrl: typeof run.pr_url === "string" ? run.pr_url : null,
				prState: typeof run.pr_state === "string" ? run.pr_state : null,
				ciReadyAt: typeof run.ci_ready_at === "number" ? run.ci_ready_at : null,
				ciReadyNoCi: Number(run.ci_ready_no_ci) === 1,
				lastPushedSha,
				awaitingAgentSince: typeof run.awaiting_agent_since === "number" ? run.awaiting_agent_since : null,
				createdAt: Number(run.created_at),
				updatedAt: Number(run.updated_at),
			},
			steps,
			rounds,
			coverage: {
				ci: run.ci_ready_at !== null && run.ci_ready_at !== undefined ? "ready" : Number(run.ci_ready_no_ci) === 1 ? "no-ci" : "not-ready",
				reviewHead: reviewApprovedHeadSha ? "recorded" : "absent",
				stepsSkipped: skipped,
			},
			eligibility: { eligible: reasons.length === 0, reasons },
			logs: logs.map(({ stepName, digest, byteLength, logPath }) => ({ stepName, digest, byteLength, logPath })),
		};
		return capture;
	} finally {
		db.close();
	}
}

/**
 * Copies only logs that live under the explicitly authorized logs root, refuses symlinks that
 * escape it, and bounds every file. Log content is returned for artifact storage; the capture
 * itself keeps only the digest, size and original path.
 */
export function collectLogs(logsRoot: string | undefined, stepRows: any[], maxBytes: number): CollectedLog[] {
	if (!logsRoot) return [];
	let root: string;
	try { root = realpathSync(logsRoot); } catch { return []; }
	const collected: CollectedLog[] = [];
	for (const row of stepRows) {
		if (typeof row.log_path !== "string" || !row.log_path) continue;
		let resolved: string;
		try { resolved = realpathSync(row.log_path); } catch { continue; }
		if (!(resolved === root || resolved.startsWith(`${root}/`))) continue;
		let stat;
		try { stat = statSync(resolved); } catch { continue; }
		if (!stat.isFile() || stat.size > maxBytes) continue;
		let content: Buffer;
		try { content = readFileSync(resolved); } catch { continue; }
		collected.push({
			stepName: String(row.step_name),
			digest: createHash("sha256").update(content).digest("hex"),
			byteLength: content.byteLength,
			logPath: resolved,
			content,
		});
	}
	return collected;
}

export function captureJson(capture: DrillCapture): string {
	return canonicalJson(capture);
}

export function captureDigest(capture: DrillCapture): string {
	return createHash("sha256").update(captureJson(capture), "utf8").digest("hex");
}

/** Rejects a capture whose bytes and claimed digest disagree, or whose shape is not capture v1. */
export function verifyCaptureJson(json: string, expectedDigest: string): DrillCapture {
	let parsed: any;
	try { parsed = JSON.parse(json); } catch { throw new DrillEvidenceError("evidence capture is not valid JSON"); }
	if (parsed?.captureVersion !== CAPTURE_VERSION) throw new DrillEvidenceError("unsupported evidence capture version");
	if (createHash("sha256").update(json, "utf8").digest("hex") !== expectedDigest) throw new DrillEvidenceError("evidence capture digest does not match its content");
	return parsed as DrillCapture;
}

