import { describe, expect, test } from "bun:test";
import {
	normalizeReviewFocusJsonEvent,
	ReviewFocusRegistry,
	ReviewJsonLineDecoder,
	sanitizeReviewFocusText,
} from "../lib/pr-review-focus.ts";

const descriptor = {
	key: "run-1:pass-1",
	label: "correctness",
	tier: "heavy" as const,
};

describe("review focus JSONL decoding", () => {
	test("handles fragmented, CRLF, malformed, and unterminated records", () => {
		const events: unknown[] = [];
		const decoder = new ReviewJsonLineDecoder((event) => events.push(event));
		decoder.push('{"type":"message_up');
		decoder.push('date","value":1}\r\nnot-json\n{"type":"tool_');
		decoder.push('execution_start","value":2}');
		decoder.end();
		expect(events).toEqual([
			{ type: "message_update", value: 1 },
			{ type: "tool_execution_start", value: 2 },
		]);
	});
});

describe("review focus event normalization", () => {
	test("accepts only assistant text and synthesized tool lifecycle metadata", () => {
		expect(normalizeReviewFocusJsonEvent({
			type: "message_update",
			message: { role: "assistant", content: [{ type: "text", text: "partial" }] },
			assistantMessageEvent: { type: "text_delta", delta: "ial" },
		})).toEqual([{ type: "assistant_delta", text: "ial" }]);
		expect(normalizeReviewFocusJsonEvent({
			type: "message_update",
			message: { role: "assistant", content: [] },
			assistantMessageEvent: { type: "text_delta", delta: "fallback" },
		})).toEqual([{ type: "assistant_delta", text: "fallback" }]);
		expect(normalizeReviewFocusJsonEvent({
			type: "message_update",
			message: { role: "assistant", content: [{ type: "text", text: "snapshot fallback" }] },
		})).toEqual([{ type: "assistant_snapshot", text: "snapshot fallback" }]);
		expect(normalizeReviewFocusJsonEvent({
			type: "message_end",
			message: { role: "assistant", content: [{ type: "text", text: "done" }] },
		})).toEqual([{ type: "assistant_snapshot", text: "done" }]);
		expect(normalizeReviewFocusJsonEvent({
			type: "tool_execution_start",
			toolCallId: "call-1",
			toolName: "read",
			args: { path: "SECRET_DIFF" },
		})).toEqual([{ type: "tool_started", toolCallId: "call-1", toolName: "read" }]);
		expect(normalizeReviewFocusJsonEvent({
			type: "tool_execution_end",
			toolCallId: "call-1",
			toolName: "read",
			result: { content: "SECRET_DIFF" },
			isError: false,
		})).toEqual([{ type: "tool_ended", toolCallId: "call-1", toolName: "read", isError: false }]);
	});

	test("streams deltas and uses message_end as authoritative reconciliation", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(1);
		registry.register(1, descriptor);
		registry.publish(1, descriptor.key, { type: "attempt_started", attempt: 1 });
		for (const raw of [
			{
				type: "message_update",
				message: { role: "assistant", content: [{ type: "text", text: "hel" }] },
				assistantMessageEvent: { type: "text_delta", delta: "hel" },
			},
			{
				type: "message_update",
				message: { role: "assistant", content: [{ type: "text", text: "hello! stale" }] },
				assistantMessageEvent: { type: "text_delta", delta: "lo" },
			},
			{
				type: "message_end",
				message: { role: "assistant", content: [{ type: "text", text: "hello" }] },
			},
		]) {
			for (const event of normalizeReviewFocusJsonEvent(raw)) registry.publish(1, descriptor.key, event);
		}
		expect(registry.snapshot(1)?.passes[0]?.assistantText).toBe("hello");
	});

	test("reconciles the actual child model without retaining other message metadata", () => {
		expect(normalizeReviewFocusJsonEvent({
			type: "message_end",
			message: {
				role: "assistant",
				model: "provider/actual-model",
				provider: "secret-provider-metadata",
				content: [{ type: "text", text: "done" }],
			},
		})).toEqual([
			{ type: "model_observed", model: "provider/actual-model" },
			{ type: "assistant_snapshot", text: "done" },
		]);
	});

	test("never retains user prompts, raw args, results, or malformed events", () => {
		const sentinel = "SENTINEL_COMPLETE_DIFF";
		for (const raw of [
			{ type: "message_end", message: { role: "user", content: [{ type: "text", text: sentinel }] } },
			{ type: "tool_execution_update", args: { context: sentinel }, partialResult: sentinel },
			{ type: "session", cwd: sentinel },
			{ type: "message_update", message: null },
			null,
			"not an event",
		]) {
			expect(JSON.stringify(normalizeReviewFocusJsonEvent(raw))).not.toContain(sentinel);
			expect(normalizeReviewFocusJsonEvent(raw)).toEqual([]);
		}
	});

	test("removes terminal controls while preserving readable layout", () => {
		expect(sanitizeReviewFocusText("a\u001b[31mred\u001b[0m\rnext\u0000end"))
			.toBe("ared\nnext�end");
	});
});

