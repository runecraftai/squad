import { createHash } from "node:crypto";

export type ReviewFocusPassStatus =
	| "queued"
	| "running"
	| "retrying"
	| "completed"
	| "failed"
	| "aborted";

export interface ReviewFocusPassDescriptor {
	key: string;
	label: string;
	tier: "light" | "medium" | "heavy";
}

export interface ReviewFocusToolSnapshot {
	name: string;
	status: "running" | "completed" | "failed";
}

export interface ReviewFocusPassSnapshot extends ReviewFocusPassDescriptor {
	status: ReviewFocusPassStatus;
	attempt: number;
	model?: string;
	assistantText: string;
	tools: ReviewFocusToolSnapshot[];
	evictedBytes: number;
	sequence: number;
}

export interface ReviewFocusSnapshot {
	generation: number;
	sequence: number;
	droppedPasses: number;
	passes: ReviewFocusPassSnapshot[];
}

export type ReviewFocusPassEvent =
	| { type: "attempt_started"; attempt: number; model?: string }
	| { type: "model_observed"; model: string }
	| { type: "assistant_delta"; text: string }
	| { type: "assistant_snapshot"; text: string }
	| { type: "tool_started"; toolCallId: string; toolName: string }
	| { type: "tool_ended"; toolCallId: string; toolName: string; isError: boolean }
	| { type: "retrying" }
	| { type: "completed" }
	| { type: "failed" }
	| { type: "aborted" };

export type ReviewFocusSubscriber = (snapshot: ReviewFocusSnapshot | undefined) => void;

/** Strict LF-delimited decoder for the child Pi JSON event stream. */
export class ReviewJsonLineDecoder {
	private buffer = "";

	constructor(private readonly onEvent: (event: unknown) => void) {}

	push(chunk: string): void {
		this.buffer += chunk;
		const lines = this.buffer.split("\n");
		this.buffer = lines.pop() ?? "";
		for (const line of lines) this.parse(line.endsWith("\r") ? line.slice(0, -1) : line);
	}

	end(): void {
		if (this.buffer) this.parse(this.buffer.endsWith("\r") ? this.buffer.slice(0, -1) : this.buffer);
		this.buffer = "";
	}

	private parse(line: string): void {
		if (!line.trim()) return;
		try {
			this.onEvent(JSON.parse(line));
		} catch {
			// Malformed child output is ignored; process exit remains authoritative.
		}
	}
}

const MAX_PASSES = 64;
const MAX_TOOLS_PER_PASS = 24;
const MAX_ASSISTANT_BYTES_PER_PASS = 48 * 1024;
const MAX_ASSISTANT_BYTES_PER_GENERATION = 256 * 1024;
const MAX_LABEL_LENGTH = 96;
const MAX_MODEL_LENGTH = 160;
const MAX_TOOL_NAME_LENGTH = 80;

interface MutableTool {
	callId: string;
	name: string;
	status: ReviewFocusToolSnapshot["status"];
}

interface MutablePass extends ReviewFocusPassDescriptor {
	status: ReviewFocusPassStatus;
	attempt: number;
	model?: string;
	assistantText: string;
	tools: MutableTool[];
	evictedBytes: number;
	sequence: number;
}

interface GenerationState {
	generation: number;
	sequence: number;
	droppedPasses: number;
	passes: Map<string, MutablePass>;
	subscribers: Set<ReviewFocusSubscriber>;
}

function utf8Bytes(value: string): number {
	return Buffer.byteLength(value, "utf8");
}

function clampPlainField(value: string, maxLength: number, fallback: string): string {
	const sanitized = sanitizeReviewFocusText(value).replace(/\s+/g, " ").trim();
	if (!sanitized) return fallback;
	return sanitized.length > maxLength ? `${sanitized.slice(0, maxLength - 1)}…` : sanitized;
}

function keepUtf8Tail(value: string, maxBytes: number): { text: string; droppedBytes: number } {
	const totalBytes = utf8Bytes(value);
	if (totalBytes <= maxBytes) return { text: value, droppedBytes: 0 };
	if (maxBytes <= 0) return { text: "", droppedBytes: totalBytes };

	const codePoints = [...value];
	let keptBytes = 0;
	let start = codePoints.length;
	while (start > 0) {
		const nextBytes = utf8Bytes(codePoints[start - 1]!);
		if (keptBytes + nextBytes > maxBytes) break;
		keptBytes += nextBytes;
		start--;
	}
	return { text: codePoints.slice(start).join(""), droppedBytes: totalBytes - keptBytes };
}

/** Remove terminal control sequences while preserving readable whitespace. */
export function sanitizeReviewFocusText(value: string): string {
	return value
		.replace(/\u001b\][^\u0007]*(?:\u0007|\u001b\\)/g, "")
		.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
		.replace(/\r\n?/g, "\n")
		.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, "�");
}

function toolIdentity(value: string): string {
	return createHash("sha256").update(value).digest("base64url").slice(0, 24);
}

