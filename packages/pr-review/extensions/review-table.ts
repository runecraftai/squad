/**
 * review-table
 *
 * Renders the /pr-review final JSON response as a readable TUI review and owns
 * configured GitHub publication after valid final JSON. Publishing is bound to raw
 * invocation flags/config, validates current PR state and anchors, and can emit only
 * one formal COMMENT review with associated inline comments.
 *
 * Rendering only rewrites interactive TUI output. Print/json/rpc modes retain raw JSON.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import {
	CONFIG_DIR_NAME,
	type ExtensionAPI,
	type ExtensionContext,
	getAgentDir,
} from "@earendil-works/pi-coding-agent";
import {
	classifyAssistantCompletion,
	COMPLETED_REVIEW_BRANCH_ANCHOR_TYPE,
	COMPLETED_REVIEW_ENTRY_TYPE,
	CompletedReviewCache,
	decideReviewPublication,
	isNonOpenConfirmationPrompt,
	parseDirectPublishRequest,
	parsePublishExistingArgs,
	parsePublishMode,
	parsePublishableReview,
	publishPullReview,
	publishPullReviewBody,
	resolveAllowStaleApprovalsSetting,
	resolveAllowStalePublishSetting,
	resolveAutoPostSetting,
	resolveApproveMaxPriorityLevelSetting,
	resolveRepositoryBinding,
	restoreCompletedReviewBranch,
	shouldPublishReview,
	validateReviewInvocation,
	type AutoPostResolution,
	type ApproveMaxPriorityLevelResolution,
	type CompletedReviewRecord,
	type CompletedReviewSessionIdentity,
	type ReviewInvocation,
} from "../lib/pr-review-publish.ts";
import {
	ReviewLoopCoordinator,
	type ReviewLoopInputSource,
} from "../lib/pr-review-loop.ts";
import { SelfReviewPermitCoordinator } from "../lib/pr-self-review.ts";
import {
	ReviewTelemetryTracker,
	type ReviewPerformanceTelemetry,
} from "../lib/pr-review-telemetry.ts";

type Severity = "P0" | "P1" | "P2" | "P3" | "nit";

interface Finding {
	title?: string;
	body?: string;
	severity?: string;
	blocking?: boolean;
	confidence_score?: number;
	priority?: number | null;
	code_location?: {
		absolute_file_path?: string | null;
		line_range?: { start?: number; end?: number };
		side?: string | null;
		commentable?: boolean;
	} | null;
}

interface Review {
	pr?: { number?: number | null; title?: string | null; head_sha?: string | null } | null;
	disposition?: "reviewed" | "skipped";
	verification?: string;
	overview?: string;
	strengths?: string[];
	findings: Finding[];
	notes?: { correctness?: string; security?: string; performance?: string } | null;
	verdict?: string;
	overall_correctness?: string;
	overall_explanation?: string;
	overall_confidence_score?: number;
}

type MessagePart = { type: string; text?: string };
type ReviewOutputRepair = (
	text: string,
	outputContract: string,
	ctx: Pick<ExtensionContext, "cwd" | "isProjectTrusted">,
	signal?: AbortSignal,
) => Promise<string | undefined>;

type ReviewOutputFallbackPayload = (
	text: string,
	reviewedHeadSha: string,
	ctx: Pick<ExtensionContext, "cwd" | "isProjectTrusted">,
	signal?: AbortSignal,
) => Promise<{ commit_id: string; event: "COMMENT"; body: string } | undefined>;

const defaultReviewOutputRepair: ReviewOutputRepair = async (...args) => {
	const { repairReviewOutput } = await import("./pr-review-subagent.ts");
	return repairReviewOutput(...args);
};

const defaultReviewOutputFallbackPayload: ReviewOutputFallbackPayload = async (...args) => {
	const { prepareReviewOutputGhPayload } = await import("./pr-review-subagent.ts");
	return prepareReviewOutputGhPayload(...args);
};

const OWN_REVIEW_PROMPT = fs.realpathSync(
	fileURLToPath(new URL("../prompts/pr-review.md", import.meta.url)),
);
const REVIEW_PROMPT_TEXT = fs.readFileSync(OWN_REVIEW_PROMPT, "utf8");
const REVIEW_OUTPUT_CONTRACT = REVIEW_PROMPT_TEXT.slice(REVIEW_PROMPT_TEXT.indexOf("## OUTPUT FORMAT"));

function isOwnReviewPrompt(pi: Pick<ExtensionAPI, "getCommands">): boolean {
	try {
		return pi.getCommands().some((command) => {
			if (command.name !== "pr-review" || command.source !== "prompt") return false;
			try {
				return fs.realpathSync(command.sourceInfo.path) === OWN_REVIEW_PROMPT;
			} catch {
				return false;
			}
		});
	} catch {
		return false;
	}
}

function assistantText(message: { content?: MessagePart[] }): string {
	if (!Array.isArray(message.content)) return "";
	return message.content
		.filter((p) => p.type === "text" && typeof p.text === "string")
		.map((p) => p.text as string)
		.join("");
}

function hasToolCall(message: { content?: MessagePart[] }): boolean {
	return Array.isArray(message.content) && message.content.some((p) => p.type === "toolCall");
}

/** Extract the balanced {...} object starting at index `start` (string-literal aware). */
function sliceBalancedFrom(s: string, start: number): string | null {
	let depth = 0;
	let inStr = false;
	let esc = false;
	for (let i = start; i < s.length; i++) {
		const c = s[i];
		if (inStr) {
			if (esc) esc = false;
			else if (c === "\\") esc = true;
			else if (c === '"') inStr = false;
			continue;
		}
		if (c === '"') inStr = true;
		else if (c === "{") depth++;
		else if (c === "}") {
			depth--;
			if (depth === 0) return s.slice(start, i + 1);
		}
	}
	return null;
}

