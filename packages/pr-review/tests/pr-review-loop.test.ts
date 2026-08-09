import { describe, expect, test } from "bun:test";
import {
	REVIEW_LOOP_TOOL_NAMES,
	ReviewLoopCoordinator,
} from "../lib/pr-review-loop.ts";
import {
	parsePublishMode,
	resolveAutoPostSetting,
} from "../lib/pr-review-publish.ts";

const autoOff = resolveAutoPostSetting({ autoPostReviews: false });

function harness() {
	let activeTools = ["read", "bash", ...REVIEW_LOOP_TOOL_NAMES];
	const pi = {
		getActiveTools: () => [...activeTools],
		setActiveTools: (next: string[]) => {
			activeTools = [...next];
		},
	};
	const session = {
		id: "session-1",
		startedAt: "2026-07-13T00:00:00.000Z",
	};
	const ctx = {
		cwd: "/tmp/repo",
		sessionManager: {
			getSessionId: () => session.id,
			getHeader: () => ({ id: session.id, timestamp: session.startedAt }),
		},
	};
	const coordinator = new ReviewLoopCoordinator(pi as any);
	return {
		coordinator,
		ctx,
		session,
		activeTools: () => [...activeTools],
	};
}

describe("review-loop authority", () => {
	test("hides only reserved tools while idle and exposes them for a trusted command", () => {
		const h = harness();
		h.coordinator.hideTools();
		expect(h.activeTools()).toEqual(["read", "bash"]);

		const started = h.coordinator.begin(
			parsePublishMode("/pr-review 7"),
			autoOff,
			"interactive",
			h.ctx as any,
		);
		expect(started).toEqual({ accepted: true });
		expect(h.activeTools()).toEqual(["read", "bash", ...REVIEW_LOOP_TOOL_NAMES]);
		expect(h.coordinator.acquire(h.ctx as any)).toBeDefined();
	});

	test("suspends every tool for output repair and restores only base tools", () => {
		const h = harness();
		h.coordinator.begin(parsePublishMode("/pr-review 7"), autoOff, "interactive", h.ctx as any);
		const lease = h.coordinator.acquire(h.ctx as any)!;

		expect(h.coordinator.suspendToolsForRepair()).toBeTrue();
		expect(h.activeTools()).toEqual([]);
		expect(h.coordinator.acquire(h.ctx as any)).toBeUndefined();
		expect(h.coordinator.isLeaseActive(lease, h.ctx as any)).toBeFalse();
		expect(lease.signal.aborted).toBeFalse();
		expect(h.coordinator.suspendToolsForRepair()).toBeFalse();

		expect(h.coordinator.consume()?.prNumber).toBe(7);
		expect(lease.signal.aborted).toBeTrue();
		expect(h.activeTools()).toEqual(["read", "bash"]);

		h.coordinator.begin(parsePublishMode("/pr-review 8"), autoOff, "interactive", h.ctx as any);
		expect(h.coordinator.suspendToolsForRepair()).toBeTrue();
		h.coordinator.clear();
		expect(h.activeTools()).toEqual(["read", "bash"]);
		expect(h.coordinator.suspendToolsForRepair()).toBeFalse();
	});

	test("never authorizes extension-originated commands", () => {
		const h = harness();
		h.coordinator.hideTools();
		const started = h.coordinator.begin(
			parsePublishMode("/pr-review 7"),
			autoOff,
			"extension",
			h.ctx as any,
		);
		expect(started.accepted).toBeFalse();
		expect(started.error).toContain("interactive or RPC user");
		expect(h.coordinator.acquire(h.ctx as any)).toBeUndefined();
		expect(h.activeTools()).toEqual(["read", "bash"]);
	});

	test("shares one generation across parallel calls and revokes stale leases", () => {
		const h = harness();
		h.coordinator.begin(parsePublishMode("/pr-review 7"), autoOff, "rpc", h.ctx as any);
		const first = h.coordinator.acquire(h.ctx as any)!;
		const second = h.coordinator.acquire(h.ctx as any)!;
		expect(second.generation).toBe(first.generation);
		expect(h.coordinator.isLeaseActive(first, h.ctx as any)).toBeTrue();

		h.coordinator.clear();
		expect(first.signal.aborted).toBeTrue();
		expect(h.coordinator.isLeaseActive(first, h.ctx as any)).toBeFalse();
		expect(h.activeTools()).toEqual(["read", "bash"]);
	});

	test("suspends tools for non-open confirmation and trusts only user confirmation", () => {
		const h = harness();
		h.coordinator.begin(parsePublishMode("/pr-review 7"), autoOff, "interactive", h.ctx as any);
		expect(h.coordinator.markAwaitingConfirmation()).toBeTrue();
		expect(h.activeTools()).toEqual(["read", "bash"]);
		expect(h.coordinator.acquire(h.ctx as any)).toBeUndefined();

		expect(h.coordinator.resolveConfirmationInput("yes", "interactive", h.ctx as any)).toBe("confirmed");
		expect(h.coordinator.acquire(h.ctx as any)).toBeDefined();
		expect(h.activeTools()).toEqual(["read", "bash", ...REVIEW_LOOP_TOOL_NAMES]);

		h.coordinator.clear();
		h.coordinator.begin(parsePublishMode("/pr-review 7"), autoOff, "interactive", h.ctx as any);
		h.coordinator.markAwaitingConfirmation();
		expect(h.coordinator.resolveConfirmationInput("yes", "extension", h.ctx as any)).toBe("cleared");
		expect(h.coordinator.acquire(h.ctx as any)).toBeUndefined();
	});

	test("binds focus publishers and subscribers to the active generation", () => {
		const h = harness();
		h.coordinator.begin(parsePublishMode("/pr-review 7"), autoOff, "interactive", h.ctx as any);
		const lease = h.coordinator.acquire(h.ctx as any)!;
		const publisher = h.coordinator.createFocusPublisher(lease, h.ctx as any, {
			key: "call-1:pass-1",
			label: "correctness",
			tier: "heavy",
		})!;
		publisher.publish({ type: "attempt_started", attempt: 1, model: "provider/model" });
		publisher.publish({ type: "assistant_snapshot", text: "live output" });
		expect(h.coordinator.focusSnapshot(h.ctx as any)?.passes[0]?.assistantText).toBe("live output");

		let closed = false;
		h.coordinator.subscribeFocus(h.ctx as any, (snapshot) => {
			if (!snapshot) closed = true;
		});
		h.coordinator.clear();
		expect(closed).toBeTrue();
		expect(publisher.publish({ type: "assistant_delta", text: "late" })).toBeFalse();
		expect(h.coordinator.focusSnapshot(h.ctx as any)).toBeUndefined();
	});

	test("fails closed when the session identity or cwd changes", () => {
		const h = harness();
		h.coordinator.begin(parsePublishMode("/pr-review 7"), autoOff, "interactive", h.ctx as any);
		const lease = h.coordinator.acquire(h.ctx as any)!;
		const publisher = h.coordinator.createFocusPublisher(lease, h.ctx as any, {
			key: "call-1:pass-1",
			label: "security",
			tier: "heavy",
		})!;
		h.session.startedAt = "2026-07-14T00:00:00.000Z";
		expect(h.coordinator.isLeaseActive(lease, h.ctx as any)).toBeFalse();
		expect(lease.signal.aborted).toBeTrue();
		expect(publisher.publish({ type: "assistant_delta", text: "late" })).toBeFalse();
		expect(h.coordinator.focusSnapshot(h.ctx as any)).toBeUndefined();
		expect(h.activeTools()).toEqual(["read", "bash"]);
	});
});