function assistantModel(message: unknown): string | undefined {
	if (!message || typeof message !== "object") return undefined;
	const candidate = message as { role?: unknown; model?: unknown };
	return candidate.role === "assistant" && typeof candidate.model === "string" && candidate.model.trim()
		? candidate.model
		: undefined;
}

function assistantText(message: unknown): string | undefined {
	if (!message || typeof message !== "object") return undefined;
	const candidate = message as { role?: unknown; content?: unknown };
	if (candidate.role !== "assistant" || !Array.isArray(candidate.content)) return undefined;
	const parts: string[] = [];
	for (const part of candidate.content) {
		if (part && typeof part === "object" && (part as { type?: unknown }).type === "text") {
			const text = (part as { text?: unknown }).text;
			if (typeof text === "string") parts.push(text);
		}
	}
	return parts.join("");
}

/** Convert child JSON events into an allowlisted stream that excludes prompts, diffs, args, and results. */
export function normalizeReviewFocusJsonEvent(raw: unknown): ReviewFocusPassEvent[] {
	if (!raw || typeof raw !== "object") return [];
	const event = raw as Record<string, unknown>;
	if (event.type === "message_update") {
		const normalized: ReviewFocusPassEvent[] = [];
		const model = assistantModel(event.message);
		if (model) normalized.push({ type: "model_observed", model });
		const update = event.assistantMessageEvent;
		if (update && typeof update === "object") {
			const delta = (update as { type?: unknown; delta?: unknown });
			if (delta.type === "text_delta" && typeof delta.delta === "string") {
				return [...normalized, { type: "assistant_delta", text: delta.delta }];
			}
		}
		const snapshot = assistantText(event.message);
		if (snapshot) normalized.push({ type: "assistant_snapshot", text: snapshot });
		return normalized;
	}
	if (event.type === "message_end") {
		const normalized: ReviewFocusPassEvent[] = [];
		const model = assistantModel(event.message);
		if (model) normalized.push({ type: "model_observed", model });
		const snapshot = assistantText(event.message);
		if (snapshot !== undefined) normalized.push({ type: "assistant_snapshot", text: snapshot });
		return normalized;
	}
	if (event.type === "tool_execution_start") {
		if (typeof event.toolCallId !== "string" || typeof event.toolName !== "string") return [];
		return [{ type: "tool_started", toolCallId: event.toolCallId, toolName: event.toolName }];
	}
	if (event.type === "tool_execution_end") {
		if (typeof event.toolCallId !== "string" || typeof event.toolName !== "string") return [];
		return [{
			type: "tool_ended",
			toolCallId: event.toolCallId,
			toolName: event.toolName,
			isError: event.isError === true,
		}];
	}
	return [];
}

export class ReviewFocusRegistry {
	private state?: GenerationState;

	open(generation: number): void {
		this.close();
		this.state = {
			generation,
			sequence: 0,
			droppedPasses: 0,
			passes: new Map(),
			subscribers: new Set(),
		};
	}

	register(generation: number, descriptor: ReviewFocusPassDescriptor): boolean {
		const state = this.state;
		if (!state || state.generation !== generation || state.passes.has(descriptor.key)) return false;
		if (state.passes.size >= MAX_PASSES) {
			const removable = [...state.passes.values()].find((pass) =>
				pass.status === "completed" || pass.status === "failed" || pass.status === "aborted"
			);
			if (!removable) {
				state.droppedPasses++;
				this.notify(state);
				return false;
			}
			state.passes.delete(removable.key);
			state.droppedPasses++;
		}
		const sequence = ++state.sequence;
		state.passes.set(descriptor.key, {
			key: descriptor.key,
			label: clampPlainField(descriptor.label, MAX_LABEL_LENGTH, "review pass"),
			tier: descriptor.tier,
			status: "queued",
			attempt: 0,
			assistantText: "",
			tools: [],
			evictedBytes: 0,
			sequence,
		});
		this.notify(state);
		return true;
	}