function isReviewShape(v: unknown): v is Review {
	if (!v || typeof v !== "object") return false;
	const r = v as Review;
	return Array.isArray(r.findings) && (typeof r.overall_correctness === "string" || typeof r.verdict === "string");
}

/**
 * Find the review JSON even if the model wrapped it in fences or prepended prose
 * that itself contains braces. Scans every `{` in each source and returns the LAST
 * valid review-shaped object (the real payload is normally last).
 */
function parseReview(text: string): Review | null {
	const sources: string[] = [];
	const fenceRe = /```(?:json)?\s*([\s\S]*?)```/gi;
	for (let m = fenceRe.exec(text); m; m = fenceRe.exec(text)) {
		if (m[1]) sources.push(m[1]);
	}
	sources.push(text);

	let best: Review | null = null;
	for (const src of sources) {
		for (let i = 0; i < src.length; i++) {
			if (src[i] !== "{") continue;
			const objStr = sliceBalancedFrom(src, i);
			if (!objStr) continue;
			try {
				const parsed = JSON.parse(objStr);
				if (isReviewShape(parsed)) best = parsed;
			} catch {
				/* not JSON starting here; keep scanning */
			}
		}
		if (best) return best; // prefer a match from an earlier (more specific) source
	}
	return best;
}

function fallbackReviewedHead(prNumber: number, ...sources: Array<string | undefined>): string | undefined {
	for (const source of sources) {
		if (!source) continue;
		const candidate = parseReview(source);
		const headSha = candidate?.pr?.head_sha;
		if (
			candidate?.pr?.number === prNumber &&
			typeof headSha === "string" &&
			/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(headSha)
		) {
			return headSha.toLowerCase();
		}
	}
	return undefined;
}

const SEVERITY_RANK: Record<Severity, number> = { P0: 0, P1: 1, P2: 2, P3: 3, nit: 4 };

function severityOf(f: Finding): Severity | null {
	const raw = (f.severity ?? "").toString().trim().toLowerCase();
	if (raw === "nit") return "nit";
	if (/^p[0-3]$/.test(raw)) return raw.toUpperCase() as Severity;
	if (typeof f.priority === "number" && f.priority >= 0 && f.priority <= 3) return `P${f.priority}` as Severity;
	const m = (f.title ?? "").match(/\[?\s*(p[0-3]|nit)\s*\]?/i);
	if (m) return m[1].toLowerCase() === "nit" ? "nit" : (m[1].toUpperCase() as Severity);
	return null;
}

function severityLabel(f: Finding): string {
	return severityOf(f) ?? "—";
}

function severityRank(f: Finding): number {
	const s = severityOf(f);
	return s ? SEVERITY_RANK[s] : 5;
}

function isBlocking(f: Finding): boolean {
	if (typeof f.blocking === "boolean") return f.blocking;
	const s = severityOf(f);
	return s === "P0" || s === "P1";
}

/** Strip a leading [Pn]/[nit] tag from a title (severity is shown in its own column). */
function titleText(f: Finding): string {
	return (f.title ?? "(untitled)").replace(/^\s*\[?\s*(?:p[0-3]|nit)\s*\]?\s*[-–:·]?\s*/i, "").trim() || "(untitled)";
}

function location(f: Finding): string {
	const p = f.code_location?.absolute_file_path;
	if (!p) return "—";
	const lr = f.code_location?.line_range;
	const side = (f.code_location?.side ?? "").toString().toUpperCase();
	const sideSuffix = side === "LEFT" ? " (LEFT)" : "";
	if (lr && lr.start != null) {
		const end = lr.end != null && lr.end !== lr.start ? `-${lr.end}` : "";
		return `${p}:${lr.start}${end}${sideSuffix}`;
	}
	return `${p}${sideSuffix}`;
}

/** Whether a finding carries enough diff-anchored data to post as an inline comment. */
function isCommentable(f: Finding): boolean {
	const cl = f.code_location;
	if (!cl || !cl.absolute_file_path) return false;
	if (cl.commentable === false) return false;
	return cl.line_range?.start != null;
}

