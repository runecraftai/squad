import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
	intervalIntersectionMs,
	intervalUnionMs,
	ReviewTelemetryTracker,
} from "../lib/pr-review-telemetry.ts";

describe("overlap-aware interval math", () => {
	test("unions each phase and computes only their interval intersection", () => {
		const review = [
			{ startMs: 10, endMs: 50 },
			{ startMs: 20, endMs: 70 },
		];
		const baseline = [
			{ startMs: 30, endMs: 40 },
			{ startMs: 60, endMs: 80 },
		];
		expect(intervalUnionMs(review)).toBe(60);
		expect(intervalUnionMs(baseline)).toBe(30);
		expect(intervalIntersectionMs(review, baseline)).toBe(20);
		expect(intervalUnionMs([...review, ...baseline])).toBe(70);
	});
});

describe("review invocation telemetry", () => {
	test("measures direct wall time without summing overlapping review and baseline phases", () => {
		let clock = 0;
		const tracker = new ReviewTelemetryTracker(() => clock);
		tracker.begin(7);
		clock = 20;
		tracker.toolStarted("batch", "review_subagents", { passes: [] });
		clock = 30;
		tracker.toolStarted("verify-list", "pr_review_verify", { action: "list" });
		tracker.toolEnded("verify-list");
		tracker.toolStarted("verify", "pr_review_verify", {
			action: "run",
			pr_number: 7,
			head_sha: "a".repeat(40),
			baseline_name: "unit",
		});
		clock = 50;
		tracker.toolEnded("verify");
		clock = 80;
		tracker.toolEnded("batch");
		clock = 100;
		const telemetry = tracker.finish("terminal_response")!;

		expect(telemetry.clock).toBe("monotonic");
		expect(telemetry.totalWallMs).toBe(100);
		expect(telemetry.activeReviewMs).toBe(100);
		expect(telemetry.phases.humanConfirmationWait.elapsedMs).toBe(0);
		expect(telemetry.phases.reviewSubagentTools.elapsedMs).toBe(60);
		expect(telemetry.schemaVersion).toBe(2);
		expect(telemetry.phases.baselineVerificationTool.elapsedMs).toBe(20);
		expect(telemetry.phases.baselineVerificationTool.intervals[0]?.toolName).toBe("pr_review_verify");
		expect(telemetry.phases.overlapMs).toBe(20);
		expect(telemetry.phases.observableToolWallMs).toBe(60);
		expect(telemetry.phases.aggregateOrchestration).toEqual({
			label: "aggregate orchestration",
			elapsedMs: 40,
		});
	});

	test("attributes only action=run, never discovery or bash command markers", () => {
		let clock = 0;
		const tracker = new ReviewTelemetryTracker(() => clock);
		tracker.begin(7);
		clock = 5;
		tracker.toolStarted("metadata", "bash", { command: "gh pr view 7 --json title" });
		clock = 25;
		tracker.toolEnded("metadata");
		tracker.toolStarted("discover", "pr_review_verify", { action: "list" });
		clock = 29;
		tracker.toolEnded("discover");
		clock = 30;
		const telemetry = tracker.finish("terminal_response")!;
		expect(telemetry.phases.baselineVerificationTool.intervals).toEqual([]);
		expect(telemetry.phases.aggregateOrchestration.elapsedMs).toBe(30);
	});

	test("marks an interval whose end lifecycle event was not observed", () => {
		let clock = 0;
		const tracker = new ReviewTelemetryTracker(() => clock);
		tracker.begin(7);
		clock = 4;
		tracker.toolStarted("batch", "review_subagent", {});
		clock = 9;
		const telemetry = tracker.finish("cleared")!;
		expect(telemetry.phases.reviewSubagentTools.intervals[0]).toMatchObject({
			toolName: "review_subagent",
			elapsedMs: 5,
			endObserved: false,
		});
	});

	test("excludes a long non-open confirmation wait from active review and compresses later offsets", () => {
		let clock = 0;
		const tracker = new ReviewTelemetryTracker(() => clock);
		tracker.begin(7);
		clock = 100;
		expect(tracker.pauseForConfirmation()).toBeTrue();

		clock = 60_100;
		expect(tracker.resumeAfterConfirmation()).toBeTrue();
		clock = 60_110;
		tracker.toolStarted("batch", "review_subagents", { passes: [] });
		clock = 60_150;
		tracker.toolEnded("batch");
		clock = 60_200;
		const telemetry = tracker.finish("terminal_response")!;

		expect(telemetry.totalWallMs).toBe(60_200);
		expect(telemetry.activeReviewMs).toBe(200);
		expect(telemetry.phases.humanConfirmationWait.elapsedMs).toBe(60_000);
		expect(telemetry.phases.reviewSubagentTools.intervals).toEqual([
			{
				toolCallId: "batch",
				toolName: "review_subagents",
				startOffsetMs: 110,
				endOffsetMs: 150,
				elapsedMs: 40,
				endObserved: true,
			},
		]);
		expect(telemetry.phases.observableToolWallMs).toBe(40);
		expect(telemetry.phases.aggregateOrchestration.elapsedMs).toBe(160);
		expect(
			telemetry.phases.observableToolWallMs + telemetry.phases.aggregateOrchestration.elapsedMs,
		).toBe(telemetry.activeReviewMs);
	});

	test("finishes negative confirmation while paused and can safely begin a replacement", () => {
		let clock = 0;
		const tracker = new ReviewTelemetryTracker(() => clock);
		tracker.begin(7);
		clock = 75;
		tracker.pauseForConfirmation();
		clock = 30_075;
		const cleared = tracker.finish("cleared")!;
		expect(cleared).toMatchObject({
			prNumber: 7,
			totalWallMs: 30_075,
			activeReviewMs: 75,
			phases: {
				humanConfirmationWait: { elapsedMs: 30_000 },
				aggregateOrchestration: { elapsedMs: 75 },
			},
		});

		tracker.begin(8);
		clock = 30_100;
		const replacement = tracker.finish("replaced")!;
		expect(replacement).toMatchObject({ prNumber: 8, totalWallMs: 25, activeReviewMs: 25 });
	});
});

describe("extension telemetry boundaries", () => {
	test("uses monotonic pass timing and persists invocation details before publication", () => {
		const subagent = readFileSync(new URL("../extensions/pr-review-subagent.ts", import.meta.url), "utf8");
		const renderer = readFileSync(new URL("../extensions/review-table.ts", import.meta.url), "utf8");
		expect(subagent).not.toContain("Date.now()");
		expect(subagent).toContain('clock: "monotonic"');
		expect(subagent).toContain("startOffsetMs");
		expect(renderer).toContain('pi.on("tool_execution_start"');
		expect(renderer).toContain('pi.appendEntry("pr-review-telemetry", telemetry)');
		expect(renderer).toContain("telemetryTracker.pauseForConfirmation()");
		expect(renderer).toContain("telemetryTracker.resumeAfterConfirmation()");
		const turnEnd = renderer.slice(
			renderer.indexOf('pi.on("turn_end"'),
			renderer.indexOf('pi.on("message_end"'),
		);
		const messageEnd = renderer.slice(renderer.indexOf('pi.on("message_end"'));
		expect(messageEnd.indexOf('persistTelemetry("terminal_response")')).toBeLessThan(
			messageEnd.indexOf("pendingCompletion ="),
		);
		expect(turnEnd.indexOf("pi.appendEntry(")).toBeLessThan(turnEnd.indexOf("await publishCompletedReview"));
	});
});