describe("review focus registry", () => {
	test("publishes immutable snapshots and reconciles streamed assistant text", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(7);
		expect(registry.register(7, descriptor)).toBeTrue();
		expect(registry.publish(7, descriptor.key, { type: "attempt_started", attempt: 1, model: "provider/requested" })).toBeTrue();
		registry.publish(7, descriptor.key, { type: "model_observed", model: "provider/actual" });
		registry.publish(7, descriptor.key, { type: "assistant_delta", text: "hel" });
		registry.publish(7, descriptor.key, { type: "assistant_snapshot", text: "hello" });
		registry.publish(7, descriptor.key, { type: "assistant_delta", text: " world" });
		registry.publish(7, descriptor.key, { type: "tool_started", toolCallId: "1", toolName: "read" });
		registry.publish(7, descriptor.key, { type: "tool_ended", toolCallId: "1", toolName: "read", isError: false });
		registry.publish(7, descriptor.key, { type: "completed" });

		expect(registry.snapshot(7)?.passes[0]).toMatchObject({
			label: "correctness",
			status: "completed",
			attempt: 1,
			model: "provider/actual",
			assistantText: "hello world",
			tools: [{ name: "read", status: "completed" }],
		});
		expect(registry.publish(7, descriptor.key, { type: "assistant_delta", text: "late" })).toBeFalse();
		expect(registry.snapshot(7)?.passes[0]?.assistantText).toBe("hello world");
	});

	test("uses bounded collision-resistant tool identities", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(1);
		registry.register(1, descriptor);
		registry.publish(1, descriptor.key, { type: "attempt_started", attempt: 1 });
		const sharedPrefix = "x".repeat(200);
		registry.publish(1, descriptor.key, { type: "tool_started", toolCallId: `${sharedPrefix}-one`, toolName: "read-one" });
		registry.publish(1, descriptor.key, { type: "tool_started", toolCallId: `${sharedPrefix}-two`, toolName: "read-two" });
		registry.publish(1, descriptor.key, { type: "tool_ended", toolCallId: `${sharedPrefix}-two`, toolName: "read-two", isError: true });
		expect(registry.snapshot(1)?.passes[0]?.tools).toEqual([
			{ name: "read-one", status: "running" },
			{ name: "read-two", status: "failed" },
		]);
	});

	test("clears text and tool activity for deterministic fallback attempts", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(1);
		registry.register(1, descriptor);
		registry.publish(1, descriptor.key, { type: "attempt_started", attempt: 1, model: "first" });
		registry.publish(1, descriptor.key, { type: "assistant_snapshot", text: "first output" });
		registry.publish(1, descriptor.key, { type: "tool_started", toolCallId: "1", toolName: "grep" });
		registry.publish(1, descriptor.key, { type: "retrying" });
		registry.publish(1, descriptor.key, { type: "attempt_started", attempt: 2, model: "fallback" });
		expect(registry.snapshot(1)?.passes[0]).toMatchObject({
			status: "running",
			attempt: 2,
			model: "fallback",
			assistantText: "",
			tools: [],
		});
	});

	test("bounds assistant text by UTF-8 bytes and records eviction", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(1);
		registry.register(1, descriptor);
		registry.publish(1, descriptor.key, { type: "attempt_started", attempt: 1 });
		registry.publish(1, descriptor.key, { type: "assistant_snapshot", text: `prefix-${"🙂".repeat(20_000)}-tail` });
		const first = registry.snapshot(1)!.passes[0]!;
		expect(Buffer.byteLength(first.assistantText, "utf8")).toBeLessThanOrEqual(48 * 1024);
		expect(first.assistantText.endsWith("-tail")).toBeTrue();
		expect(first.assistantText).not.toContain("prefix-");
		expect(first.evictedBytes).toBeGreaterThan(0);

		registry.publish(1, descriptor.key, { type: "assistant_snapshot", text: `new-${"🙂".repeat(20_100)}-tail` });
		const second = registry.snapshot(1)!.passes[0]!;
		expect(second.evictedBytes).toBeGreaterThan(first.evictedBytes);
		expect(second.evictedBytes).toBeLessThan(first.evictedBytes * 2);
	});

	test("enforces a generation-wide UTF-8 byte ceiling across parallel passes", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(1);
		for (let index = 0; index < 8; index++) {
			const key = `pass-${index}`;
			registry.register(1, { ...descriptor, key, label: key });
			registry.publish(1, key, { type: "attempt_started", attempt: 1 });
			registry.publish(1, key, { type: "assistant_snapshot", text: `${index}:${"x".repeat(48 * 1024)}` });
		}
		const current = registry.snapshot(1)!;
		const retainedBytes = current.passes.reduce(
			(total, pass) => total + Buffer.byteLength(pass.assistantText, "utf8"),
			0,
		);
		expect(retainedBytes).toBeLessThanOrEqual(256 * 1024);
		expect(current.passes.some((pass) => pass.evictedBytes > 0)).toBeTrue();
	});

	test("isolates observer failures from publication and purge", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(1);
		let healthyUpdates = 0;
		registry.subscribe(1, () => {
			throw new Error("broken observer");
		});
		registry.subscribe(1, () => healthyUpdates++);
		expect(() => registry.register(1, descriptor)).not.toThrow();
		expect(healthyUpdates).toBe(2);
		expect(() => registry.close(1)).not.toThrow();
	});

	test("notifies subscribers and rejects stale generations synchronously", () => {
		const registry = new ReviewFocusRegistry();
		registry.open(1);
		const seen: Array<number | undefined> = [];
		registry.subscribe(1, (snapshot) => seen.push(snapshot?.sequence));
		registry.register(1, descriptor);
		registry.close(1);
		expect(seen).toEqual([0, 1, undefined]);
		expect(registry.snapshot(1)).toBeUndefined();
		expect(registry.register(1, { ...descriptor, key: "late" })).toBeFalse();

		registry.open(2);
		expect(registry.register(1, descriptor)).toBeFalse();
		expect(registry.snapshot(1)).toBeUndefined();
	});
});