function conf(n: number | undefined): string {
	return typeof n === "number" && Number.isFinite(n) ? n.toFixed(2) : "—";
}

/** Escape a value for use inside a Markdown table cell. */
function cell(s: string): string {
	return s.replace(/\|/g, "\\|").replace(/\r?\n/g, " ").trim();
}

function verdictLine(r: Review): string {
	const v = (r.verdict ?? "").toLowerCase();
	const incorrect = /incorrect/i.test(r.overall_correctness ?? "");
	let icon: string;
	let label: string;
	if (v === "approve" || (!v && !incorrect)) {
		icon = "✅";
		label = "Approve";
	} else if (v === "request_changes" || (!v && incorrect)) {
		icon = "❌";
		label = "Request changes";
	} else {
		icon = "💬";
		label = "Comment";
	}
	const parts = [`${icon} **${label}**`];
	if (r.overall_explanation) parts.push(`— ${r.overall_explanation.trim()}`);
	if (r.overall_confidence_score != null) parts.push(`_(confidence ${conf(r.overall_confidence_score)})_`);
	return parts.join(" ");
}

function renderReviewMarkdown(r: Review): string {
	const out: string[] = [];

	// Header
	const num = r.pr?.number;
	const title = (r.pr?.title ?? "").toString().replace(/\r?\n/g, " ").trim();
	if (num != null) out.push(`## Code Review — PR #${num}${title ? `: ${title}` : ""}`, "");
	else out.push("## Code Review", "");

	if (r.verification?.trim()) out.push(`**Verification:** ${r.verification.trim()}`, "");

	if (r.overview?.trim()) out.push("### Overview", "", r.overview.trim(), "");

	if (Array.isArray(r.strengths) && r.strengths.length > 0) {
		out.push("### Strengths", "");
		for (const s of r.strengths) out.push(`- ${String(s).replace(/^\s*-\s*/, "").trim()}`);
		out.push("");
	}

	// Findings
	const findings = [...r.findings].sort((a, b) => severityRank(a) - severityRank(b));
	const blocking = findings.filter(isBlocking).length;
	const nonBlocking = findings.length - blocking;
	out.push(`### Findings — ${findings.length} (${blocking} blocking, ${nonBlocking} non-blocking)`, "");

	if (findings.length === 0) {
		out.push("_No issues found — nit through P0._", "");
	} else {
		const inlineCount = findings.filter(isCommentable).length;
		out.push("| # | Sev | Blk | Inline | Finding | Location | Conf |", "|---|:--:|:--:|:--:|---|---|:--:|");
		findings.forEach((f, i) => {
			out.push(
				`| ${i + 1} | ${severityLabel(f)} | ${isBlocking(f) ? "yes" : "—"} | ${isCommentable(f) ? "✎" : "—"} | ${cell(titleText(f))} | \`${cell(location(f))}\` | ${conf(f.confidence_score)} |`,
			);
		});
		out.push("", `_✎ = has diff-anchored location postable as an inline comment (${inlineCount}/${findings.length})._`, "");
		findings.forEach((f, i) => {
			out.push(`#### ${i + 1}. [${severityLabel(f)}] ${cell(titleText(f))}`);
			const anchor = isCommentable(f) ? "inline-ready" : "summary-only";
			out.push(`\`${location(f)}\` · confidence ${conf(f.confidence_score)} · ${isBlocking(f) ? "blocking" : "non-blocking"} · ${anchor}`, "");
			if (f.body?.trim()) out.push(f.body.trim(), "");
		});
	}

	// Correctness / Security / Performance
	const notes = r.notes;
	const noteRows: string[] = [];
	if (notes?.correctness?.trim()) noteRows.push(`- **Correctness:** ${notes.correctness.trim()}`);
	if (notes?.security?.trim()) noteRows.push(`- **Security:** ${notes.security.trim()}`);
	if (notes?.performance?.trim()) noteRows.push(`- **Performance:** ${notes.performance.trim()}`);
	if (noteRows.length > 0) out.push("### Correctness / Security / Performance", "", ...noteRows, "");

	// Verdict
	out.push("### Verdict", "", verdictLine(r));

	return out.join("\n").trimEnd();
}

interface ConfigReadResult {
	value: Record<string, unknown>;
	error?: string;
}

function readJsonObject(filePath: string): ConfigReadResult {
	try {
		if (!fs.existsSync(filePath)) return { value: {} };
		const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
		return parsed && typeof parsed === "object"
			? { value: parsed as Record<string, unknown> }
			: { value: {}, error: `${filePath} must contain a JSON object` };
	} catch (error) {
		return { value: {}, error: `${filePath} is invalid JSON: ${String(error)}` };
	}
}

interface PublishingConfigResolution {
	autoPost: AutoPostResolution;
	allowStale: AutoPostResolution;
	allowStaleApprovals: AutoPostResolution;
	approveMaxPriority: ApproveMaxPriorityLevelResolution;
}