	publish(generation: number, key: string, event: ReviewFocusPassEvent): boolean {
		const state = this.state;
		const pass = state?.generation === generation ? state.passes.get(key) : undefined;
		if (!state || !pass) return false;
		if (pass.status === "completed" || pass.status === "failed" || pass.status === "aborted") return false;

		switch (event.type) {
			case "attempt_started":
				pass.status = "running";
				pass.attempt = Math.max(1, Math.floor(event.attempt));
				pass.model = typeof event.model === "string"
					? clampPlainField(event.model, MAX_MODEL_LENGTH, "") || undefined
					: undefined;
				pass.assistantText = "";
				pass.tools = [];
				pass.evictedBytes = 0;
				break;
			case "model_observed":
				pass.model = clampPlainField(event.model, MAX_MODEL_LENGTH, "") || undefined;
				break;
			case "assistant_delta":
				this.appendAssistantText(pass, sanitizeReviewFocusText(event.text));
				break;
			case "assistant_snapshot":
				this.replaceAssistantText(pass, sanitizeReviewFocusText(event.text));
				break;
			case "tool_started":
				pass.tools.push({
					callId: toolIdentity(event.toolCallId),
					name: clampPlainField(event.toolName, MAX_TOOL_NAME_LENGTH, "tool"),
					status: "running",
				});
				if (pass.tools.length > MAX_TOOLS_PER_PASS) pass.tools.splice(0, pass.tools.length - MAX_TOOLS_PER_PASS);
				break;
			case "tool_ended": {
				const callId = toolIdentity(event.toolCallId);
				const existing = [...pass.tools].reverse().find((tool) => tool.callId === callId);
				if (existing) existing.status = event.isError ? "failed" : "completed";
				else {
					pass.tools.push({
						callId,
						name: clampPlainField(event.toolName, MAX_TOOL_NAME_LENGTH, "tool"),
						status: event.isError ? "failed" : "completed",
					});
					if (pass.tools.length > MAX_TOOLS_PER_PASS) pass.tools.splice(0, pass.tools.length - MAX_TOOLS_PER_PASS);
				}
				break;
			}
			case "retrying":
				pass.status = "retrying";
				break;
			case "completed":
				pass.status = "completed";
				break;
			case "failed":
				pass.status = "failed";
				break;
			case "aborted":
				pass.status = "aborted";
				break;
		}
		pass.sequence = ++state.sequence;
		this.enforceGenerationLimit(state);
		this.notify(state);
		return true;
	}

	snapshot(generation: number): ReviewFocusSnapshot | undefined {
		const state = this.state;
		if (!state || state.generation !== generation) return undefined;
		return this.makeSnapshot(state);
	}

	subscribe(generation: number, subscriber: ReviewFocusSubscriber): (() => void) | undefined {
		const state = this.state;
		if (!state || state.generation !== generation) return undefined;
		state.subscribers.add(subscriber);
		try {
			subscriber(this.makeSnapshot(state));
		} catch {
			state.subscribers.delete(subscriber);
		}
		return () => state.subscribers.delete(subscriber);
	}

	close(generation?: number): void {
		const state = this.state;
		if (!state || (generation !== undefined && state.generation !== generation)) return;
		this.state = undefined;
		for (const subscriber of [...state.subscribers]) {
			try {
				subscriber(undefined);
			} catch {
				// Observer failures never delay authority revocation or data purge.
			}
		}
		state.subscribers.clear();
		state.passes.clear();
	}

	private appendAssistantText(pass: MutablePass, delta: string): void {
		const bounded = keepUtf8Tail(pass.assistantText + delta, MAX_ASSISTANT_BYTES_PER_PASS);
		pass.assistantText = bounded.text;
		pass.evictedBytes += bounded.droppedBytes;
	}

	private replaceAssistantText(pass: MutablePass, value: string): void {
		const bounded = keepUtf8Tail(value, MAX_ASSISTANT_BYTES_PER_PASS);
		pass.assistantText = bounded.text;
		pass.evictedBytes = bounded.droppedBytes;
	}

	private enforceGenerationLimit(state: GenerationState): void {
		let total = [...state.passes.values()].reduce((sum, pass) => sum + utf8Bytes(pass.assistantText), 0);
		if (total <= MAX_ASSISTANT_BYTES_PER_GENERATION) return;
		for (const pass of [...state.passes.values()].sort((a, b) => a.sequence - b.sequence)) {
			if (total <= MAX_ASSISTANT_BYTES_PER_GENERATION) break;
			const currentBytes = utf8Bytes(pass.assistantText);
			if (currentBytes === 0) continue;
			const target = Math.max(0, currentBytes - (total - MAX_ASSISTANT_BYTES_PER_GENERATION));
			const bounded = keepUtf8Tail(pass.assistantText, target);
			pass.assistantText = bounded.text;
			pass.evictedBytes += bounded.droppedBytes;
			total -= bounded.droppedBytes;
		}
	}

	private makeSnapshot(state: GenerationState): ReviewFocusSnapshot {
		return {
			generation: state.generation,
			sequence: state.sequence,
			droppedPasses: state.droppedPasses,
			passes: [...state.passes.values()].map((pass) => ({
				key: pass.key,
				label: pass.label,
				tier: pass.tier,
				status: pass.status,
				attempt: pass.attempt,
				...(pass.model ? { model: pass.model } : {}),
				assistantText: pass.assistantText,
				tools: pass.tools.map(({ name, status }) => ({ name, status })),
				evictedBytes: pass.evictedBytes,
				sequence: pass.sequence,
			})),
		};
	}

	private notify(state: GenerationState): void {
		if (state.subscribers.size === 0) return;
		const snapshot = this.makeSnapshot(state);
		for (const subscriber of [...state.subscribers]) {
			try {
				subscriber(snapshot);
			} catch {
				state.subscribers.delete(subscriber);
			}
		}
	}
}
