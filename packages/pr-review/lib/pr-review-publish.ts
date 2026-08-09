import { Buffer } from "node:buffer";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";

export type PublishMode = "auto" | "force" | "disabled";
export type AutoPostSource = "default" | "user" | "project";
export type CompletionAction = "continue_tools" | "accept_final" | "clear_invocation";

/** Maximum severity that may appear in a review for auto-APPROVE to be granted. */
export type ApproveMaxPriorityLevel = "off" | "P2" | "P3" | "nit";

const APPROVE_PRIORITY_LEVELS = ["P2", "P3", "nit"] as const;
const APPROVE_PRIORITY_RANK: Record<string, number> = {
	P0: 4,
	P1: 3,
	P2: 2,
	P3: 1,
	nit: 0,
	NIT: 0,
};

export interface ApproveMaxPriorityLevelResolution {
	readonly value: ApproveMaxPriorityLevel;
	readonly valid: boolean;
	readonly source: AutoPostSource;
	readonly error?: string;
}

function isValidApproveLevel(value: unknown): value is ApproveMaxPriorityLevel {
	return value === "off" || (typeof value === "string" && APPROVE_PRIORITY_LEVELS.includes(value as (typeof APPROVE_PRIORITY_LEVELS)[number]));
}

/** Resolve the auto-approve priority gate with trusted project config overlaying user config. */
export function resolveApproveMaxPriorityLevelSetting(
	user: unknown,
	trustedProject?: unknown,
): ApproveMaxPriorityLevelResolution {
	if (hasOwn(trustedProject, "approveMaxPriorityLevel")) {
		const value = (trustedProject as { approveMaxPriorityLevel?: unknown }).approveMaxPriorityLevel;
		return isValidApproveLevel(value)
			? { value, valid: true, source: "project" }
			: {
					value: "off",
					valid: false,
					source: "project",
					error: `project approveMaxPriorityLevel must be one of: off, ${APPROVE_PRIORITY_LEVELS.join(", ")}`,
				};
	}
	if (hasOwn(user, "approveMaxPriorityLevel")) {
		const value = (user as { approveMaxPriorityLevel?: unknown }).approveMaxPriorityLevel;
		return isValidApproveLevel(value)
			? { value, valid: true, source: "user" }
			: {
					value: "off",
					valid: false,
					source: "user",
					error: `user approveMaxPriorityLevel must be one of: off, ${APPROVE_PRIORITY_LEVELS.join(", ")}`,
				};
	}
	return { value: "off", valid: true, source: "default" };
}

/** Whether all findings in a review are at or below the configured maximum priority. */
export function findingsWithinApproveMaxPriority(
	review: ReviewLike,
	level: ApproveMaxPriorityLevel,
): boolean {
	if (level === "off") return false;
	const maxRank = APPROVE_PRIORITY_RANK[level];
	if (maxRank === undefined) return false;
	const findings = Array.isArray(review.findings) ? review.findings : [];
	return findings.every(
		(finding) => (APPROVE_PRIORITY_RANK[String(finding.severity ?? "").toUpperCase()] ?? Infinity) <= maxRank,
	);
}

/** Decide whether a review should be published as APPROVE instead of COMMENT. */
export function shouldApproveReview(
	review: ReviewLike,
	approveMaxPriorityLevel: ApproveMaxPriorityLevel,
): boolean {
	const findings = Array.isArray(review.findings) ? review.findings : [];
	return (
		review.verdict === "approve" &&
		approveMaxPriorityLevel !== "off" &&
		findings.every((finding) => !finding.blocking) &&
		findingsWithinApproveMaxPriority(review, approveMaxPriorityLevel)
	);
}

export function classifyAssistantCompletion(
	stopReason: string | undefined,
	hasToolCall: boolean,
): CompletionAction {
	if (stopReason === "toolUse" && hasToolCall) return "continue_tools";
	if (stopReason === "stop" && !hasToolCall) return "accept_final";
	return "clear_invocation";
}

export interface AutoPostResolution {
	readonly value: boolean;
	readonly valid: boolean;
	readonly source: AutoPostSource;
	readonly error?: string;
}

function hasOwn(value: unknown, key: string): boolean {
	return !!value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, key);
}

/** Resolve a strict boolean with trusted project config overlaying user config. */
export function resolveAutoPostSetting(user: unknown, trustedProject?: unknown): AutoPostResolution {
	if (hasOwn(trustedProject, "autoPostReviews")) {
		const value = (trustedProject as { autoPostReviews?: unknown }).autoPostReviews;
		return typeof value === "boolean"
			? { value, valid: true, source: "project" }
			: {
					value: false,
					valid: false,
					source: "project",
					error: "project autoPostReviews must be a boolean",
				};
	}
	if (hasOwn(user, "autoPostReviews")) {
		const value = (user as { autoPostReviews?: unknown }).autoPostReviews;
		return typeof value === "boolean"
			? { value, valid: true, source: "user" }
			: {
					value: false,
					valid: false,
					source: "user",
					error: "user autoPostReviews must be a boolean",
				};
	}
	return { value: false, valid: true, source: "default" };
}

/** Resolve whether stale cached reviews may publish, enabled by default. */
export function resolveAllowStalePublishSetting(
	user: unknown,
	trustedProject?: unknown,
): AutoPostResolution {
	if (hasOwn(trustedProject, "allowStalePublish")) {
		const value = (trustedProject as { allowStalePublish?: unknown }).allowStalePublish;
		return typeof value === "boolean"
			? { value, valid: true, source: "project" }
			: {
					value: false,
					valid: false,
					source: "project",
					error: "project allowStalePublish must be a boolean",
				};
	}
	if (hasOwn(user, "allowStalePublish")) {
		const value = (user as { allowStalePublish?: unknown }).allowStalePublish;
		return typeof value === "boolean"
			? { value, valid: true, source: "user" }
			: {
					value: false,
					valid: false,
					source: "user",
					error: "user allowStalePublish must be a boolean",
				};
	}
	return { value: true, valid: true, source: "default" };
}

/** Resolve whether an otherwise-qualified stale review may record APPROVE. Disabled by default. */
export function resolveAllowStaleApprovalsSetting(
	user: unknown,
	trustedProject?: unknown,
): AutoPostResolution {
	if (hasOwn(trustedProject, "allowStaleApprovals")) {
		const value = (trustedProject as { allowStaleApprovals?: unknown }).allowStaleApprovals;
		return typeof value === "boolean"
			? { value, valid: true, source: "project" }
			: {
					value: false,
					valid: false,
					source: "project",
					error: "project allowStaleApprovals must be a boolean",
				};
	}
	if (hasOwn(user, "allowStaleApprovals")) {
		const value = (user as { allowStaleApprovals?: unknown }).allowStaleApprovals;
		return typeof value === "boolean"
			? { value, valid: true, source: "user" }
			: {
					value: false,
					valid: false,
					source: "user",
					error: "user allowStaleApprovals must be a boolean",
				};
	}
	return { value: false, valid: true, source: "default" };
}

export interface PublishModeParseResult {
	matched: boolean;
	mode?: PublishMode;
	prNumber?: number;
	allowNonOpen?: boolean;
	error?: string;
}

/** Parse trusted raw prompt-template invocation flags before template expansion. */
export function parsePublishMode(input: string): PublishModeParseResult {
	const trimmed = input.trim();
	if (!/^\/pr-review(?:\s|$)/.test(trimmed)) return { matched: false };
	const tokens = trimmed.split(/\s+/);
	const requested = Number(tokens[1]);
	if (!Number.isInteger(requested) || requested <= 0) {
		return { matched: true, error: "a positive PR number must be the first argument" };
	}
	const force = tokens.includes("--comment");
	const disabled = tokens.includes("--no-comment");
	const full = tokens.includes("--full");
	const majorOnly = tokens.includes("--major-only");
	const balanced = tokens.includes("--balanced");
	if (force && disabled) {
		return { matched: true, error: "--comment and --no-comment cannot be used together" };
	}
	if ([full, majorOnly, balanced].filter(Boolean).length > 1) {
		return { matched: true, error: "--full, --major-only, and --balanced cannot be used together" };
	}
	return {
		matched: true,
		mode: disabled ? "disabled" : force ? "force" : "auto",
		prNumber: requested,
		allowNonOpen: tokens.includes("--include-closed") || tokens.includes("--review-closed"),
	};
}

export interface ReviewInvocation {
	readonly mode: PublishMode;
	readonly prNumber: number;
	readonly allowNonOpen: boolean;
	/** Trusted stale-publication setting captured before review execution begins. */
	readonly allowStalePublish: boolean;
	/** Trusted stale-approval setting captured before review execution begins. */
	readonly allowStaleApprovals: boolean;
	/** Trusted automatic-posting decision captured before review execution begins. */
	readonly autoPost: Readonly<AutoPostResolution>;
	/** Trusted auto-approve priority gate captured before review execution begins. */
	readonly approveMaxPriorityLevel: ApproveMaxPriorityLevel;
}

export interface ReviewPublicationDecision {
	readonly publish: boolean;
	readonly source?: "--comment" | `${AutoPostSource} config`;
	readonly error?: string;
}