function invalidPublishingConfig(source: "user" | "project", error: string): PublishingConfigResolution {
	const invalid = { value: false, valid: false, source, error } as const;
	const invalidLevel = { value: "off" as const, valid: false, source, error } as const;
	return { autoPost: invalid, allowStale: invalid, allowStaleApprovals: invalid, approveMaxPriority: invalidLevel };
}

function resolvePublishingConfig(ctx: ExtensionContext): PublishingConfigResolution {
	const user = readJsonObject(path.join(getAgentDir(), "pr-review.json"));
	if (user.error) return invalidPublishingConfig("user", user.error);
	let project: ConfigReadResult | undefined;
	try {
		if (ctx.isProjectTrusted()) {
			project = readJsonObject(path.join(ctx.cwd, CONFIG_DIR_NAME, "pr-review.json"));
			if (project.error) return invalidPublishingConfig("project", project.error);
		}
	} catch {
		/* user config only */
	}
	return {
		autoPost: resolveAutoPostSetting(user.value, project?.value),
		allowStale: resolveAllowStalePublishSetting(user.value, project?.value),
		allowStaleApprovals: resolveAllowStaleApprovalsSetting(user.value, project?.value),
		approveMaxPriority: resolveApproveMaxPriorityLevelSetting(user.value, project?.value),
	};
}

function notifyPublishResult(
	result: Awaited<ReturnType<typeof publishPullReview>>,
	source: string,
	ctx: ExtensionContext,
): void {
	if (result.status === "posted") {
		const label = result.event === "APPROVE" ? "APPROVE" : "COMMENT";
		ctx.ui.notify(`PR review posted as ${label} (${source})${result.url ? `: ${result.url}` : ""}`, "info");
	} else if (result.status === "posted_degraded") {
		ctx.ui.notify(`PR review posted (${source}): ${result.message}${result.url ? ` ${result.url}` : ""}`, "warning");
	} else if (result.status === "skipped_duplicate") {
		ctx.ui.notify("PR review not reposted: this reviewed head was already posted by the current GitHub identity", "info");
	} else {
		ctx.ui.notify(`PR review publish ${result.status}: ${result.message}`, "error");
	}
}

type ReviewPublicationOrigin =
	| { readonly kind: "frozen-invocation" }
	| { readonly kind: "publish-command"; readonly stalePolicy: "frozen" | "allow-stale" }
	| { readonly kind: "direct-request" };

async function publishCompletedReview(
	record: CompletedReviewRecord,
	origin: ReviewPublicationOrigin,
	ctx: ExtensionContext,
): Promise<void> {
	const decision = origin.kind === "frozen-invocation"
		? decideReviewPublication(record.invocation)
		: undefined;
	if (decision?.error) {
		ctx.ui.notify(`PR review was not posted: ${decision.error}`, "error");
		return;
	}
	if (decision && !decision.publish) return;
	const explicitStale = origin.kind === "direct-request" ||
		(origin.kind === "publish-command" && origin.stalePolicy === "allow-stale");
	const allowStale = explicitStale || record.invocation.allowStalePublish;
	const source = decision?.source ?? (origin.kind === "frozen-invocation"
		? "frozen invocation"
		: origin.kind === "direct-request"
			? "direct user request"
			: origin.stalePolicy === "allow-stale" ? "publish-only --allow-stale" : "publish-only");

	const headSha = record.review.pr?.head_sha;
	if (typeof headSha !== "string") {
		ctx.ui.notify("PR review was not posted: cached final JSON is missing pr.head_sha", "error");
		return;
	}
	const result = await publishPullReview({
		cwd: ctx.cwd,
		prNumber: record.invocation.prNumber,
		headSha,
		allowNonOpen: record.invocation.allowNonOpen,
		allowStale,
		allowStaleApprovals: record.invocation.allowStaleApprovals,
		approveMaxPriorityLevel: record.invocation.approveMaxPriorityLevel,
		expectedRepository: record.repository,
		review: record.review,
	});
	notifyPublishResult(result, source, ctx);
}

