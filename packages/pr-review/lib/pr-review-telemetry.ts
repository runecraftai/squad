export type MonotonicNow = () => number;

/** Milliseconds from a monotonic process clock. It is not a wall-clock timestamp. */
export const monotonicNow: MonotonicNow = () => Number(process.hrtime.bigint()) / 1_000_000;

export interface TimeInterval {
	startMs: number;
	endMs: number;
}

export interface ReviewToolInterval {
	toolCallId: string;
	toolName: "review_subagent" | "review_subagents" | "pr_review_verify";
	startOffsetMs: number;
	endOffsetMs: number;
	elapsedMs: number;
	endObserved: boolean;
}

export interface ReviewPerformanceTelemetry {
	schemaVersion: 2;
	clock: "monotonic";
	prNumber: number;
	completion: "terminal_response" | "cleared" | "replaced";
	/** Direct input-to-completion wall time, including any human confirmation wait. */
	totalWallMs: number;
	/** Active review/orchestration time with human confirmation wait removed. */
	activeReviewMs: number;
	phases: {
		humanConfirmationWait: {
			label: "human confirmation wait";
			elapsedMs: number;
		};
		reviewSubagentTools: {
			elapsedMs: number;
			intervals: ReviewToolInterval[];
		};
		baselineVerificationTool: {
			elapsedMs: number;
			intervals: ReviewToolInterval[];
		};
		overlapMs: number;
		observableToolWallMs: number;
		aggregateOrchestration: {
			label: "aggregate orchestration";
			elapsedMs: number;
		};
	};
	notes: string[];
}

type TrackedKind = "review" | "baseline";

interface ActiveInterval {
	kind: TrackedKind;
	toolCallId: string;
	toolName: ReviewToolInterval["toolName"];
	/** Offset on the active timeline, which compresses confirmation pauses. */
	startOffsetMs: number;
}

interface InvocationTiming {
	prNumber: number;
	startedAtMs: number;
	activeSegmentStartedAtMs?: number;
	activeElapsedMs: number;
	confirmationPaused: boolean;
	active: Map<string, ActiveInterval>;
	completed: Array<ActiveInterval & { endOffsetMs: number; endObserved: boolean }>;
}

function finiteInterval(interval: TimeInterval): TimeInterval | undefined {
	if (!Number.isFinite(interval.startMs) || !Number.isFinite(interval.endMs)) return undefined;
	return { startMs: interval.startMs, endMs: Math.max(interval.startMs, interval.endMs) };
}

export function unionIntervals(intervals: readonly TimeInterval[]): TimeInterval[] {
	const sorted = intervals
		.map(finiteInterval)
		.filter((interval): interval is TimeInterval => !!interval)
		.sort((a, b) => a.startMs - b.startMs || a.endMs - b.endMs);
	const union: TimeInterval[] = [];
	for (const interval of sorted) {
		const previous = union.at(-1);
		if (!previous || interval.startMs > previous.endMs) {
			union.push({ ...interval });
		} else {
			previous.endMs = Math.max(previous.endMs, interval.endMs);
		}
	}
	return union;
}

export function intervalUnionMs(intervals: readonly TimeInterval[]): number {
	return unionIntervals(intervals).reduce((total, interval) => total + interval.endMs - interval.startMs, 0);
}

/** Intersection duration between two interval sets, after independently unioning each set. */
export function intervalIntersectionMs(left: readonly TimeInterval[], right: readonly TimeInterval[]): number {
	const a = unionIntervals(left);
	const b = unionIntervals(right);
	let total = 0;
	let i = 0;
	let j = 0;
	while (i < a.length && j < b.length) {
		const start = Math.max(a[i]!.startMs, b[j]!.startMs);
		const end = Math.min(a[i]!.endMs, b[j]!.endMs);
		if (end > start) total += end - start;
		if (a[i]!.endMs <= b[j]!.endMs) i++;
		else j++;
	}
	return total;
}

function roundMs(value: number): number {
	return Math.round(Math.max(0, value) * 1000) / 1000;
}

export class ReviewTelemetryTracker {
	private invocation?: InvocationTiming;

	constructor(private readonly now: MonotonicNow = monotonicNow) {}

	private activeOffset(invocation: InvocationTiming, atMs: number): number {
		const segmentElapsed =
			invocation.activeSegmentStartedAtMs === undefined
				? 0
				: Math.max(0, atMs - invocation.activeSegmentStartedAtMs);
		return invocation.activeElapsedMs + segmentElapsed;
	}

	begin(prNumber: number): void {
		const startedAtMs = this.now();
		this.invocation = {
			prNumber,
			startedAtMs,
			activeSegmentStartedAtMs: startedAtMs,
			activeElapsedMs: 0,
			confirmationPaused: false,
			active: new Map(),
			completed: [],
		};
	}

	clear(): void {
		this.invocation = undefined;
	}