/** Derive write authority exclusively from invocation flags and its frozen config snapshot. */
export function decideReviewPublication(invocation: ReviewInvocation): ReviewPublicationDecision {
	if (invocation.mode === "disabled") return { publish: false };
	if (invocation.mode === "force") return { publish: true, source: "--comment" };
	if (!invocation.autoPost.valid) {
		return {
			publish: false,
			error: invocation.autoPost.error ?? `${invocation.autoPost.source} autoPostReviews is invalid`,
		};
	}
	return invocation.autoPost.value
		? { publish: true, source: `${invocation.autoPost.source} config` }
		: { publish: false };
}

export interface DirectPublishRequestParseResult {
	matched: boolean;
	prNumber?: number;
}

/** Narrow whole-input matcher for direct natural-language cached publish requests. */
export function parseDirectPublishRequest(input: string): DirectPublishRequestParseResult {
	const trimmed = input.trim();
	if (!trimmed || /[\r\n]/.test(trimmed)) return { matched: false };
	const match = trimmed.match(
		/^(?:(?:please|kindly)\s+|(?:(?:can|could|would|will)\s+you\s+))?(?:post|publish|submit)\s+(?:(?:(?:the|this|that|these|those|my|our)\s+)?(?:(?:cached|completed|current|latest|inline|github|pr|pull[\s-]?request|review)\s+)*(?:reviews?|comments|(?:inline|review)\s+comment)|(?:it|this|that)\s+as\s+(?:(?:an?|the)\s+)?(?:(?:cached|completed|current|latest|inline|github|pr|pull[\s-]?request|review)\s+)*(?:reviews?|comments|(?:inline|review)\s+comment))(?:\s+(?:for|on|to)\s+(?:(?:the\s+)?(?:pull\s+request|pr)\s*)?#?(\d+))?(?:\s+please)?[.!?]*$/i,
	);
	if (!match) return { matched: false };
	if (match[1] === undefined) return { matched: true };
	const prNumber = Number(match[1]);
	return Number.isInteger(prNumber) && prNumber > 0
		? { matched: true, prNumber }
		: { matched: false };
}

export interface PublishExistingParseResult {
	prNumber?: number;
	allowStale: boolean;
	error?: string;
}

/** Parse the direct, model-free `/pr-review-publish` command arguments. */
export function parsePublishExistingArgs(input: string): PublishExistingParseResult {
	const tokens = input.trim().split(/\s+/).filter(Boolean);
	const requested = Number(tokens[0]);
	if (!Number.isInteger(requested) || requested <= 0) {
		return { allowStale: false, error: "a positive PR number must be the first argument" };
	}
	const unknown = tokens.slice(1).filter((token) => token !== "--allow-stale");
	if (unknown.length > 0) {
		return { allowStale: false, error: `unknown argument${unknown.length === 1 ? "" : "s"}: ${unknown.join(", ")}` };
	}
	return { prNumber: requested, allowStale: tokens.includes("--allow-stale") };
}

export type ReviewInvocationPhase = "reviewing" | "awaiting_confirmation" | "confirmed";

export function isNonOpenConfirmationPrompt(text: string, prNumber: number): boolean {
	const escaped = String(prNumber).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const match = text.trim().match(
		new RegExp(
			`^PR #${escaped} is ([A-Z_]+) \\(head [0-9a-f]{40}(?:[0-9a-f]{24})?\\)\\. Review it anyway\\? Reply yes, or rerun with --include-closed to proceed non-interactively\\.$`,
			"i",
		),
	);
	return !!match && ["CLOSED", "MERGED"].includes(match[1]?.toUpperCase() ?? "");
}

export function isAffirmativeReviewConfirmation(text: string): boolean {
	return /^(?:y|yes)[.!]?$/i.test(text.trim());
}

export function validateReviewInvocation(review: ReviewLike, invocation: ReviewInvocation): string | undefined {
	return review.pr?.number === invocation.prNumber
		? undefined
		: `final JSON PR #${review.pr?.number ?? "?"} does not match requested PR #${invocation.prNumber}`;
}

/** One active invocation per extension session; queued reviews cannot overwrite its write intent. */
export class ReviewInvocationGate {
	private active?: ReviewInvocation;
	private currentPhase?: ReviewInvocationPhase;

	begin(
		parsed: PublishModeParseResult,
		autoPost: AutoPostResolution,
		allowStalePublish = true,
		allowStaleApprovals = false,
		approveMaxPriorityLevel: ApproveMaxPriorityLevel = "off",
	): { accepted: boolean; error?: string } {
		if (!parsed.matched) return { accepted: false, error: "not a pr-review invocation" };
		if (this.active) {
			return { accepted: false, error: `PR #${this.active.prNumber} review is still active` };
		}
		if (parsed.error || !parsed.mode || !parsed.prNumber) {
			return { accepted: false, error: parsed.error ?? "missing PR number or publishing mode" };
		}
		const snapshot = Object.freeze({
			value: autoPost.value,
			valid: autoPost.valid,
			source: autoPost.source,
			...(autoPost.error === undefined ? {} : { error: autoPost.error }),
		});
		this.active = Object.freeze({
			mode: parsed.mode,
			prNumber: parsed.prNumber,
			allowNonOpen: parsed.allowNonOpen === true,
			allowStalePublish,
			allowStaleApprovals,
			autoPost: snapshot,
			approveMaxPriorityLevel,
		});
		this.currentPhase = "reviewing";
		return { accepted: true };
	}

	peek(): ReviewInvocation | undefined {
		return this.active;
	}

	phase(): ReviewInvocationPhase | undefined {
		return this.currentPhase;
	}

	markAwaitingConfirmation(): boolean {
		if (!this.active || this.currentPhase !== "reviewing") return false;
		this.currentPhase = "awaiting_confirmation";
		return true;
	}

	resolveConfirmationInput(text: string): "not_awaiting" | "confirmed" | "cleared" {
		if (!this.active || this.currentPhase !== "awaiting_confirmation") return "not_awaiting";
		if (isAffirmativeReviewConfirmation(text)) {
			this.currentPhase = "confirmed";
			return "confirmed";
		}
		this.clear();
		return "cleared";
	}

	consume(): ReviewInvocation | undefined {
		const value = this.active
			? {
					...this.active,
					allowNonOpen: this.active.allowNonOpen || this.currentPhase === "confirmed",
				}
			: undefined;
		this.clear();
		return value;
	}

	clear(): void {
		this.active = undefined;
		this.currentPhase = undefined;
	}
}

export function canonicalReviewMarker(headSha: string): string {
	return `<!-- pi-pr-review: {"schema":1,"headRefOid":"${headSha.toLowerCase()}"} -->`;
}

export function githubApiArgs(hostname: string, ...args: string[]): string[] {
	return ["api", "--hostname", hostname, ...args];
}

export const REVIEW_EVENT = "COMMENT" as const;
export const APPROVE_EVENT = "APPROVE" as const;
export type ReviewEventType = typeof REVIEW_EVENT | typeof APPROVE_EVENT;
export const MAX_INLINE_COMMENTS = 50;
const MAX_BODY_BYTES = 65_536;
const MAX_PAYLOAD_BYTES = 900_000;
const RESERVED_MARKER_PREFIX = "<!-- pi-pr-review:";
const CHANGED_FILE_LOOKUP_DIAGNOSTIC =
	"changed-file lookup failed; all inline findings kept in the review summary";

export interface PublishComment {
	path: string;
	body: string;
	line: number;
	side: "LEFT" | "RIGHT";
	start_line?: number;
	start_side?: "LEFT" | "RIGHT";
}

export interface PullReviewPayload {
	commit_id: string;
	event: ReviewEventType;
	body: string;
	comments?: PublishComment[];
}

/** Build the GitHub review payload, optionally with an APPROVE event. */
export function buildPullReviewPayload(
	headSha: string,
	body: string,
	comments: PublishComment[],
	event: ReviewEventType = REVIEW_EVENT,
): PullReviewPayload {
	return {
		commit_id: headSha,
		event,
		body,
		...(comments.length > 0 ? { comments } : {}),
	};
}

export interface ReviewFindingLike {
	title?: string;
	body?: string;
	severity?: string;
	blocking?: boolean;
	confidence_score?: number;
	code_location?: {
		absolute_file_path?: string | null;
		line_range?: { start?: number; end?: number };
		side?: string | null;
		commentable?: boolean;
	} | null;
}

export interface ReviewLike {
	pr?: { number?: number | null; title?: string | null; head_sha?: string | null } | null;
	disposition?: "reviewed" | "skipped";
	verification?: string;
	overview?: string;
	strengths?: string[];
	findings?: ReviewFindingLike[];
	notes?: { correctness?: string; security?: string; performance?: string } | null;
	verdict?: string;
	overall_correctness?: string;
	overall_explanation?: string;
	overall_confidence_score?: number;
}

export interface RepositoryBinding {
	repository: string;
	hostname: string;
}

export interface CompletedReviewRecord {
	review: ReviewLike;
	invocation: ReviewInvocation;
	repository: RepositoryBinding;
}

export const COMPLETED_REVIEW_ENTRY_TYPE = "pr-review-completed";
export const COMPLETED_REVIEW_BRANCH_ANCHOR_TYPE = "pr-review-cache-branch";

export interface CompletedReviewSessionIdentity {
	id: string;
	startedAt: string;
}

export interface PersistedCompletedReview {
	schemaVersion: 2;
	session: CompletedReviewSessionIdentity;
	invocation: ReviewInvocation;
	repository: RepositoryBinding;
	reviewHash: string;
	reviewEntryId?: string;
	review?: ReviewLike;
}

export interface CompletedReviewSessionEntryLike {
	type: string;
	id?: string;
	customType?: string;
	data?: unknown;
	message?: unknown;
}

function completedReviewKey(repository: RepositoryBinding, prNumber: number): string {
	return `${repository.hostname.toLowerCase()}:${repository.repository.toLowerCase()}:${prNumber}`;
}

export function validRepositoryBinding(value: unknown): value is RepositoryBinding {
	if (!isObject(value)) return false;
	return (
		typeof value.repository === "string" &&
		/^[^/\s]+\/[^/\s]+$/.test(value.repository) &&
		typeof value.hostname === "string" &&
		/^[a-z0-9.-]+$/i.test(value.hostname)
	);
}

function validSessionIdentity(value: unknown): value is CompletedReviewSessionIdentity {
	return (
		isObject(value) &&
		typeof value.id === "string" &&
		value.id.length > 0 &&
		typeof value.startedAt === "string" &&
		value.startedAt.length > 0
	);
}

function sameSessionIdentity(left: CompletedReviewSessionIdentity, right: CompletedReviewSessionIdentity): boolean {
	return left.id === right.id && left.startedAt === right.startedAt;
}

function reviewHash(review: ReviewLike): string {
	return createHash("sha256").update(JSON.stringify(review)).digest("hex");
}

function parsePersistedInvocation(value: unknown): ReviewInvocation | undefined {
	if (!isObject(value)) return undefined;
	if (!new Set(["auto", "force", "disabled"]).has(String(value.mode))) return undefined;
	if (
		!Number.isInteger(value.prNumber) ||
		Number(value.prNumber) <= 0 ||
		typeof value.allowNonOpen !== "boolean" ||
		(value.allowStalePublish !== undefined && typeof value.allowStalePublish !== "boolean") ||
		(value.allowStaleApprovals !== undefined && typeof value.allowStaleApprovals !== "boolean")
	) {
		return undefined;
	}
	const autoPost = value.autoPost;
	if (
		!isObject(autoPost) ||
		typeof autoPost.value !== "boolean" ||
		typeof autoPost.valid !== "boolean" ||
		!new Set(["default", "user", "project"]).has(String(autoPost.source)) ||
		(autoPost.error !== undefined && typeof autoPost.error !== "string")
	) {
		return undefined;
	}
	return {
		mode: value.mode as PublishMode,
		prNumber: Number(value.prNumber),
		allowNonOpen: value.allowNonOpen,
		// Schema v2 records created before this setting existed inherit the new
		// safe default: stale publication is body-only with both SHAs disclosed.
		allowStalePublish: typeof value.allowStalePublish === "boolean" ? value.allowStalePublish : true,
		// Legacy records never opt into merge-relevant stale approvals.
		allowStaleApprovals: typeof value.allowStaleApprovals === "boolean" ? value.allowStaleApprovals : false,
		autoPost: {
			value: autoPost.value,
			valid: autoPost.valid,
			source: autoPost.source as AutoPostSource,
			...(typeof autoPost.error === "string" ? { error: autoPost.error } : {}),
		},
		// Schema v2 records created before this setting existed inherit the safe
		// default: auto-approve is disabled (publication uses COMMENT only).
		approveMaxPriorityLevel:
			isValidApproveLevel(value.approveMaxPriorityLevel) ? value.approveMaxPriorityLevel : "off",
	};
}

/** Session-scoped latest completed review per repository and PR. */
export class CompletedReviewCache {
	private readonly reviews = new Map<string, CompletedReviewRecord>();

	remember(review: ReviewLike, invocation: ReviewInvocation, repository: RepositoryBinding): CompletedReviewRecord {
		return this.replace(review, invocation, repository).record;
	}

	/** Replace one PR record while retaining its predecessor for cancellation rollback. */
	replace(review: ReviewLike, invocation: ReviewInvocation, repository: RepositoryBinding): {
		record: CompletedReviewRecord;
		previous?: CompletedReviewRecord;
	} {
		const record = {
			review,
			invocation: { ...invocation, autoPost: { ...invocation.autoPost } },
			repository: { ...repository },
		};
		const key = completedReviewKey(repository, invocation.prNumber);
		const previous = this.reviews.get(key);
		// Refresh insertion order so unnumbered direct publish requests bind to
		// the most recently completed review in this repository.
		this.reviews.delete(key);
		this.reviews.set(key, record);
		return previous ? { record, previous } : { record };
	}

	persist(
		record: CompletedReviewRecord,
		session: CompletedReviewSessionIdentity,
		reviewEntryId?: string,
		referencedReview?: ReviewLike,
	): PersistedCompletedReview {
		const digest = reviewHash(record.review);
		const useReference = !!reviewEntryId && !!referencedReview && reviewHash(referencedReview) === digest;
		return {
			schemaVersion: 2,
			session: { ...session },
			invocation: { ...record.invocation, autoPost: { ...record.invocation.autoPost } },
			repository: { ...record.repository },
			reviewHash: digest,
			...(useReference ? { reviewEntryId } : { review: record.review }),
		};
	}

	/** Restore only strictly validated state created by this exact Pi session instance. */
	restore(
		value: unknown,
		session: CompletedReviewSessionIdentity,
		referencedReview?: ReviewLike,
	): boolean {
		if (
			!isObject(value) ||
			value.schemaVersion !== 2 ||
			!validSessionIdentity(value.session) ||
			!sameSessionIdentity(value.session, session) ||
			!validRepositoryBinding(value.repository)
		) {
			return false;
		}
		const invocation = parsePersistedInvocation(value.invocation);
		if (!invocation || typeof value.reviewHash !== "string" || !/^[0-9a-f]{64}$/.test(value.reviewHash)) {
			return false;
		}
		const hasReference = typeof value.reviewEntryId === "string" && value.reviewEntryId.length > 0;
		const hasInlineReview = Object.prototype.hasOwnProperty.call(value, "review");
		if (hasReference === hasInlineReview) return false;
		const candidate = hasReference ? referencedReview : value.review;
		let parsed: PublishableReviewParseResult;
		try {
			parsed = parsePublishableReview(JSON.stringify(candidate));
		} catch {
			return false;
		}
		if (
			!parsed.review ||
			reviewHash(parsed.review) !== value.reviewHash ||
			!shouldPublishReview(parsed.review) ||
			validateReviewInvocation(parsed.review, invocation)
		) {
			return false;
		}
		this.remember(parsed.review, invocation, value.repository);
		return true;
	}

	/** Remove this exact record without deleting a newer completion for the same PR. */
	forget(record: CompletedReviewRecord): void {
		const key = completedReviewKey(record.repository, record.invocation.prNumber);
		if (this.reviews.get(key) === record) this.reviews.delete(key);
	}

	/** Undo a replacement only when this exact record is still current. */
	restoreReplacement(record: CompletedReviewRecord, previous: CompletedReviewRecord | undefined): void {
		const key = completedReviewKey(record.repository, record.invocation.prNumber);
		if (this.reviews.get(key) !== record) return;
		this.reviews.delete(key);
		if (previous) this.reviews.set(key, previous);
	}

	get(prNumber: number, repository: RepositoryBinding): CompletedReviewRecord | undefined {
		return this.reviews.get(completedReviewKey(repository, prNumber));
	}

	latest(repository: RepositoryBinding): CompletedReviewRecord | undefined {
		const records = [...this.reviews.values()];
		for (let index = records.length - 1; index >= 0; index--) {
			const record = records[index]!;
			if (completedReviewKey(record.repository, record.invocation.prNumber).startsWith(
				`${repository.hostname.toLowerCase()}:${repository.repository.toLowerCase()}:`,
			)) {
				return record;
			}
		}
		return undefined;
	}

	clear(): void {
		this.reviews.clear();
	}
}

function reviewFromSessionMessage(entry: CompletedReviewSessionEntryLike | undefined): ReviewLike | undefined {
	if (!entry || entry.type !== "message" || !isObject(entry.message) || entry.message.role !== "assistant") {
		return undefined;
	}
	const content = entry.message.content;
	const text = typeof content === "string"
		? content
		: Array.isArray(content)
			? content
					.filter((part) => isObject(part) && part.type === "text" && typeof part.text === "string")
					.map((part) => String(part.text))
					.join("")
			: "";
	return parsePublishableReview(text).review;
}

/** Rebuild cache state after session load, reload, resume, or tree navigation. */
export function restoreCompletedReviewBranch(
	cache: CompletedReviewCache,
	entries: CompletedReviewSessionEntryLike[],
	session: CompletedReviewSessionIdentity,
): number {
	cache.clear();
	const seenEntries = new Map<string, CompletedReviewSessionEntryLike>();
	let restored = 0;
	for (const entry of entries) {
		if (typeof entry.id === "string") seenEntries.set(entry.id, entry);
		if (entry.type !== "custom" || entry.customType !== COMPLETED_REVIEW_ENTRY_TYPE) continue;
		const reviewEntryId = isObject(entry.data) && typeof entry.data.reviewEntryId === "string"
			? entry.data.reviewEntryId
			: undefined;
		const referencedReview = reviewEntryId
			? reviewFromSessionMessage(seenEntries.get(reviewEntryId))
			: undefined;
		if (cache.restore(entry.data, session, referencedReview)) restored++;
	}
	return restored;
}

export interface PublishableReviewParseResult {
	review?: ReviewLike;
	error?: string;
}

function isObject(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function isConfidence(value: unknown): value is number {
	return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

/**
 * Strip a single surrounding Markdown fenced code block (```lang … ```) so a model
 * response that wraps the review object in a code fence — despite the instruction
 * to emit exactly one JSON object — can still be parsed without a repair round-trip.
 * Prose-wrapped or mixed drafts are intentionally left untouched (still rejected).
 * Returns the original text when there is no recognizable outer fence.
 */
function stripMarkdownCodeFence(text: string): string {
	const match = text.trim().match(/^```[^\n]*\n([\s\S]*)\n```[ \t]*$/);
	return match ? match[1] : text;
}

/**
 * Publication accepts one complete JSON object. A single surrounding Markdown code
 * fence is tolerated and stripped; prose-wrapped or partial drafts are rejected.
 */
export function parsePublishableReview(text: string): PublishableReviewParseResult {
	let value: unknown;
	try {
		value = JSON.parse(stripMarkdownCodeFence(text).trim());
	} catch {
		return { error: "final response is not exactly one JSON object" };
	}
	if (!isObject(value)) return { error: "final review must be a JSON object" };
	if (containsReservedReviewMarker(JSON.stringify(value))) {
		return { error: "review content contains a reserved pi-pr-review marker" };
	}
	const pr = value.pr;
	if (!isObject(pr) || !Number.isInteger(pr.number) || Number(pr.number) <= 0 || typeof pr.title !== "string") {
		return { error: "pr.number and pr.title are required" };
	}
	if (typeof pr.head_sha !== "string" || !/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(pr.head_sha)) {
		return { error: "pr.head_sha must be a full hexadecimal commit SHA" };
	}
	if (value.disposition !== "reviewed" && value.disposition !== "skipped") {
		return { error: "disposition must be reviewed or skipped" };
	}
	for (const key of ["verification", "overview", "overall_explanation"] as const) {
		if (typeof value[key] !== "string") return { error: `${key} must be a string` };
	}
	if (!Array.isArray(value.strengths) || !value.strengths.every((item) => typeof item === "string")) {
		return { error: "strengths must be an array of strings" };
	}
	if (!Array.isArray(value.findings)) return { error: "findings must be an array" };
	const severities = new Set(["P0", "P1", "P2", "P3", "nit"]);
	for (const [index, finding] of value.findings.entries()) {
		if (!isObject(finding)) return { error: `finding ${index + 1} must be an object` };
		if (typeof finding.title !== "string" || typeof finding.body !== "string") {
			return { error: `finding ${index + 1} title/body must be strings` };
		}
		if (typeof finding.severity !== "string" || !severities.has(finding.severity)) {
			return { error: `finding ${index + 1} has invalid severity` };
		}
		if (typeof finding.blocking !== "boolean" || finding.blocking !== ["P0", "P1"].includes(finding.severity)) {
			return { error: `finding ${index + 1} has inconsistent blocking value` };
		}
		if (!isConfidence(finding.confidence_score)) {
			return { error: `finding ${index + 1} has invalid confidence_score` };
		}
		const locationError = validateFindingLocation(finding as ReviewFindingLike, index);
		if (locationError) return { error: locationError };
	}
	if (!isObject(value.notes)) return { error: "notes must be an object" };
	for (const key of ["correctness", "security", "performance"] as const) {
		if (typeof value.notes[key] !== "string") return { error: `notes.${key} must be a string` };
	}
	if (!new Set(["approve", "request_changes", "comment"]).has(String(value.verdict))) {
		return { error: "verdict is invalid" };
	}
	if (!new Set(["patch is correct", "patch is incorrect"]).has(String(value.overall_correctness))) {
		return { error: "overall_correctness is invalid" };
	}
	if (!isConfidence(value.overall_confidence_score)) {
		return { error: "overall_confidence_score is invalid" };
	}
	return { review: value as unknown as ReviewLike };
}

export function shouldPublishReview(review: ReviewLike): boolean {
	return review.disposition === "reviewed";
}

interface DiffHunk {
	left: Set<number>;
	right: Set<number>;
}

function parsePatchHunks(patch: string): DiffHunk[] {
	const hunks: DiffHunk[] = [];
	let current: DiffHunk | undefined;
	let left = 0;
	let right = 0;
	for (const line of patch.split("\n")) {
		const header = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
		if (header) {
			left = Number(header[1]);
			right = Number(header[2]);
			current = { left: new Set<number>(), right: new Set<number>() };
			hunks.push(current);
			continue;
		}
		if (!current || line.startsWith("\\")) continue;
		if (line.startsWith("+")) {
			current.right.add(right++);
		} else if (line.startsWith("-")) {
			current.left.add(left++);
		} else if (line.startsWith(" ")) {
			current.left.add(left++);
			current.right.add(right++);
		}
	}
	return hunks;
}

export interface ChangedFileLike {
	filename?: string;
	patch?: string;
}

function safeRelativePath(value: string): boolean {
	if (!value || value.startsWith("/") || value.includes("\\") || /[\0-\x1f\x7f]/.test(value)) return false;
	const segments = value.split("/");
	return segments.every((segment) => segment !== "" && segment !== "." && segment !== "..");
}

function validateFindingLocation(finding: ReviewFindingLike, index: number): string | undefined {
	const location = finding.code_location;
	const label = `finding ${index + 1}`;
	if (location === null) return undefined;
	if (!isObject(location) || typeof location.commentable !== "boolean") {
		return `${label} has invalid code_location`;
	}
	const path = location.absolute_file_path;
	if (path !== null && typeof path !== "string") return `${label} has invalid absolute_file_path`;
	const side = location.side;
	if (side !== null && side !== "LEFT" && side !== "RIGHT") return `${label} has invalid side`;
	const range = location.line_range;
	if (!isObject(range) || !Number.isInteger(range.start) || !Number.isInteger(range.end)) {
		return `${label} has invalid line_range`;
	}
	const start = Number(range.start);
	const end = Number(range.end);
	if (path === null) {
		if (location.commentable) return `${label}: commentable location is missing a repo-relative path`;
		if (side !== null || start !== 0 || end !== 0) {
			return `${label}: location without a path must use null side and a 0:0 range`;
		}
		return undefined;
	}
	if (!safeRelativePath(path)) return `${label}: invalid repo-relative path`;
	if (side !== "LEFT" && side !== "RIGHT") return `${label}: side must be LEFT or RIGHT`;
	if (start <= 0 || end < start) return `${label}: invalid line range`;
	return undefined;
}

function isInlineSeverity(finding: ReviewFindingLike): boolean {
	const severity = String(finding.severity ?? "").toUpperCase();
	return ["P0", "P1", "P2", "P3"].includes(severity);
}

function publishCommentAnchor(comment: PublishComment): string {
	return `${comment.path}:${comment.side}:${comment.start_line ?? comment.line}:${comment.line}`;
}

function cell(value: string): string {
	return value.replace(/\|/g, "\\|").replace(/\r?\n/g, " ").trim();
}

function findingLocation(finding: ReviewFindingLike): string {
	const location = finding.code_location;
	if (!location?.absolute_file_path) return "summary-only";
	const start = location.line_range?.start;
	const end = location.line_range?.end;
	if (!Number.isInteger(start) || !Number.isInteger(end)) return location.absolute_file_path;
	return `${location.absolute_file_path}:${start}${end !== start ? `-${end}` : ""} ${(location.side ?? "RIGHT").toUpperCase()}`;
}

function findingAnchor(finding: ReviewFindingLike): string | undefined {
	const location = finding.code_location;
	const path = location?.absolute_file_path;
	const side = location?.side?.toUpperCase();
	const start = location?.line_range?.start;
	const end = location?.line_range?.end;
	if (!path || (side !== "LEFT" && side !== "RIGHT") || !Number.isInteger(start) || !Number.isInteger(end)) {
		return undefined;
	}
	return `${path}:${side}:${start}:${end}`;
}

export function buildReviewSummary(review: ReviewLike, inlineComments: PublishComment[] = []): string {
	const lines: string[] = [];
	const number = review.pr?.number;
	const title = String(review.pr?.title ?? "").replace(/\r?\n/g, " ").trim();
	lines.push(`## Code Review${number != null ? ` — PR #${number}${title ? `: ${title}` : ""}` : ""}`, "");
	if (review.verification?.trim()) lines.push(`**Verification:** ${review.verification.trim()}`, "");
	if (review.overview?.trim()) lines.push("### Overview", "", review.overview.trim(), "");
	if (review.strengths?.length) {
		lines.push("### Strengths", "", ...review.strengths.map((strength) => `- ${String(strength).replace(/^\s*-\s*/, "").trim()}`), "");
	}
	const findings = Array.isArray(review.findings) ? review.findings : [];
	const inlineAnchors = new Map<string, number>();
	for (const comment of inlineComments) {
		const anchor = publishCommentAnchor(comment);
		inlineAnchors.set(anchor, (inlineAnchors.get(anchor) ?? 0) + 1);
	}
	const summaryFindings = findings.filter((finding) => {
		if (!finding.code_location?.commentable || !isInlineSeverity(finding)) return true;
		const anchor = findingAnchor(finding);
		if (!anchor) return true;
		const remaining = inlineAnchors.get(anchor) ?? 0;
		if (remaining === 0) return true;
		if (remaining === 1) inlineAnchors.delete(anchor);
		else inlineAnchors.set(anchor, remaining - 1);
		return false;
	});
	lines.push(
		`### Findings — ${findings.length} total (${inlineComments.length} inline, ${summaryFindings.length} summary-only)`,
		"",
	);
	if (findings.length === 0) {
		lines.push("_No issues found._", "");
	} else if (summaryFindings.length === 0) {
		lines.push(`_All ${inlineComments.length} findings are attached inline below this review._`, "");
	} else {
		lines.push("| Severity | Summary-only finding | Location |", "|---|---|---|");
		for (const finding of summaryFindings) {
			lines.push(
				`| ${cell(String(finding.severity ?? "—"))} | ${cell(String(finding.title ?? "(untitled)"))} | \`${cell(findingLocation(finding))}\` |`,
			);
		}
		lines.push("");
		for (const finding of summaryFindings) {
			lines.push(`#### ${String(finding.title ?? "Finding")}`, `\`${findingLocation(finding)}\``, "");
			if (finding.body?.trim()) lines.push(finding.body.trim(), "");
		}
	}
	const notes = review.notes;
	if (notes?.correctness || notes?.security || notes?.performance) {
		lines.push("### Correctness / Security / Performance", "");
		if (notes.correctness) lines.push(`- **Correctness:** ${notes.correctness}`);
		if (notes.security) lines.push(`- **Security:** ${notes.security}`);
		if (notes.performance) lines.push(`- **Performance:** ${notes.performance}`);
		lines.push("");
	}
	lines.push("### Verdict", "", `**Suggested verdict:** ${review.verdict ?? "comment"}`);
	if (review.overall_explanation?.trim()) lines.push("", review.overall_explanation.trim());
	if (typeof review.overall_confidence_score === "number") {
		lines.push("", `_Confidence: ${review.overall_confidence_score.toFixed(2)}_`);
	}
	return lines.join("\n").trim();
}

interface InlineSelection {
	comments: PublishComment[];
	diagnostics: string[];
	errors: string[];
}

function buildPublishComment(
	path: string,
	body: string,
	side: "LEFT" | "RIGHT",
	start: number,
	end: number,
): PublishComment {
	return {
		path,
		body,
		line: end,
		side,
		...(start < end ? { start_line: start, start_side: side } : {}),
	};
}

function selectInlineComments(
	review: ReviewLike,
	changedFiles: readonly ChangedFileLike[],
): InlineSelection {
	const files = new Map<string, ChangedFileLike>();
	for (const file of changedFiles) {
		if (!file || typeof file.filename !== "string") continue;
		const existing = files.get(file.filename);
		if (!existing || (!existing.patch && file.patch)) files.set(file.filename, file);
	}
	const comments: PublishComment[] = [];
	const diagnostics: string[] = [];
	const errors: string[] = [];
	const anchors = new Set<string>();
	const hunkCache = new Map<string, DiffHunk[]>();
	for (const [index, finding] of (review.findings ?? []).entries()) {
		const locationError = finding.code_location === undefined
			? undefined
			: validateFindingLocation(finding, index);
		if (locationError) {
			errors.push(locationError);
			continue;
		}
		if (!finding.code_location?.commentable || !isInlineSeverity(finding)) continue;
		const location = finding.code_location;
		const label = `finding ${index + 1}`;
		const path = location.absolute_file_path as string;
		const side = location.side as "LEFT" | "RIGHT";
		const start = Number(location.line_range?.start);
		const end = Number(location.line_range?.end);
		const body = [
			finding.title?.trim() ? `**${finding.title.trim()}**` : "",
			finding.body?.trim(),
		].filter(Boolean).join("\n\n");
		if (!body || Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES) {
			errors.push(`${label}: comment body is empty or too large`);
			continue;
		}
		if (containsReservedReviewMarker(body)) {
			errors.push(`${label}: comment body contains a reserved pi-pr-review marker`);
			continue;
		}
		const comment = buildPublishComment(path, body, side, start, end);
		const file = files.get(path);
		if (!file) {
			diagnostics.push(`${label}: path is not a changed file; kept in the review summary`);
			continue;
		}
		if (typeof file.patch !== "string" || file.patch.length === 0) {
			diagnostics.push(`${label}: diff patch is unavailable; kept in the review summary`);
			continue;
		}
		let hunks = hunkCache.get(path);
		if (!hunks) {
			hunks = parsePatchHunks(file.patch);
			hunkCache.set(path, hunks);
		}
		const sideKey = side === "LEFT" ? "left" : "right";
		if (!hunks.some((hunk) => hunk[sideKey].has(start) && hunk[sideKey].has(end))) {
			diagnostics.push(
				`${label}: line range is not inside one diff hunk on ${side}; kept in the review summary`,
			);
			continue;
		}
		const anchor = publishCommentAnchor(comment);
		if (anchors.has(anchor)) {
			diagnostics.push(`${label}: duplicate inline anchor; kept in the review summary`);
			continue;
		}
		anchors.add(anchor);
		if (comments.length >= MAX_INLINE_COMMENTS) {
			diagnostics.push(
				`${label}: inline comment limit of ${MAX_INLINE_COMMENTS} reached; kept in the review summary`,
			);
			continue;
		}
		comments.push(comment);
	}
	return { comments, diagnostics, errors };
}

export interface CommentValidationResult {
	comments: PublishComment[];
	errors: string[];
	warnings?: string[];
}

function canonicalReviewSnapshot(review: ReviewLike): PublishableReviewParseResult {
	let serialized: string | undefined;
	try {
		serialized = JSON.stringify(review);
	} catch {
		return { error: "review could not be serialized for publication" };
	}
	if (typeof serialized !== "string") {
		return { error: "review could not be serialized for publication" };
	}
	return parsePublishableReview(serialized);
}

export function validateInlineComments(
	review: ReviewLike,
	changedFiles: readonly ChangedFileLike[],
): CommentValidationResult {
	const selected = selectInlineComments(review, changedFiles);
	return {
		comments: selected.comments,
		errors: selected.errors,
		warnings: selected.diagnostics,
	};
}

/** Compatibility helper for callers that fold would-be inline findings into a body-only review. */
export function collectFoldedComments(review: ReviewLike): CommentValidationResult {
	const comments: PublishComment[] = [];
	const errors: string[] = [];
	for (const [index, finding] of (review.findings ?? []).entries()) {
		const location = finding.code_location;
		if (!location?.commentable || !isInlineSeverity(finding)) continue;
		const path = String(location.absolute_file_path ?? "");
		const side = String(location.side ?? "").toUpperCase();
		const start = location.line_range?.start;
		const end = location.line_range?.end;
		const label = `finding ${index + 1}`;
		if (!safeRelativePath(path) || (side !== "LEFT" && side !== "RIGHT")) {
			errors.push(`${label}: invalid folded inline location`);
			continue;
		}
		if (!Number.isInteger(start) || !Number.isInteger(end) || Number(start) <= 0 || Number(end) < Number(start)) {
			errors.push(`${label}: invalid folded line range`);
			continue;
		}
		const body = [`**${String(finding.title ?? "Review finding").trim()}**`, finding.body?.trim()]
			.filter(Boolean)
			.join("\n\n");
		if (!body || Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES) {
			errors.push(`${label}: folded comment body is empty or too large`);
			continue;
		}
		if (containsReservedReviewMarker(body)) {
			errors.push(`${label}: folded comment body contains a reserved pi-pr-review marker`);
			continue;
		}
		comments.push(buildPublishComment(path, body, side, Number(start), Number(end)));
	}
	return { comments, errors, warnings: [] };
}

/** Compatibility formatter for body-only reviews assembled by earlier consumers. */
export function foldInlineComments(summary: string, comments: PublishComment[]): string {
	if (comments.length === 0) return summary;
	const lines = [summary, "", "### Inline findings (folded for a non-open PR)", ""];
	for (const comment of comments) {
		const range = comment.start_line ? `${comment.start_line}-${comment.line}` : String(comment.line);
		lines.push(`#### \`${comment.path}:${range} ${comment.side}\``, "", comment.body, "");
	}
	return lines.join("\n").trim();
}

export function containsReservedReviewMarker(body: string): boolean {
	return body.toLowerCase().includes(RESERVED_MARKER_PREFIX);
}

function validateReviewBody(body: string): string | undefined {
	if (!body.trim()) return "review body is empty";
	if (containsReservedReviewMarker(body)) return "review content contains a reserved pi-pr-review marker";
	if (Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES) return "review body exceeds 65536 UTF-8 bytes";
	return undefined;
}

function hasInlineCandidates(review: ReviewLike): boolean {
	return (review.findings ?? []).some(
		(finding) => finding.code_location?.commentable === true && isInlineSeverity(finding),
	);
}

function buildLosslessReviewPayload(input: {
	review: ReviewLike;
	commitId: string;
	markerHeadSha: string;
	allowInlineComments: boolean;
	changedFiles?: readonly ChangedFileLike[];
	bodyPreamble?: string;
	diagnostics?: readonly string[];
	event?: ReviewEventType;
}): { payload?: PullReviewPayload; diagnostics: string[]; errors: string[] } {
	const diagnostics = [...(input.diagnostics ?? [])];
	if (!/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(input.commitId)) {
		return { diagnostics, errors: ["publication commit ID must be a full hexadecimal commit SHA"] };
	}
	if (!/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(input.markerHeadSha)) {
		return { diagnostics, errors: ["publication marker head must be a full hexadecimal commit SHA"] };
	}
	const markerHeadSha = input.markerHeadSha.toLowerCase();
	if (input.review.pr?.head_sha?.toLowerCase() !== markerHeadSha) {
		return { diagnostics, errors: ["publication marker head does not match the validated review head"] };
	}
	if (input.bodyPreamble && containsReservedReviewMarker(input.bodyPreamble)) {
		return { diagnostics, errors: ["publication preamble contains a reserved pi-pr-review marker"] };
	}
	const selected = input.allowInlineComments
		? selectInlineComments(input.review, input.changedFiles ?? [])
		: { comments: [], diagnostics: [], errors: [] };
	diagnostics.push(...selected.diagnostics);
	if (selected.errors.length > 0) return { diagnostics, errors: selected.errors };

	let content = buildReviewSummary(input.review, selected.comments);
	if (diagnostics.length > 0) {
		content = `${content}\n\n### Publication diagnostics\n\n${diagnostics.map((item) => `- ${item}`).join("\n")}`;
	}
	if (input.bodyPreamble?.trim()) content = `${input.bodyPreamble.trim()}\n\n${content}`;
	const bodyError = validateReviewBody(content);
	if (bodyError) return { diagnostics, errors: [bodyError] };
	const body = `${content}\n\n${canonicalReviewMarker(markerHeadSha)}`;
	if (Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES) {
		return { diagnostics, errors: ["final review body exceeds 65536 UTF-8 bytes"] };
	}
	const payload = buildPullReviewPayload(
		input.commitId.toLowerCase(),
		body,
		selected.comments,
		input.event ?? REVIEW_EVENT,
	);
	if (Buffer.byteLength(JSON.stringify(payload), "utf8") > MAX_PAYLOAD_BYTES) {
		return { diagnostics, errors: ["review payload is too large"] };
	}
	return { payload, diagnostics, errors: [] };
}

interface GhResult {
	stdout: string;
	stderr: string;
	exitCode: number;
	timedOut: boolean;
	errorMessage?: string;
}

function runGh(args: string[], cwd: string, input?: string, timeoutMs = 60_000): Promise<GhResult> {
	return new Promise((resolve) => {
		let settled = false;
		let stdout = "";
		let stderr = "";
		let timer: ReturnType<typeof setTimeout> | undefined;
		const finish = (result: GhResult) => {
			if (settled) return;
			settled = true;
			if (timer) clearTimeout(timer);
			resolve(result);
		};
		const proc = spawn("gh", args, { cwd, shell: false, stdio: ["pipe", "pipe", "pipe"] });
		proc.stdout.on("data", (data) => (stdout += data.toString()));
		proc.stderr.on("data", (data) => (stderr += data.toString()));
		proc.stdin.on("error", (error) => {
			const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
			if (!settled && code !== "EPIPE") stderr += error.message;
		});
		proc.on("error", (error) =>
			finish({ stdout, stderr, exitCode: 1, timedOut: false, errorMessage: error.message }),
		);
		proc.on("close", (code) => finish({ stdout, stderr, exitCode: code ?? 1, timedOut: false }));
		if (input !== undefined) proc.stdin.end(input);
		else proc.stdin.end();
		timer = setTimeout(() => {
			proc.kill("SIGTERM");
			setTimeout(() => proc.kill("SIGKILL"), 3000);
			finish({ stdout, stderr, exitCode: 1, timedOut: true, errorMessage: "gh command timed out" });
		}, timeoutMs);
	});
}

async function ghText(args: string[], cwd: string): Promise<string> {
	const result = await runGh(args, cwd);
	if (result.exitCode !== 0) throw new Error(result.errorMessage || result.stderr || "gh command failed");
	return result.stdout.trim();
}

async function ghJson<T>(args: string[], cwd: string): Promise<T> {
	const text = await ghText(args, cwd);
	return JSON.parse(text) as T;
}

export async function resolveRepositoryBinding(cwd: string): Promise<RepositoryBinding> {
	const repoInfo = await ghJson<{ nameWithOwner?: string; url?: string }>(
		["repo", "view", "--json", "nameWithOwner,url"],
		cwd,
	);
	const repository = String(repoInfo.nameWithOwner ?? "");
	const hostname = new URL(String(repoInfo.url ?? "")).hostname;
	const binding = { repository, hostname };
	if (!validRepositoryBinding(binding)) throw new Error("invalid GitHub repository or hostname");
	return binding;
}

function normalizeChangedFilePages(value: unknown): ChangedFileLike[] | undefined {
	if (!Array.isArray(value)) return undefined;
	if (value.some(Array.isArray) && !value.every(Array.isArray)) return undefined;
	const entries: unknown[] = value.every(Array.isArray) ? value.flat() : value;
	const files: ChangedFileLike[] = [];
	for (const entry of entries) {
		if (!isObject(entry) || typeof entry.filename !== "string") return undefined;
		if (entry.patch !== undefined && entry.patch !== null && typeof entry.patch !== "string") {
			return undefined;
		}
		files.push({
			filename: entry.filename,
			...(typeof entry.patch === "string" ? { patch: entry.patch } : {}),
		});
	}
	return files;
}

interface AuthoredBody {
	body: string | null;
	user: { login: string | null } | null;
}

function normalizeAuthoredBodyPages(value: unknown): AuthoredBody[] | undefined {
	if (!Array.isArray(value)) return undefined;
	if (value.some(Array.isArray) && !value.every(Array.isArray)) return undefined;
	const entries: unknown[] = value.every(Array.isArray) ? value.flat() : value;
	const authoredBodies: AuthoredBody[] = [];
	for (const entry of entries) {
		if (!isObject(entry) || (entry.body !== null && typeof entry.body !== "string")) {
			return undefined;
		}
		const user = entry.user;
		if (user === null) {
			authoredBodies.push({ body: entry.body, user: null });
			continue;
		}
		if (!isObject(user)) return undefined;
		const login = user.login;
		if (login !== null && typeof login !== "string") return undefined;
		authoredBodies.push({ body: entry.body, user: { login } });
	}
	return authoredBodies;
}

export function bodyHasHeadMarker(body: string | null | undefined, normalizedHeadSha: string): boolean {
	if (!body) return false;
	const marker = /<!-- pi-pr-review: \{"schema":1,"headRefOid":"([0-9a-f]{40}(?:[0-9a-f]{24})?)"\} -->/gi;
	for (const match of body.matchAll(marker)) {
		if (match[1]?.toLowerCase() === normalizedHeadSha) return true;
	}
	return false;
}

async function hasExistingMarker(
	cwd: string,
	hostname: string,
	repository: string,
	prNumber: number,
	identity: string,
	normalizedHeadSha: string,
): Promise<boolean> {
	const reviewPages = await ghJson<unknown>(
		githubApiArgs(hostname, "--paginate", "--slurp", `repos/${repository}/pulls/${prNumber}/reviews?per_page=100`),
		cwd,
	);
	const reviews = normalizeAuthoredBodyPages(reviewPages);
	if (!reviews) throw new Error("invalid paginated pull review response");
	const commentPages = await ghJson<unknown>(
		githubApiArgs(hostname, "--paginate", "--slurp", `repos/${repository}/issues/${prNumber}/comments?per_page=100`),
		cwd,
	);
	const comments = normalizeAuthoredBodyPages(commentPages);
	if (!comments) throw new Error("invalid paginated issue comment response");
	return [...reviews, ...comments].some(
		(item) =>
			item.user?.login?.toLowerCase() === identity.toLowerCase() &&
			bodyHasHeadMarker(item.body, normalizedHeadSha),
	);
}

interface PullState {
	state?: string;
	draft?: boolean;
	merged_at?: string | null;
	head?: { sha?: string };
	user?: { login?: string };
}

export interface HeadPublicationPlan {
	reviewedHeadSha: string;
	currentHeadSha: string;
	stale: boolean;
	commitId: string;
	allowInlineComments: boolean;
}

/** Authorize a reviewed/current head pairing without silently weakening stale protection. */
export function planHeadPublication(
	reviewedHeadSha: string,
	currentHeadSha: string | undefined,
	allowStale: boolean,
): { plan?: HeadPublicationPlan; error?: string } {
	const reviewed = reviewedHeadSha.toLowerCase();
	const current = currentHeadSha?.toLowerCase();
	if (!current || !/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/.test(current)) {
		return { error: "GitHub returned an invalid current PR head SHA" };
	}
	const stale = current !== reviewed;
	if (stale && !allowStale) {
		return {
			error: `PR head changed after review (${reviewed} -> ${current}); refusing to publish stale results. Use /pr-review-publish with --allow-stale to post the completed review without rerunning it`,
		};
	}
	return {
		plan: {
			reviewedHeadSha: reviewed,
			currentHeadSha: current,
			stale,
			commitId: stale ? current : reviewed,
			allowInlineComments: !stale,
		},
	};
}

export function buildStaleReviewNotice(reviewedHeadSha: string, currentHeadSha: string): string {
	return [
		"> [!WARNING]",
		`> This review was generated for commit \`${reviewedHeadSha}\`. At publish preflight, the PR pointed to \`${currentHeadSha}\`.`,
		"> Inline findings were folded into this body because their original diff anchors may be stale.",
	].join("\n");
}

export type PullLifecycle = "open" | "non_open";

export function authorizePullLifecycle(
	state: string | undefined,
	mergedAt: string | null | undefined,
	allowNonOpen: boolean,
): { lifecycle?: PullLifecycle; error?: string } {
	const normalized = state?.toLowerCase();
	if (normalized === "open" && !mergedAt) return { lifecycle: "open" };
	if (normalized === "closed" || !!mergedAt) {
		return allowNonOpen
			? { lifecycle: "non_open" }
			: { error: "closed or merged PR publication was not authorized by the invocation" };
	}
	return { error: `unknown PR lifecycle state: ${state ?? "missing"}` };
}

export type PublishStatus =
	| "skipped_duplicate"
	| "posted"
	| "posted_degraded"
	| "failed"
	| "indeterminate";

export interface PublishResult {
	status: PublishStatus;
	message: string;
	event?: ReviewEventType;
	reviewId?: number;
	url?: string;
	reconciled?: boolean;
}

const publishLocks = new Map<string, Promise<void>>();

async function withPublishLock<T>(key: string, operation: () => Promise<T>): Promise<T> {
	const previous = publishLocks.get(key) ?? Promise.resolve();
	let release = () => {};
	const gate = new Promise<void>((resolve) => {
		release = resolve;
	});
	const chain = previous.then(() => gate);
	publishLocks.set(key, chain);
	await previous;
	try {
		return await operation();
	} finally {
		release();
		if (publishLocks.get(key) === chain) publishLocks.delete(key);
	}
}

/** Publish a model-formatted body through the same host-owned GitHub write boundary. */
export async function publishPullReviewBody(input: {
	cwd: string;
	prNumber: number;
	headSha: string;
	allowNonOpen: boolean;
	allowStale?: boolean;
	expectedRepository?: RepositoryBinding;
	body: string;
}): Promise<PublishResult> {
	const {
		cwd,
		prNumber,
		headSha,
		allowNonOpen,
		allowStale = false,
		expectedRepository,
		body,
	} = input;
	if (!Number.isInteger(prNumber) || prNumber <= 0) return { status: "failed", message: "invalid PR number" };
	if (!/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(headSha)) return { status: "failed", message: "invalid head SHA" };
	const normalizedHeadSha = headSha.toLowerCase();
	const bodyError = validateReviewBody(body);
	if (bodyError) return { status: "failed", message: `publication planning failed: ${bodyError}` };

	let repository: string;
	let hostname: string;
	let identity: string;
	try {
		const binding = await resolveRepositoryBinding(cwd);
		repository = binding.repository;
		hostname = binding.hostname;
		if (
			expectedRepository &&
			completedReviewKey(expectedRepository, prNumber) !== completedReviewKey(binding, prNumber)
		) {
			return { status: "failed", message: "current GitHub repository does not match the fallback review repository" };
		}
		identity = await ghText(githubApiArgs(hostname, "user", "--jq", ".login"), cwd);
	} catch (error) {
		return { status: "failed", message: `GitHub identity/repository lookup failed: ${String(error)}` };
	}
	if (!identity) return { status: "failed", message: "invalid GitHub identity" };

	const lockKey = `${hostname}:${repository}:${prNumber}:${normalizedHeadSha}:${identity.toLowerCase()}`;
	return withPublishLock(lockKey, async () => {
		let pull: PullState;
		let headPlan: HeadPublicationPlan;
		let isOpen: boolean;
		try {
			pull = await ghJson<PullState>(githubApiArgs(hostname, `repos/${repository}/pulls/${prNumber}`), cwd);
			const planned = planHeadPublication(normalizedHeadSha, pull.head?.sha, allowStale);
			if (!planned.plan) return { status: "failed", message: planned.error ?? "invalid PR head" };
			headPlan = planned.plan;
			if (pull.draft) return { status: "failed", message: "draft PR reviews are not automatically published" };
			const lifecycle = authorizePullLifecycle(pull.state, pull.merged_at, allowNonOpen);
			if (!lifecycle.lifecycle) return { status: "failed", message: lifecycle.error ?? "invalid PR lifecycle" };
			isOpen = lifecycle.lifecycle === "open";
			if (await hasExistingMarker(cwd, hostname, repository, prNumber, identity, normalizedHeadSha)) {
				return { status: "skipped_duplicate", message: "same head already reviewed by this GitHub identity" };
			}
		} catch (error) {
			return { status: "failed", message: `GitHub preflight failed: ${String(error)}` };
		}

		const content = headPlan.stale
			? `${buildStaleReviewNotice(headPlan.reviewedHeadSha, headPlan.currentHeadSha)}\n\n${body.trim()}`
			: body.trim();
		const finalBody = `${content}\n\n${canonicalReviewMarker(normalizedHeadSha)}`;
		if (Buffer.byteLength(finalBody, "utf8") > MAX_BODY_BYTES) {
			return { status: "failed", message: "publication planning failed: final review body exceeds 65536 UTF-8 bytes" };
		}
		const payload = buildPullReviewPayload(headPlan.commitId, finalBody, []);
		if (Buffer.byteLength(JSON.stringify(payload), "utf8") > MAX_PAYLOAD_BYTES) {
			return { status: "failed", message: "publication planning failed: review payload is too large" };
		}

		try {
			const refreshed = await ghJson<PullState>(
				githubApiArgs(hostname, `repos/${repository}/pulls/${prNumber}`),
				cwd,
			);
			if (refreshed.head?.sha?.toLowerCase() !== headPlan.currentHeadSha) {
				return { status: "failed", message: "PR head changed during publish preflight" };
			}
			if (refreshed.draft) return { status: "failed", message: "PR became a draft during publish preflight" };
			const lifecycle = authorizePullLifecycle(refreshed.state, refreshed.merged_at, allowNonOpen);
			if (!lifecycle.lifecycle) return { status: "failed", message: lifecycle.error ?? "invalid refreshed PR lifecycle" };
			if ((lifecycle.lifecycle === "open") !== isOpen) {
				return { status: "failed", message: "PR open/closed state changed during publish preflight" };
			}
		} catch (error) {
			return { status: "failed", message: `final head check failed: ${String(error)}` };
		}

		const degraded = !isOpen || headPlan.stale;
		const post = await runGh(
			githubApiArgs(hostname, "--method", "POST", `repos/${repository}/pulls/${prNumber}/reviews`, "--input", "-"),
			cwd,
			JSON.stringify(payload),
		);
		if (post.exitCode === 0) {
			let response: { id?: number; html_url?: string } = {};
			try {
				response = JSON.parse(post.stdout);
			} catch {
				/* GitHub accepted the POST even if response metadata is unavailable. */
			}
			return {
				status: degraded ? "posted_degraded" : "posted",
				message: headPlan.stale
					? `body-only stale COMMENT review posted (${headPlan.reviewedHeadSha} -> ${headPlan.currentHeadSha})`
					: isOpen ? "GitHub COMMENT review posted" : "body-only COMMENT review posted for non-open PR",
				event: REVIEW_EVENT,
				reviewId: response.id,
				url: response.html_url,
			};
		}

		try {
			if (await hasExistingMarker(cwd, hostname, repository, prNumber, identity, normalizedHeadSha)) {
				return {
					status: degraded ? "posted_degraded" : "posted",
					message: "GitHub COMMENT review found during failure reconciliation",
					event: REVIEW_EVENT,
					reconciled: true,
				};
			}
		} catch {
			/* reconciliation failure is handled below */
		}
		const detail = post.errorMessage || post.stderr || "gh review request failed";
		if (/HTTP\s+4\d\d/i.test(detail) && !post.timedOut) return { status: "failed", message: detail };
		return { status: "indeterminate", message: `${detail}; no matching marker found after reconciliation` };
	});
}

export async function publishPullReview(input: {
	cwd: string;
	prNumber: number;
	headSha: string;
	allowNonOpen: boolean;
	allowStale?: boolean;
	allowStaleApprovals?: boolean;
	approveMaxPriorityLevel?: ApproveMaxPriorityLevel;
	expectedRepository?: RepositoryBinding;
	review: ReviewLike;
}): Promise<PublishResult> {
	const {
		cwd,
		prNumber,
		headSha,
		allowNonOpen,
		allowStale = false,
		allowStaleApprovals = false,
		approveMaxPriorityLevel = "off",
		expectedRepository,
		review,
	} = input;
	if (!Number.isInteger(prNumber) || prNumber <= 0) return { status: "failed", message: "invalid PR number" };
	if (!/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(headSha)) return { status: "failed", message: "invalid head SHA" };
	const normalizedHeadSha = headSha.toLowerCase();
	const snapshot = canonicalReviewSnapshot(review);
	const validatedReview = snapshot.review;
	if (!validatedReview) {
		return {
			status: "failed",
			message: `publication planning failed: ${snapshot.error ?? "review is not publishable"}`,
		};
	}
	if (!shouldPublishReview(validatedReview)) {
		return { status: "failed", message: "only completed reviewed dispositions can be published" };
	}
	if (validatedReview.pr?.number !== prNumber) {
		return { status: "failed", message: "validated review PR number does not match the publication target" };
	}
	if (validatedReview.pr?.head_sha?.toLowerCase() !== normalizedHeadSha) {
		return { status: "failed", message: "validated review head does not match the publication target" };
	}

	let repository: string;
	let hostname: string;
	let identity: string;
	try {
		const binding = await resolveRepositoryBinding(cwd);
		repository = binding.repository;
		hostname = binding.hostname;
		if (
			expectedRepository &&
			completedReviewKey(expectedRepository, prNumber) !== completedReviewKey(binding, prNumber)
		) {
			return { status: "failed", message: "current GitHub repository does not match the cached review repository" };
		}
		identity = await ghText(githubApiArgs(hostname, "user", "--jq", ".login"), cwd);
	} catch (error) {
		return { status: "failed", message: `GitHub identity/repository lookup failed: ${String(error)}` };
	}
	if (!identity) return { status: "failed", message: "invalid GitHub identity" };

	const lockKey = `${hostname}:${repository}:${prNumber}:${normalizedHeadSha}:${identity.toLowerCase()}`;
	return withPublishLock(lockKey, async () => {
		let pull: PullState;
		let headPlan: HeadPublicationPlan;
		try {
			pull = await ghJson<PullState>(githubApiArgs(hostname, `repos/${repository}/pulls/${prNumber}`), cwd);
			const planned = planHeadPublication(normalizedHeadSha, pull.head?.sha, allowStale);
			if (!planned.plan) return { status: "failed", message: planned.error ?? "invalid PR head" };
			headPlan = planned.plan;
			if (pull.draft) return { status: "failed", message: "draft PR reviews are not automatically published" };
			const lifecycle = authorizePullLifecycle(pull.state, pull.merged_at, allowNonOpen);
			if (!lifecycle.lifecycle) return { status: "failed", message: lifecycle.error ?? "invalid PR lifecycle" };
			if (await hasExistingMarker(cwd, hostname, repository, prNumber, identity, normalizedHeadSha)) {
				return { status: "skipped_duplicate", message: "same head already reviewed by this GitHub identity" };
			}
		} catch (error) {
			return { status: "failed", message: `GitHub preflight failed: ${String(error)}` };
		}

		const lifecycle = authorizePullLifecycle(pull.state, pull.merged_at, allowNonOpen);
		if (!lifecycle.lifecycle) return { status: "failed", message: lifecycle.error ?? "invalid PR lifecycle" };
		const isOpen = lifecycle.lifecycle === "open";
		let allowInlineComments = isOpen && headPlan.allowInlineComments;
		let changedFiles: readonly ChangedFileLike[] = [];
		let changedFileLookupFailed = false;
		if (allowInlineComments && hasInlineCandidates(validatedReview)) {
			try {
				const filePages = await ghJson<unknown>(
					githubApiArgs(hostname, "--paginate", "--slurp", `repos/${repository}/pulls/${prNumber}/files?per_page=100`),
					cwd,
				);
				const normalizedFiles = normalizeChangedFilePages(filePages);
				if (!normalizedFiles) throw new Error("invalid changed-file JSON response");
				changedFiles = normalizedFiles;
			} catch {
				allowInlineComments = false;
				changedFileLookupFailed = true;
			}
		}
		// Stale publication authorization is independent from merge-relevant stale
		// approval. The latter requires its own explicit frozen config opt-in.
		// GitHub rejects a formal APPROVE from the PR author. Downgrade before the
		// single write rather than retrying a rejected review as COMMENT.
		const isSelfAuthored = pull.user?.login?.toLowerCase() === identity.toLowerCase();
		const isApprove =
			!isSelfAuthored &&
			(!headPlan.stale || allowStaleApprovals) &&
			shouldApproveReview(validatedReview, approveMaxPriorityLevel);
		const built = buildLosslessReviewPayload({
			review: validatedReview,
			commitId: headPlan.commitId,
			markerHeadSha: normalizedHeadSha,
			allowInlineComments,
			changedFiles,
			...(isApprove ? { event: APPROVE_EVENT } : {}),
			...(changedFileLookupFailed ? { diagnostics: [CHANGED_FILE_LOOKUP_DIAGNOSTIC] } : {}),
			...(headPlan.stale
				? { bodyPreamble: buildStaleReviewNotice(headPlan.reviewedHeadSha, headPlan.currentHeadSha) }
				: {}),
		});
		if (!built.payload) {
			return { status: "failed", message: `publication planning failed: ${built.errors.join("; ")}` };
		}
		const payload = built.payload;

		try {
			const refreshed = await ghJson<PullState>(
				githubApiArgs(hostname, `repos/${repository}/pulls/${prNumber}`),
				cwd,
			);
			if (refreshed.head?.sha?.toLowerCase() !== headPlan.currentHeadSha) {
				return {
					status: "failed",
					message: "PR head changed during publish preflight; run the publish-only command again to acknowledge the new current head",
				};
			}
			if (refreshed.draft) return { status: "failed", message: "PR became a draft during publish preflight" };
			const refreshedLifecycle = authorizePullLifecycle(refreshed.state, refreshed.merged_at, allowNonOpen);
			if (!refreshedLifecycle.lifecycle) {
				return { status: "failed", message: refreshedLifecycle.error ?? "invalid refreshed PR lifecycle" };
			}
			if ((refreshedLifecycle.lifecycle === "open") !== isOpen) {
				return { status: "failed", message: "PR open/closed state changed during publish preflight" };
			}
		} catch (error) {
			return { status: "failed", message: `final head check failed: ${String(error)}` };
		}

		const inlineWarning = built.diagnostics.length === 0
			? ""
			: changedFileLookupFailed
				? `; ${CHANGED_FILE_LOOKUP_DIAGNOSTIC}`
				: `; ${built.diagnostics.length} inline finding${built.diagnostics.length === 1 ? "" : "s"} kept in the summary: ${built.diagnostics.join("; ")}`;
		const degraded = !isOpen || headPlan.stale || built.diagnostics.length > 0;
		const eventLabel = payload.event === APPROVE_EVENT ? "APPROVE" : "COMMENT";
		const post = await runGh(
			githubApiArgs(hostname, "--method", "POST", `repos/${repository}/pulls/${prNumber}/reviews`, "--input", "-"),
			cwd,
			JSON.stringify(payload),
		);
		if (post.exitCode === 0) {
			let response: { id?: number; html_url?: string } = {};
			try {
				response = JSON.parse(post.stdout);
			} catch {
				/* accepted response without parseable metadata */
			}
			return {
				status: degraded ? "posted_degraded" : "posted",
				message: headPlan.stale
					? `body-only stale ${eventLabel} review posted (${headPlan.reviewedHeadSha} -> ${headPlan.currentHeadSha})`
					: isOpen
						? `GitHub ${eventLabel} review posted${inlineWarning}`
						: `body-only ${eventLabel} review posted for non-open PR`,
				event: payload.event,
				reviewId: response.id,
				url: response.html_url,
			};
		}

		try {
			if (await hasExistingMarker(cwd, hostname, repository, prNumber, identity, normalizedHeadSha)) {
				return {
					status: degraded ? "posted_degraded" : "posted",
					message: `GitHub ${eventLabel} review found during failure reconciliation${inlineWarning}`,
					event: payload.event,
					reconciled: true,
				};
			}
		} catch {
			/* reconciliation failure is handled below */
		}
		const detail = post.errorMessage || post.stderr || "gh review request failed";
		if (/HTTP\s+4\d\d/i.test(detail) && !post.timedOut) {
			return { status: "failed", message: detail };
		}
		return { status: "indeterminate", message: `${detail}; no matching marker found after reconciliation` };
	});
}