export default function registerReviewTable(
	pi: ExtensionAPI,
	loopCoordinator = new ReviewLoopCoordinator(pi),
	selfReviewCoordinator = new SelfReviewPermitCoordinator(pi, () => !!loopCoordinator.peek()),
	repairOutput: ReviewOutputRepair = defaultReviewOutputRepair,
	prepareFallbackPayload: ReviewOutputFallbackPayload = defaultReviewOutputFallbackPayload,
) {
	const completedReviews = new CompletedReviewCache();
	const sessionIdentity = (ctx: ExtensionContext): CompletedReviewSessionIdentity | undefined => {
		const header = ctx.sessionManager.getHeader();
		const id = ctx.sessionManager.getSessionId();
		return header?.id === id && typeof header.timestamp === "string"
			? { id, startedAt: header.timestamp }
			: undefined;
	};
	const restoreCompletedReviews = (ctx: ExtensionContext) => {
		const session = sessionIdentity(ctx);
		if (!session) {
			completedReviews.clear();
			return;
		}
		restoreCompletedReviewBranch(completedReviews, ctx.sessionManager.getBranch(), session);
	};
	type PendingCompletion =
		| {
			readonly record: CompletedReviewRecord;
			readonly replacedRecord?: CompletedReviewRecord;
			readonly session?: CompletedReviewSessionIdentity;
		}
		| { readonly error: string };
	let pendingCompletion: PendingCompletion | undefined;
	const completionError = (invocation: ReviewInvocation, failure?: string): PendingCompletion | undefined => {
		const decision = decideReviewPublication(invocation);
		const error = decision.error ?? (decision.publish ? failure : undefined);
		return error ? { error } : undefined;
	};
	const resolveCompletion = async (
		parsed: ReturnType<typeof parsePublishableReview>,
		invocation: ReviewInvocation,
		ctx: ExtensionContext,
	): Promise<PendingCompletion | undefined> => {
		if (!parsed.review) return completionError(invocation, parsed.error ?? "final review JSON is invalid");
		const bindingError = validateReviewInvocation(parsed.review, invocation);
		if (bindingError) return completionError(invocation, bindingError);
		if (!shouldPublishReview(parsed.review)) return completionError(invocation);
		try {
			const repository = await resolveRepositoryBinding(ctx.cwd);
			// Cache before publication preflight; persist after Pi stores the assistant message.
			const replacement = completedReviews.replace(parsed.review, invocation, repository);
			const { record } = replacement;
			const session = sessionIdentity(ctx);
			if (!session) {
				ctx.ui.notify("Completed review cache will not survive reload: session identity is unavailable", "warning");
			}
			return session
				? { record, ...(replacement.previous ? { replacedRecord: replacement.previous } : {}), session }
				: { record, ...(replacement.previous ? { replacedRecord: replacement.previous } : {}) };
		} catch (error) {
			ctx.ui.notify(`Completed review is not available to publish-only: ${String(error)}`, "warning");
			return completionError(
				invocation,
				"its repository identity could not be established before caching; no publish-only cache is available. Rerun /pr-review when GitHub repository lookup is working.",
			);
		}
	};
	let outputRepairAttempted = false;
	let outputRepairCancelled = false;
	let outputRepairGeneration = 0;
	const clearOutputRepair = () => {
		outputRepairGeneration++;
		outputRepairAttempted = false;
		outputRepairCancelled = false;
	};
	const telemetryTracker = new ReviewTelemetryTracker();
	const persistTelemetry = (completion: ReviewPerformanceTelemetry["completion"]) => {
		const telemetry = telemetryTracker.finish(completion);
		if (!telemetry) return;
		try {
			pi.appendEntry("pr-review-telemetry", telemetry);
		} catch {
			// Telemetry persistence must never block rendering or publication safety checks.
		}
	};

	type CachedReviewResolution = { record: CompletedReviewRecord } | { error: string };
	const resolveCachedReview = async (
		requestedPrNumber: number | undefined,
		ctx: ExtensionContext,
	): Promise<CachedReviewResolution> => {
		try {
			const repository = await resolveRepositoryBinding(ctx.cwd);
			const record = requestedPrNumber === undefined
				? completedReviews.latest(repository)
				: completedReviews.get(requestedPrNumber, repository);
			if (record) return { record };
			const target = requestedPrNumber === undefined ? "the latest PR" : `PR #${requestedPrNumber}`;
			return {
				error: `No completed review for ${target} is cached for this repository in the current extension session. Publishing never starts or reruns a review.`,
			};
		} catch (error) {
			return { error: `Cannot resolve the current GitHub repository: ${String(error)}` };
		}
	};

	pi.registerCommand("pr-review-publish", {
		description: "Publish a completed review from this session without rerunning the model",
		handler: async (args, ctx) => {
			// Extension commands execute before input hooks, so every invocation —
			// including malformed arguments — must revoke active review authority.
			selfReviewCoordinator.clear();
			const active = loopCoordinator.peek();
			if (active) {
				loopCoordinator.clear();
				persistTelemetry("cleared");
			}
			const parsed = parsePublishExistingArgs(args ?? "");
			if (parsed.error || !parsed.prNumber) {
				ctx.ui.notify(
					`Invalid /pr-review-publish command: ${parsed.error ?? "missing PR number"}. Usage: /pr-review-publish <PR-NUM> [--allow-stale]`,
					"error",
				);
				return;
			}
			if (active?.prNumber === parsed.prNumber) {
				ctx.ui.notify(
					`PR #${parsed.prNumber} review was cancelled. The publish-only command will not post an older cached result in its place.`,
					"error",
				);
				return;
			}
			const resolved = await resolveCachedReview(parsed.prNumber, ctx);
			if ("error" in resolved) {
				ctx.ui.notify(resolved.error, "error");
				return;
			}
			await publishCompletedReview(resolved.record, {
				kind: "publish-command",
				stalePolicy: parsed.allowStale ? "allow-stale" : "frozen",
			}, ctx);
		},
	});

	const revokeActiveLoop = () => {
		loopCoordinator.clear();
		selfReviewCoordinator.clear();
		pendingCompletion = undefined;
		clearOutputRepair();
		telemetryTracker.clear();
	};

	pi.on("session_before_switch", revokeActiveLoop);
	pi.on("session_before_fork", revokeActiveLoop);
	pi.on("session_before_tree", revokeActiveLoop);
	pi.on("session_shutdown", revokeActiveLoop);

	pi.on("session_start", (_event, ctx) => {
		revokeActiveLoop();
		restoreCompletedReviews(ctx);
	});

	pi.on("before_agent_start", async (_event, ctx) => {
		await selfReviewCoordinator.beginTask(ctx);
	});

	pi.on("agent_settled", () => {
		selfReviewCoordinator.clear();
		if (!outputRepairCancelled) return;
		loopCoordinator.clear();
		clearOutputRepair();
		persistTelemetry("cleared");
	});

	pi.on("session_tree", (event, ctx) => {
		loopCoordinator.clear();
		selfReviewCoordinator.clear();
		pendingCompletion = undefined;
		clearOutputRepair();
		restoreCompletedReviews(ctx);
		telemetryTracker.clear();
		const session = sessionIdentity(ctx);
		if (event.summaryEntry || !session) return;
		try {
			// Pi otherwise resumes at the JSONL tail, not a no-summary /tree selection.
			pi.appendEntry(COMPLETED_REVIEW_BRANCH_ANCHOR_TYPE, { schemaVersion: 2, session });
		} catch (error) {
			ctx.ui.notify(`PR review cache branch selection will not survive session resume: ${String(error)}`, "warning");
		}
	});

	pi.on("input", async (event, ctx) => {
		// Any new input revokes the prior top-level task generation before it can
		// authorize a replay or a queued/steering continuation.
		selfReviewCoordinator.clear();
		if (outputRepairAttempted) {
			outputRepairCancelled = true;
			loopCoordinator.clear();
			clearOutputRepair();
			persistTelemetry("cleared");
			ctx.abort();
			ctx.ui.notify("PR review output correction was cancelled; overlapping input was not queued, so retry it", "warning");
			return { action: "handled" as const };
		}
		clearOutputRepair();
		const source = event.source as ReviewLoopInputSource;
		const directPublish = parseDirectPublishRequest(event.text);
		if (
			(source === "interactive" || source === "rpc") &&
			event.streamingBehavior === undefined &&
			directPublish.matched
		) {
			const active = loopCoordinator.peek();
			if (active) {
				loopCoordinator.clear();
				persistTelemetry("cleared");
				ctx.ui.notify(
					`PR #${active.prNumber} review was cancelled. The direct publish request will not post an older cached result in its place.`,
					"error",
				);
				return { action: "handled" as const };
			}
			const resolved = await resolveCachedReview(directPublish.prNumber, ctx);
			if ("error" in resolved) ctx.ui.notify(resolved.error, "error");
			else await publishCompletedReview(resolved.record, { kind: "direct-request" }, ctx);
			return { action: "handled" as const };
		}
		if (loopCoordinator.phase() === "awaiting_confirmation") {
			const confirmation = loopCoordinator.resolveConfirmationInput(event.text, source, ctx);
			if (confirmation === "confirmed") {
				telemetryTracker.resumeAfterConfirmation();
				return;
			}
			// Finish while paused so negative/unrelated input cannot count human wait as active work.
			// A fresh /pr-review in this same input may safely bind a new tracker below.
			persistTelemetry("cleared");
		}

		const parsed = parsePublishMode(event.text);
		if (loopCoordinator.peek()) {
			// Any independent user/extension input revokes the current generation.
			// Only a fresh idle /pr-review command may begin the replacement.
			loopCoordinator.clear();
			persistTelemetry(parsed.matched && event.streamingBehavior === undefined ? "replaced" : "cleared");
			if (!parsed.matched) return;
		}
		if (!parsed.matched) {
			selfReviewCoordinator.noteTopLevelInput(source, event.streamingBehavior, ctx);
			return;
		}
		if (event.streamingBehavior !== undefined) {
			// Returning handled prevents queueing but does not stop the current parent
			// operation. Abort it so revoked review work cannot continue with built-ins.
			ctx.abort();
			ctx.ui.notify("Invalid /pr-review invocation: queued or steering input cannot start a review loop", "error");
			return { action: "handled" as const };
		}
		if (!isOwnReviewPrompt(pi)) {
			ctx.ui.notify("Invalid /pr-review invocation: the active prompt is not the pi-pr-review package prompt", "error");
			return { action: "handled" as const };
		}

		// Freeze trusted publication config before review tools or optional PR code can run.
		const publishingConfig = resolvePublishingConfig(ctx);
		const gate = loopCoordinator.begin(
			parsed,
			publishingConfig.autoPost,
			source,
			ctx,
			publishingConfig.allowStale.valid && publishingConfig.allowStale.value,
			publishingConfig.allowStaleApprovals.valid && publishingConfig.allowStaleApprovals.value,
			publishingConfig.approveMaxPriority.valid ? publishingConfig.approveMaxPriority.value : "off",
		);
		if (!gate.accepted) {
			ctx.ui.notify(`Invalid /pr-review invocation: ${gate.error}`, "error");
			return { action: "handled" as const };
		}
		telemetryTracker.begin(parsed.prNumber!);
	});

	pi.on("tool_execution_start", (event) => {
		if (!loopCoordinator.peek()) return;
		telemetryTracker.toolStarted(event.toolCallId, event.toolName, event.args);
	});

	pi.on("tool_execution_end", (event) => {
		telemetryTracker.toolEnded(event.toolCallId);
	});

	pi.on("turn_end", async (_event, ctx) => {
		const pending = pendingCompletion;
		pendingCompletion = undefined;
		if (!pending) return;
		if ("error" in pending) {
			ctx.ui.notify(`PR review was not posted: ${pending.error}`, "error");
			return;
		}
		if (pending.session) {
			const currentSession = sessionIdentity(ctx);
			if (!currentSession || currentSession.id !== pending.session.id || currentSession.startedAt !== pending.session.startedAt) {
				ctx.ui.notify("Completed review was not persisted or posted because the session identity changed", "warning");
				return;
			}
			const leaf = ctx.sessionManager.getLeafEntry();
			const leafReview = leaf?.type === "message" && leaf.message.role === "assistant"
				? parsePublishableReview(assistantText(leaf.message as { content?: MessagePart[] })).review
				: undefined;
			const reviewEntryId = leafReview ? leaf?.id : undefined;
			try {
				// Persist before any GitHub preflight so a failed post always remains retryable.
				pi.appendEntry(
					COMPLETED_REVIEW_ENTRY_TYPE,
					completedReviews.persist(pending.record, pending.session, reviewEntryId, leafReview),
				);
			} catch (error) {
				ctx.ui.notify(`Completed review cache will not survive an extension reload: ${String(error)}`, "warning");
			}
		}
		await publishCompletedReview(pending.record, { kind: "frozen-invocation" }, ctx);
	});

	pi.on("message_end", async (event, ctx) => {
		if (event.message.role !== "assistant") return;
		const completion = classifyAssistantCompletion(event.message.stopReason, hasToolCall(event.message));
		if (outputRepairCancelled) {
			if (completion === "continue_tools") ctx.abort();
			return;
		}
		if (completion === "continue_tools") {
			if (outputRepairAttempted && loopCoordinator.peek()) {
				ctx.ui.notify("PR review was not posted: automatic output correction attempted to call tools", "error");
				ctx.abort();
				loopCoordinator.clear();
				clearOutputRepair();
				persistTelemetry("cleared");
				return;
			}
			const toolCalls = Array.isArray(event.message.content)
				? event.message.content.filter((part) => part.type === "toolCall")
				: [];
			if (toolCalls.length === 1) {
				const call = toolCalls[0] as { id?: unknown; name?: unknown };
				if (call.name === "self_review_subagent" && typeof call.id === "string") {
					selfReviewCoordinator.bindToolCall(call.id, ctx);
				}
			}
			return;
		}
		if (completion === "clear_invocation") {
			loopCoordinator.clear();
			clearOutputRepair();
			persistTelemetry("cleared");
			return;
		}

		const text = assistantText(event.message);
		const active = loopCoordinator.peek();
		if (
			active &&
			loopCoordinator.phase() === "reviewing" &&
			isNonOpenConfirmationPrompt(text, active.prNumber)
		) {
			if (loopCoordinator.markAwaitingConfirmation()) telemetryTracker.pauseForConfirmation();
			return;
		}

		const publishable = active ? parsePublishableReview(text) : undefined;
		if (active && !publishable?.review && !outputRepairAttempted) {
			const error = publishable?.error ?? "final review JSON is invalid";
			if (loopCoordinator.suspendToolsForRepair()) {
				const lease = loopCoordinator.repairLease(ctx);
				if (!lease) {
					ctx.ui.notify("Automatic PR review output correction was skipped because its review lease was lost", "warning");
					return;
				}
				outputRepairAttempted = true;
				outputRepairCancelled = false;
				const repairGeneration = ++outputRepairGeneration;
				const isActiveRepair = () => !outputRepairCancelled && repairGeneration === outputRepairGeneration &&
					loopCoordinator.isRepairLeaseActive(lease, ctx);
				ctx.ui.notify(`PR review output is invalid (${error}); asking the light repair subagent once`, "warning");
				void repairOutput(text, REVIEW_OUTPUT_CONTRACT, ctx, lease.signal).then(async (repairedText) => {
					if (!isActiveRepair()) return;
					const repaired = repairedText ? parsePublishableReview(repairedText) : undefined;
					if (!repaired?.review) {
						const activeInvocation = loopCoordinator.peek();
						const invocation = activeInvocation
							? {
								...activeInvocation,
								allowNonOpen: activeInvocation.allowNonOpen || loopCoordinator.phase() === "confirmed",
							}
							: undefined;
						const publication = invocation ? decideReviewPublication(invocation) : undefined;
						const reviewedHeadSha = invocation
							? fallbackReviewedHead(invocation.prNumber, text)
							: undefined;
						if (invocation && publication?.publish && reviewedHeadSha && isActiveRepair()) {
							ctx.ui.notify(
								"Light output correction did not produce valid final JSON; asking the light model for one COMMENT payload for host-owned gh publication",
								"warning",
							);
							let expectedRepository;
							try {
								expectedRepository = await resolveRepositoryBinding(ctx.cwd);
							} catch (error) {
								if (isActiveRepair()) {
									ctx.ui.notify(`PR review was not posted: fallback repository lookup failed: ${String(error)}`, "error");
									loopCoordinator.consume();
									clearOutputRepair();
									persistTelemetry("terminal_response");
								}
								return;
							}
							if (!isActiveRepair()) return;
							const payload = await prepareFallbackPayload(text, reviewedHeadSha, ctx, lease.signal);
							if (!isActiveRepair()) return;
							if (
								!payload ||
								payload.commit_id !== reviewedHeadSha ||
								payload.event !== "COMMENT" ||
								typeof payload.body !== "string"
							) {
								ctx.ui.notify("PR review was not posted: light gh fallback did not produce a valid COMMENT payload", "error");
							} else {
								const result = await publishPullReviewBody({
									cwd: ctx.cwd,
									prNumber: invocation.prNumber,
									headSha: reviewedHeadSha,
									allowNonOpen: invocation.allowNonOpen,
									allowStale: invocation.allowStalePublish,
									expectedRepository,
									body: payload.body,
								});
								if (!isActiveRepair()) return;
								notifyPublishResult(result, "light gh fallback", ctx);
							}
						} else if (isActiveRepair()) {
							ctx.ui.notify(
								publication?.error
									? `PR review was not posted: ${publication.error}`
									: publication?.publish && !reviewedHeadSha
										? "PR review was not posted: malformed output did not contain a trustworthy reviewed head"
										: "PR review was not posted: light output correction did not produce valid final JSON",
								"error",
							);
						}
						if (isActiveRepair()) {
							loopCoordinator.consume();
							clearOutputRepair();
							persistTelemetry("terminal_response");
						}
						return;
					}
					const invocation = loopCoordinator.peek();
					if (!invocation || !isActiveRepair()) return;
					const completion = await resolveCompletion(repaired, invocation, ctx);
					if (!isActiveRepair()) {
						if (completion && "record" in completion) {
							completedReviews.restoreReplacement(completion.record, completion.replacedRecord);
						}
						return;
					}
					if (completion && "record" in completion) {
						if (completion.session) {
							try {
								pi.appendEntry(COMPLETED_REVIEW_ENTRY_TYPE, completedReviews.persist(completion.record, completion.session));
							} catch (persistError) {
								ctx.ui.notify(`Completed review cache will not survive an extension reload: ${String(persistError)}`, "warning");
							}
						}
						if (!isActiveRepair()) return;
						await publishCompletedReview(completion.record, { kind: "frozen-invocation" }, ctx);
					} else if (completion && "error" in completion) {
						ctx.ui.notify(`PR review was not posted: ${completion.error}`, "error");
					}
					if (isActiveRepair()) {
						loopCoordinator.consume();
						clearOutputRepair();
						persistTelemetry("terminal_response");
					}
				}).catch(() => {
					if (!isActiveRepair()) return;
					loopCoordinator.consume();
					clearOutputRepair();
					persistTelemetry("terminal_response");
					ctx.ui.notify("PR review was not posted: light output correction failed", "error");
				});
				return;
			}
			ctx.ui.notify("Automatic PR review output correction was skipped because tools could not be disabled", "warning");
		}

		// A valid response, or a failed single correction, consumes authority.
		// Persist timing before publication so network/write latency is never coupled to review wall time.
		const invocation = active ? loopCoordinator.consume() : undefined;
		if (invocation) {
			clearOutputRepair();
			persistTelemetry("terminal_response");
		}
		const review = publishable?.review
			? publishable.review as Review
			: active
				? null
				: text.trim()
					? parseReview(text)
					: null;
		if (invocation) pendingCompletion = await resolveCompletion(publishable!, invocation, ctx);
		if (!review) return; // not a renderable /pr-review JSON payload — leave untouched

		// Keep raw JSON for automation; only prettify for interactive terminals.
		if (ctx.mode !== "tui") return;
		const nonText = event.message.content.filter((part) => part.type !== "text");
		return {
			message: {
				...event.message,
				content: [...nonText, { type: "text", text: renderReviewMarkdown(review) }],
			},
		};
	});
}