	/** Stop the active timeline after emitting the non-open PR confirmation prompt. */
	pauseForConfirmation(): boolean {
		const invocation = this.invocation;
		if (!invocation || invocation.confirmationPaused) return false;
		const pausedAtMs = this.now();
		const pausedOffsetMs = this.activeOffset(invocation, pausedAtMs);
		invocation.activeElapsedMs = pausedOffsetMs;
		invocation.activeSegmentStartedAtMs = undefined;
		invocation.confirmationPaused = true;
		// Defensive: no observed tool should span a terminal assistant response.
		for (const active of invocation.active.values()) {
			invocation.completed.push({ ...active, endOffsetMs: pausedOffsetMs, endObserved: false });
		}
		invocation.active.clear();
		return true;
	}

	/** Resume immediately when an affirmative confirmation input is accepted. */
	resumeAfterConfirmation(): boolean {
		const invocation = this.invocation;
		if (!invocation || !invocation.confirmationPaused) return false;
		invocation.activeSegmentStartedAtMs = this.now();
		invocation.confirmationPaused = false;
		return true;
	}

	toolStarted(toolCallId: string, toolName: string, args: unknown): void {
		const invocation = this.invocation;
		if (!invocation || invocation.confirmationPaused || invocation.active.has(toolCallId)) return;
		let kind: TrackedKind | undefined;
		if (toolName === "review_subagent" || toolName === "review_subagents") kind = "review";
		else if (
			toolName === "pr_review_verify" &&
			args !== null &&
			typeof args === "object" &&
			(args as { action?: unknown }).action === "run"
		) kind = "baseline";
		if (!kind) return;
		invocation.active.set(toolCallId, {
			kind,
			toolCallId,
			toolName: toolName as ReviewToolInterval["toolName"],
			startOffsetMs: this.activeOffset(invocation, this.now()),
		});
	}

	toolEnded(toolCallId: string): void {
		const invocation = this.invocation;
		const active = invocation?.active.get(toolCallId);
		if (!invocation || !active) return;
		invocation.active.delete(toolCallId);
		invocation.completed.push({
			...active,
			endOffsetMs: this.activeOffset(invocation, this.now()),
			endObserved: true,
		});
	}

	finish(completion: ReviewPerformanceTelemetry["completion"]): ReviewPerformanceTelemetry | undefined {
		const invocation = this.invocation;
		if (!invocation) return undefined;
		const finishedAtMs = Math.max(invocation.startedAtMs, this.now());
		const activeReviewMs = roundMs(this.activeOffset(invocation, finishedAtMs));
		for (const active of invocation.active.values()) {
			invocation.completed.push({ ...active, endOffsetMs: activeReviewMs, endObserved: false });
		}

		const toReported = (kind: TrackedKind): ReviewToolInterval[] =>
			invocation.completed
				.filter((interval) => interval.kind === kind)
				.map((interval) => {
					const startOffsetMs = Math.min(activeReviewMs, roundMs(interval.startOffsetMs));
					const endOffsetMs = Math.min(
						activeReviewMs,
						Math.max(startOffsetMs, roundMs(interval.endOffsetMs)),
					);
					return {
						toolCallId: interval.toolCallId,
						toolName: interval.toolName,
						startOffsetMs,
						endOffsetMs,
						elapsedMs: roundMs(endOffsetMs - startOffsetMs),
						endObserved: interval.endObserved,
					};
				});

		const review = toReported("review");
		const baseline = toReported("baseline");
		const reviewRaw = review.map((interval) => ({ startMs: interval.startOffsetMs, endMs: interval.endOffsetMs }));
		const baselineRaw = baseline.map((interval) => ({ startMs: interval.startOffsetMs, endMs: interval.endOffsetMs }));
		const totalWallMs = roundMs(finishedAtMs - invocation.startedAtMs);
		const confirmationWaitMs = roundMs(totalWallMs - activeReviewMs);
		const observableToolWallMs = roundMs(intervalUnionMs([...reviewRaw, ...baselineRaw]));
		const result: ReviewPerformanceTelemetry = {
			schemaVersion: 2,
			clock: "monotonic",
			prNumber: invocation.prNumber,
			completion,
			totalWallMs,
			activeReviewMs,
			phases: {
				humanConfirmationWait: {
					label: "human confirmation wait",
					elapsedMs: confirmationWaitMs,
				},
				reviewSubagentTools: {
					elapsedMs: roundMs(intervalUnionMs(reviewRaw)),
					intervals: review,
				},
				baselineVerificationTool: {
					elapsedMs: roundMs(intervalUnionMs(baselineRaw)),
					intervals: baseline,
				},
				overlapMs: roundMs(intervalIntersectionMs(reviewRaw, baselineRaw)),
				observableToolWallMs,
				aggregateOrchestration: {
					label: "aggregate orchestration",
					elapsedMs: roundMs(activeReviewMs - observableToolWallMs),
				},
			},
			notes: [
				"totalWallMs is measured directly from accepted /pr-review input to the recorded completion boundary; publication latency is excluded.",
				"activeReviewMs and tool interval offsets use an active timeline that excludes human confirmation wait.",
				"Phase elapsed values are interval unions. overlapMs is the interval intersection, so overlapping phases are never summed as active review time.",
				"Metadata/context gathering, model orchestration, targeted checks, and final validation are not directly bounded by lifecycle events and remain aggregate orchestration.",
			],
		};
		this.invocation = undefined;
		return result;
	}
}
