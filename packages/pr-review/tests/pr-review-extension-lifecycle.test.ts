import { afterEach, describe, expect, mock, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
	appendFileSync,
	chmodSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ReviewLoopCoordinator, REVIEW_LOOP_TOOL_NAMES } from "../lib/pr-review-loop.ts";
import { SelfReviewPermitCoordinator, SELF_REVIEW_TOOL_NAME } from "../lib/pr-self-review.ts";
import {
	COMPLETED_REVIEW_BRANCH_ANCHOR_TYPE,
	COMPLETED_REVIEW_ENTRY_TYPE,
	CompletedReviewCache,
	resolveAutoPostSetting,
	type CompletedReviewSessionIdentity,
	type ReviewLike,
} from "../lib/pr-review-publish.ts";

mock.module("@earendil-works/pi-coding-agent", () => ({
	CONFIG_DIR_NAME: ".pi",
	getAgentDir: () => join(tmpdir(), "pi-pr-review-empty-agent-dir"),
	getSelectListTheme: () => ({}),
	getSettingsListTheme: () => ({}),
}));
mock.module("typebox", () => ({
	Type: {
		Integer: (options: Record<string, unknown> = {}) => ({ type: "integer", ...options }),
		Object: (properties: Record<string, unknown>, options: Record<string, unknown> = {}) => ({
			type: "object",
			properties,
			...options,
		}),
	},
}));
let repairOutput = "";
let fallbackPayload: { commit_id: string; event: "COMMENT"; body: string } | undefined;
const fallbackPayloadCalls: Array<{ text: string; reviewedHeadSha: string }> = [];
const repairReviewOutput = async () => {
	await new Promise((resolve) => setTimeout(resolve, 0));
	return repairOutput;
};
const prepareFallbackPayload = async (text: string, reviewedHeadSha: string) => {
	fallbackPayloadCalls.push({ text, reviewedHeadSha });
	return fallbackPayload;
};

const reviewTable = (await import("../extensions/review-table.ts")).default;
const ownPromptPath = fileURLToPath(new URL("../prompts/pr-review.md", import.meta.url));
const BASE_ACTIVE_TOOLS = ["read", "bash"];

const review: ReviewLike = {
	pr: { number: 7, title: "Lifecycle review", head_sha: "a".repeat(40) },
	disposition: "reviewed",
	verification: "Not run.",
	overview: "Checks lifecycle persistence.",
	strengths: [],
	findings: [],
	notes: { correctness: "", security: "", performance: "" },
	verdict: "approve",
	overall_correctness: "patch is correct",
	overall_explanation: "No issues found.",
	overall_confidence_score: 0.9,
};

const session: CompletedReviewSessionIdentity = {
	id: "shared-explicit-id",
	startedAt: "2026-07-13T00:00:00.000Z",
};
const repository = { hostname: "github.com", repository: "owner/repo" };
const invocation = {
	mode: "disabled" as const,
	prNumber: 7,
	allowNonOpen: false,
	allowStalePublish: true,
	autoPost: resolveAutoPostSetting({ autoPostReviews: false }),
};

interface Harness {
	handlers: Map<string, Array<(event: any, ctx: any) => any>>;
	commands: Map<string, (args: string, ctx: any) => Promise<void>>;
	tools: Map<string, any>;
	branch: any[];
	notifications: string[];
	sentMessages: Array<{ message: any; options: any }>;
	activeTools(): string[];
	abortCount(): number;
	selfReviewCoordinator: SelfReviewPermitCoordinator;
	setPromptPath(path: string): void;
	ctx: any;
	appendMessage(message: any, id?: string): any;
	emit(name: string, event: any): Promise<any[]>;
}

interface HarnessOptions {
	projectConfig?: Record<string, unknown>;
	operationLogPath?: string;
	persistenceFailure?: string;
	repositoryDelayMs?: number;
}

const tempDirs: string[] = [];
let previousPath: string | undefined;

afterEach(() => {
	repairOutput = "";
	fallbackPayload = undefined;
	fallbackPayloadCalls.splice(0);
	if (previousPath !== undefined) process.env.PATH = previousPath;
	previousPath = undefined;
	for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function installFakeGh(repositoryDelayMs = 0): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-pr-review-lifecycle-"));
	tempDirs.push(dir);
	const gh = join(dir, "gh");
	writeFileSync(
		gh,
		`#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "repo view --json nameWithOwner,url" ]]; then
  sleep ${repositoryDelayMs / 1000}
  echo '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}'
else
  echo 'intentional lifecycle-test stop' >&2
  exit 1
fi
`,
	);
	chmodSync(gh, 0o755);
	for (const args of [
		["init", "-q"],
		["add", "gh"],
		["-c", "user.name=Lifecycle Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"],
	]) {
		const result = spawnSync("/usr/bin/git", args, { cwd: dir, encoding: "utf8" });
		if (result.status !== 0) throw new Error(result.stderr || "fixture git setup failed");
	}
	if (previousPath === undefined) previousPath = process.env.PATH;
	process.env.PATH = `${dir}:${process.env.PATH ?? ""}`;
	return dir;
}

interface PublishingProbe {
	payloadPath: string;
	calls(): string[];
	postCount(): number;
	payload(): Record<string, unknown> | undefined;
}

function installPublishingProbe(options: {
	currentHead?: string;
	patchless?: boolean;
	postFailure?: string;
	operationLogPath?: string;
	state?: "open" | "closed";
	mergedAt?: string | null;
} = {}): PublishingProbe {
	const dir = mkdtempSync(join(tmpdir(), "pi-pr-review-publish-tool-"));
	tempDirs.push(dir);
	const gh = join(dir, "gh");
	const payloadPath = join(dir, "payload.json");
	const callsPath = join(dir, "calls.log");
	const postsPath = join(dir, "posts.log");
	const failurePath = join(dir, "post-failure.txt");
	const changedFiles = options.patchless ? '[[{"filename":"src/parser.ts","status":"modified"}]]' : "[[]]";
	const currentHead = options.currentHead ?? "a".repeat(40);
	writeFileSync(failurePath, options.postFailure ?? "");
	const recordPostOperation = options.operationLogPath
		? `printf 'gh:POST\\n' >> '${options.operationLogPath}'`
		: ":";
	writeFileSync(
		gh,
		`#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf '%s\n' "$args" >> '${callsPath}'
if [[ "$args" == "repo view --json nameWithOwner,url" ]]; then
  echo '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}'
elif [[ "$args" == *" user --jq .login"* ]]; then
  echo 'reviewer'
elif [[ "$args" == *"--method POST"* ]]; then
  printf 'post\n' >> '${postsPath}'
  ${recordPostOperation}
  cat > '${payloadPath}'
  if [[ -s '${failurePath}' ]]; then
    cat '${failurePath}' >&2
    exit 1
  fi
  echo '{"id":42,"html_url":"https://github.com/owner/repo/pull/7#pullrequestreview-42"}'
elif [[ "$args" == *"pulls/7/reviews?per_page=100"* || "$args" == *"issues/7/comments?per_page=100"* ]]; then
  echo '[[]]'
elif [[ "$args" == *"pulls/7/files?per_page=100"* ]]; then
  echo '${changedFiles}'
elif [[ "$args" == *"repos/owner/repo/pulls/7"* ]]; then
  printf '{"state":"${options.state ?? "open"}","draft":false,"merged_at":${options.mergedAt ? JSON.stringify(options.mergedAt) : "null"},"head":{"sha":"%s"}}\n' '${currentHead}'
else
  echo "unexpected gh args: $args" >&2
  exit 1
fi
`,
	);
	chmodSync(gh, 0o755);
	process.env.PATH = `${dir}:${process.env.PATH ?? ""}`;
	return {
		payloadPath,
		calls: () => existsSync(callsPath)
			? readFileSync(callsPath, "utf8").trim().split("\n").filter(Boolean)
			: [],
		postCount: () => existsSync(postsPath)
			? readFileSync(postsPath, "utf8").trim().split("\n").filter(Boolean).length
			: 0,
		payload: () => existsSync(payloadPath)
			? JSON.parse(readFileSync(payloadPath, "utf8")) as Record<string, unknown>
			: undefined,
	};
}

function installFakePublishingGh(currentHead = "a".repeat(40), patchless = false): string {
	return installPublishingProbe({ currentHead, patchless }).payloadPath;
}

function createHarness(
	initialBranch: any[] = [],
	identity = session,
	options: HarnessOptions = {},
): Harness {
	let nextId = 1;
	const handlers = new Map<string, Array<(event: any, ctx: any) => any>>();
	const commands = new Map<string, (args: string, ctx: any) => Promise<void>>();
	const tools = new Map<string, any>();
	const branch = [...initialBranch];
	const notifications: string[] = [];
	const sentMessages: Array<{ message: any; options: any }> = [];
	let activeTools = ["read", "bash", ...REVIEW_LOOP_TOOL_NAMES];
	let aborts = 0;
	let promptPath = ownPromptPath;
	const sessionManager = {
		getBranch: () => [...branch],
		getSessionId: () => identity.id,
		getHeader: () => ({ type: "session", id: identity.id, timestamp: identity.startedAt, cwd: "/tmp" }),
		getLeafEntry: () => branch.at(-1),
	};
	const cwd = installFakeGh(options.repositoryDelayMs);
	if (options.projectConfig) {
		mkdirSync(join(cwd, ".pi"), { recursive: true });
		writeFileSync(join(cwd, ".pi", "pr-review.json"), JSON.stringify(options.projectConfig));
	}
	const ctx = {
		cwd,
		mode: "json",
		isProjectTrusted: () => options.projectConfig !== undefined,
		abort: () => {
			aborts++;
		},
		sessionManager,
		ui: { notify: (message: string) => notifications.push(message) },
	};
	const pi = {
		on: (name: string, handler: (event: any, ctx: any) => any) => {
			const registered = handlers.get(name) ?? [];
			registered.push(handler);
			handlers.set(name, registered);
		},
		registerCommand: (name: string, options: { handler: (args: string, ctx: any) => Promise<void> }) => {
			commands.set(name, options.handler);
		},
		registerTool: (definition: any) => {
			tools.set(definition.name, definition);
			if (!activeTools.includes(definition.name)) activeTools.push(definition.name);
		},
		appendEntry: (customType: string, data: unknown) => {
			if (customType === COMPLETED_REVIEW_ENTRY_TYPE && options.persistenceFailure) {
				throw new Error(options.persistenceFailure);
			}
			branch.push({ type: "custom", id: `custom-${nextId++}`, customType, data });
			if (options.operationLogPath) appendFileSync(options.operationLogPath, `append:${customType}\n`);
		},
		sendMessage: (message: any, options: any) => {
			sentMessages.push({ message, options });
		},
		getActiveTools: () => [...activeTools],
		setActiveTools: (next: string[]) => {
			activeTools = [...next];
		},
		getCommands: () => [{
			name: "pr-review",
			source: "prompt",
			sourceInfo: { path: promptPath },
		}],
	};
	const loopCoordinator = new ReviewLoopCoordinator(pi as any);
	const selfReviewCoordinator = new SelfReviewPermitCoordinator(pi as any, () => !!loopCoordinator.peek());
	reviewTable(pi as any, loopCoordinator, selfReviewCoordinator, repairReviewOutput, prepareFallbackPayload);
	return {
		handlers,
		commands,
		tools,
		branch,
		notifications,
		sentMessages,
		activeTools: () => [...activeTools],
		abortCount: () => aborts,
		selfReviewCoordinator,
		setPromptPath: (next: string) => {
			promptPath = next;
		},
		ctx,
		appendMessage(message: any, id = `message-${nextId++}`) {
			const entry = { type: "message", id, message };
			branch.push(entry);
			return entry;
		},
		async emit(name: string, event: any) {
			const results = [];
			for (const handler of handlers.get(name) ?? []) results.push(await handler(event, ctx));
			return results;
		},
	};
}

function persistedInlineReview(identity = session, allowStalePublish = true): any {
	const cache = new CompletedReviewCache();
	const record = cache.remember(
		review,
		{ ...invocation, allowStalePublish },
		repository,
	);
	return cache.persist(record, identity);
}

function completedReviewMessage(): any {
	return {
		role: "assistant",
		stopReason: "stop",
		content: [{ type: "text", text: JSON.stringify(review) }],
	};
}

async function finishReviewTurn(harness: Harness, prompt: string): Promise<void> {
	await harness.emit("input", { text: prompt, source: "interactive" });
	const message = completedReviewMessage();
	await harness.emit("message_end", { message });
	harness.appendMessage(message);
	await harness.emit("turn_end", { message, toolResults: [] });
}

type PostingPath = "automatic" | "comment" | "slash" | "direct";

async function exercisePostingPath(
	postingPath: PostingPath,
	options: { postFailure?: string; operationLogPath?: string } = {},
): Promise<{ harness: Harness; probe: PublishingProbe; inputResults: any[] }> {
	const cached = postingPath === "slash" || postingPath === "direct";
	const initialBranch = cached
		? [{ type: "custom", id: "cache", customType: COMPLETED_REVIEW_ENTRY_TYPE, data: persistedInlineReview() }]
		: [];
	const harness = createHarness(initialBranch, session, {
		...(postingPath === "automatic" ? { projectConfig: { autoPostReviews: true } } : {}),
		...(options.operationLogPath ? { operationLogPath: options.operationLogPath } : {}),
	});
	if (cached) await harness.emit("session_start", { reason: "reload" });
	const probe = installPublishingProbe({
		...(options.postFailure ? { postFailure: options.postFailure } : {}),
		...(options.operationLogPath ? { operationLogPath: options.operationLogPath } : {}),
	});
	let inputResults: any[] = [];
	if (postingPath === "automatic") await finishReviewTurn(harness, "/pr-review 7");
	else if (postingPath === "comment") await finishReviewTurn(harness, "/pr-review 7 --comment");
	else if (postingPath === "slash") await harness.commands.get("pr-review-publish")!("7", harness.ctx);
	else {
		inputResults = await harness.emit("input", {
			text: "publish the cached review for PR #7",
			source: "interactive",
		});
	}
	return { harness, probe, inputResults };
}

describe("completed review extension lifecycle", () => {
	test("uses the light subagent to correct invalid final JSON once and attempts publication", async () => {
		const harness = createHarness();
		repairOutput = JSON.stringify(review);
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		// Prose-prefixed output is not auto-healable (only a single surrounding code
		// fence is), so it still routes through the one-shot repair path.
		const preamble = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: `Here is the completed review:\n${JSON.stringify(review)}` }],
		};
		await harness.emit("message_end", { message: preamble });
		expect(harness.sentMessages).toHaveLength(0);
		expect(harness.notifications.some((message) => message.includes("light repair subagent"))).toBeTrue();
		expect(harness.activeTools()).toEqual([]);

		const payloadPath = installFakePublishingGh();
		await new Promise((resolve) => setTimeout(resolve, 700));

		expect(harness.sentMessages).toHaveLength(0);
		expect(harness.notifications.some((message) => message.includes("PR review posted"))).toBeTrue();
		expect(harness.branch.some((entry) => entry.customType === COMPLETED_REVIEW_ENTRY_TYPE)).toBeTrue();
		expect(JSON.parse(readFileSync(payloadPath, "utf8")).body).toContain("Checks lifecycle persistence");
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
	});

	test("aborts and revokes repair authority when the correction attempts a tool call", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		const invalid = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: "not json" }],
		};
		await harness.emit("message_end", { message: invalid });
		expect(harness.activeTools()).toEqual([]);

		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "toolUse",
				content: [{ type: "toolCall", id: "repair-bash", name: "bash", arguments: { command: "echo unsafe" } }],
			},
		});

		expect(harness.abortCount()).toBe(1);
		expect(harness.sentMessages).toHaveLength(0);
		expect(harness.notifications.some((message) => message.includes("correction attempted to call tools"))).toBeTrue();
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
	});

	test("immediately clears and aborts a cancelled repair", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		const invalid = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: "not json" }],
		};
		await harness.emit("message_end", { message: invalid });
		expect(harness.activeTools()).toEqual([]);

		const overlap = await harness.emit("input", {
			text: "do something unrelated",
			source: "interactive",
			streamingBehavior: "steer",
		});
		expect(overlap).toContainEqual({ action: "handled" });
		expect(harness.abortCount()).toBe(1);
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
		expect(harness.notifications.some((message) => message.includes("was not queued"))).toBeTrue();

		const staleCorrection = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: JSON.stringify(review) }],
		};
		await harness.emit("message_end", { message: staleCorrection });
		harness.appendMessage(staleCorrection, "stale-correction");
		await harness.emit("turn_end", { message: staleCorrection, toolResults: [] });
		expect(harness.notifications.some((message) => message.includes("PR review posted"))).toBeFalse();
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);

		await harness.emit("agent_settled", {});
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
	});

	test("forgets a repaired completion when cancellation wins during repository resolution", async () => {
		const harness = createHarness([], session, { repositoryDelayMs: 200 });
		repairOutput = JSON.stringify(review);
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		await harness.emit("message_end", {
			message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "not json" }] },
		});
		// Let the mocked repair start the deliberately delayed repository lookup.
		await new Promise((resolve) => setTimeout(resolve, 20));
		await harness.emit("input", { text: "cancel", source: "interactive", streamingBehavior: "steer" });
		await new Promise((resolve) => setTimeout(resolve, 700));
		const probe = installPublishingProbe();
		await harness.commands.get("pr-review-publish")!("7", harness.ctx);
		expect(probe.postCount()).toBe(0);
	});

	test("falls back to one light-model payload and host-owned gh posting attempt", async () => {
		const harness = createHarness();
		const probe = installPublishingProbe();
		fallbackPayload = {
			commit_id: "a".repeat(40),
			event: "COMMENT",
			body: "completed review prose",
		};
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		const malformed = `Here is the completed review:\n${JSON.stringify(review)}`;
		const invalid = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: malformed }],
		};
		await harness.emit("message_end", { message: invalid });
		await new Promise((resolve) => setTimeout(resolve, 700));

		expect(fallbackPayloadCalls).toEqual([{ text: malformed, reviewedHeadSha: "a".repeat(40) }]);
		expect(probe.postCount()).toBe(1);
		expect(probe.payload()?.event).toBe("COMMENT");
		expect(probe.payload()?.body).toContain("completed review prose");
		expect(harness.notifications.some((message) => message.includes("PR review posted"))).toBeTrue();
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
	});

	test("stops after one failed correction and fallback payload attempt", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		const invalid = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: `Review:\n${JSON.stringify(review)}` }],
		};
		await harness.emit("message_end", { message: invalid });
		expect(harness.sentMessages).toHaveLength(0);
		expect(harness.activeTools()).toEqual([]);
		await new Promise((resolve) => setTimeout(resolve, 700));

		// Both one-shot attempts consume authority, so a later malformed
		// assistant message cannot start another repair or posting loop.
		await harness.emit("message_end", { message: invalid });
		expect(harness.sentMessages).toHaveLength(0);
		expect(fallbackPayloadCalls).toHaveLength(1);
		expect(harness.notifications.some((message) => message.includes("did not produce a valid COMMENT payload"))).toBeTrue();
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
	});

	test("does not grant gh fallback posting without frozen publication authority", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		await harness.emit("message_end", {
			message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "not json" }] },
		});
		await new Promise((resolve) => setTimeout(resolve, 20));

		expect(fallbackPayloadCalls).toHaveLength(0);
		expect(harness.notifications.some((message) => message.includes("did not produce valid final JSON"))).toBeTrue();
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
	});

	test("persists a reference before publishing after Pi stores exact assistant JSON", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		const message = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: JSON.stringify(review) }],
		};
		await harness.emit("message_end", { message });
		const assistantEntry = harness.appendMessage(message, "assistant-review");
		await harness.emit("turn_end", { message, toolResults: [] });

		const persisted = harness.branch.findLast(
			(entry) => entry.type === "custom" && entry.customType === COMPLETED_REVIEW_ENTRY_TYPE,
		);
		expect(persisted?.data.reviewEntryId).toBe(assistantEntry.id);
		expect(persisted?.data.review).toBeUndefined();
		expect(harness.notifications.some((message) => message.includes("PR review publish failed"))).toBeTrue();
	});

	test("persists a reference for pretty, noncanonical equivalent assistant JSON", async () => {
		const harness = createHarness();
		const probe = installPublishingProbe();
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "interactive" });
		const noncanonicalJson = JSON.stringify(review, null, 2).replace(
			"Lifecycle review",
			"Lifecycle\\u0020review",
		);
		expect(JSON.parse(noncanonicalJson)).toEqual(review);
		expect(noncanonicalJson).toContain("\\u0020");
		expect(noncanonicalJson).not.toBe(JSON.stringify(review));
		const message = {
			role: "assistant",
			stopReason: "stop",
			content: [{ type: "text", text: noncanonicalJson }],
		};
		await harness.emit("message_end", { message });
		const assistantEntry = harness.appendMessage(message, "noncanonical-assistant-review");
		await harness.emit("turn_end", { message, toolResults: [] });

		const persisted = harness.branch.findLast(
			(entry) => entry.type === "custom" && entry.customType === COMPLETED_REVIEW_ENTRY_TYPE,
		);
		expect(assistantEntry.id).toBe("noncanonical-assistant-review");
		expect(persisted?.data.reviewEntryId).toBe(assistantEntry.id);
		expect(persisted?.data.review).toBeUndefined();
		expect(probe.postCount()).toBe(1);
		expect(probe.payload()?.body).toContain("Checks lifecycle persistence.");
		expect(harness.notifications.some((notification) => notification.includes("PR review posted"))).toBeTrue();
	});

	test("restores on session_start, clears on tree navigation, and scopes reused IDs by header", async () => {
		const persisted = persistedInlineReview();
		const cacheEntry = { type: "custom", id: "cache", customType: COMPLETED_REVIEW_ENTRY_TYPE, data: persisted };
		const harness = createHarness([cacheEntry]);
		await harness.emit("session_start", { reason: "reload" });
		await harness.commands.get("pr-review-publish")!("7 --allow-stale", harness.ctx);
		expect(harness.notifications.some((message) => message.includes("No completed review"))).toBeFalse();

		harness.branch.splice(0);
		harness.notifications.splice(0);
		await harness.emit("session_tree", { newLeafId: null, oldLeafId: "cache" });
		expect(harness.branch.at(-1)?.customType).toBe(COMPLETED_REVIEW_BRANCH_ANCHOR_TYPE);
		await harness.commands.get("pr-review-publish")!("7 --allow-stale", harness.ctx);
		expect(harness.notifications.some((message) => message.includes("No completed review"))).toBeTrue();

		const reusedId = createHarness([cacheEntry], { id: session.id, startedAt: "2026-07-14T00:00:00.000Z" });
		await reusedId.emit("session_start", { reason: "fork" });
		await reusedId.commands.get("pr-review-publish")!("7 --allow-stale", reusedId.ctx);
		expect(reusedId.notifications.some((message) => message.includes("No completed review"))).toBeTrue();
	});

	test("exposes self-review only for a direct clean top-level task and hides it for /pr-review", async () => {
		const harness = createHarness();
		await harness.emit("session_start", { reason: "startup" });
		await harness.emit("input", { text: "implement the requested change", source: "interactive" });
		expect(harness.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
		await harness.emit("before_agent_start", { prompt: "implement the requested change" });
		expect(harness.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);
		await harness.emit("agent_end", { messages: [] });
		expect(harness.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);
		await harness.emit("agent_settled", {});
		expect(harness.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);

		await harness.emit("input", { text: "implement another change", source: "rpc" });
		await harness.emit("before_agent_start", { prompt: "implement another change" });
		expect(harness.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);
		await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		expect(harness.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
		expect(harness.activeTools()).toEqual([...BASE_ACTIVE_TOOLS, ...REVIEW_LOOP_TOOL_NAMES]);
	});

	test("binds self-review only from a sole tool call and preserves authority after denied dispatches", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "implement safely", source: "interactive" });
		await harness.emit("before_agent_start", { prompt: "implement safely" });

		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "toolUse",
				content: [
					{ type: "toolCall", id: "mixed-self", name: SELF_REVIEW_TOOL_NAME, arguments: {} },
					{ type: "toolCall", id: "mixed-edit", name: "edit", arguments: {} },
				],
			},
		});
		expect(await harness.selfReviewCoordinator.consume("mixed-self", harness.ctx)).toBeUndefined();
		expect(harness.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);

		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "toolUse",
				content: [
					{ type: "toolCall", id: "multiple-one", name: SELF_REVIEW_TOOL_NAME, arguments: {} },
					{ type: "toolCall", id: "multiple-two", name: SELF_REVIEW_TOOL_NAME, arguments: {} },
				],
			},
		});
		expect(await harness.selfReviewCoordinator.consume("multiple-one", harness.ctx)).toBeUndefined();
		expect(await harness.selfReviewCoordinator.consume("direct-unbound", harness.ctx)).toBeUndefined();
		expect(harness.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);

		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "error",
				content: [{ type: "toolCall", id: "rejected-self", name: SELF_REVIEW_TOOL_NAME, arguments: {} }],
			},
		});
		expect(await harness.selfReviewCoordinator.consume("rejected-self", harness.ctx)).toBeUndefined();
		expect(harness.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);

		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "toolUse",
				content: [{ type: "toolCall", id: "sole-self", name: SELF_REVIEW_TOOL_NAME, arguments: {} }],
			},
		});
		expect(await harness.selfReviewCoordinator.consume("wrong-id", harness.ctx)).toBeUndefined();
		expect(harness.activeTools()).toContain(SELF_REVIEW_TOOL_NAME);
		expect(await harness.selfReviewCoordinator.consume("sole-self", harness.ctx)).toBeDefined();
		expect(harness.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
	});

	test("exposes review tools only for trusted command-loop phases", async () => {
		const harness = createHarness();
		await harness.emit("session_start", { reason: "startup" });
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);

		await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		expect(harness.activeTools()).toEqual([...BASE_ACTIVE_TOOLS, ...REVIEW_LOOP_TOOL_NAMES]);

		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "toolUse",
				content: [{ type: "toolCall", name: "review_subagents" }],
			},
		});
		expect(harness.activeTools()).toEqual([...BASE_ACTIVE_TOOLS, ...REVIEW_LOOP_TOOL_NAMES]);

		await harness.emit("input", { text: "do something unrelated", source: "interactive", streamingBehavior: "steer" });
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);

		const denied = await harness.emit("input", { text: "/pr-review 8", source: "extension" });
		expect(denied).toContainEqual({ action: "handled" });
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
	});

	test("rejects queued and shadowed prompt invocations", async () => {
		const harness = createHarness();
		await harness.emit("session_start", { reason: "startup" });
		await harness.emit("input", { text: "/pr-review 6", source: "interactive" });
		const queued = await harness.emit("input", {
			text: "/pr-review 7",
			source: "interactive",
			streamingBehavior: "followUp",
		});
		expect(queued).toContainEqual({ action: "handled" });
		expect(harness.abortCount()).toBe(1);
		expect(harness.activeTools()).not.toContain("review_subagent");

		harness.setPromptPath("/tmp/other-package/prompts/pr-review.md");
		const shadowed = await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		expect(shadowed).toContainEqual({ action: "handled" });
		expect(harness.activeTools()).not.toContain("review_subagent");
	});

	test("publishes a direct comments request without an agent turn", async () => {
		const persisted = persistedInlineReview(session, false);
		const cacheEntry = { type: "custom", id: "cache", customType: COMPLETED_REVIEW_ENTRY_TYPE, data: persisted };
		const harness = createHarness([cacheEntry]);
		await harness.emit("session_start", { reason: "reload" });
		expect(harness.tools.has("pr_review_publish")).toBeFalse();
		const currentHead = "b".repeat(40);
		const payloadPath = installFakePublishingGh(currentHead);
		const handled = await harness.emit("input", {
			text: "post the comments",
			source: "interactive",
		});
		expect(handled).toContainEqual({ action: "handled" });
		expect(harness.notifications.some((message) => message.includes("posted"))).toBeTrue();
		const payload = JSON.parse(readFileSync(payloadPath, "utf8"));
		expect(payload.comments).toBeUndefined();
		expect(payload.body).toContain("[!WARNING]");
		expect(payload.body).toContain("This review was generated for commit");
		expect(payload.body).toContain("a".repeat(40));
		expect(payload.body).toContain(currentHead);
	});

	test("surfaces patchless inline fallback in the posted notification", async () => {
		const patchlessReview: ReviewLike = {
			...review,
			findings: [
				{
					title: "[P2] Patchless finding",
					severity: "P2",
					blocking: false,
					body: "This finding must remain visible in the summary.",
					confidence_score: 0.9,
					code_location: {
						absolute_file_path: "src/parser.ts",
						line_range: { start: 2, end: 2 },
						side: "RIGHT",
						commentable: true,
					},
				},
			],
		};
		const cache = new CompletedReviewCache();
		const record = cache.remember(patchlessReview, invocation, repository);
		const persisted = cache.persist(record, session);
		const cacheEntry = { type: "custom", id: "cache", customType: COMPLETED_REVIEW_ENTRY_TYPE, data: persisted };
		const harness = createHarness([cacheEntry]);
		await harness.emit("session_start", { reason: "reload" });
		const payloadPath = installFakePublishingGh("a".repeat(40), true);

		await harness.commands.get("pr-review-publish")!("7", harness.ctx);

		expect(harness.notifications.some((message) => message.includes("1 inline finding kept in the summary"))).toBeTrue();
		const payload = JSON.parse(readFileSync(payloadPath, "utf8"));
		expect(payload.comments).toBeUndefined();
		expect(payload.body).toContain("[P2] Patchless finding");
	});

	test("rejects extension-generated, queued, and steering publish requests", async () => {
		const persisted = persistedInlineReview();
		const cacheEntry = { type: "custom", id: "cache", customType: COMPLETED_REVIEW_ENTRY_TYPE, data: persisted };
		const harness = createHarness([cacheEntry]);
		await harness.emit("session_start", { reason: "reload" });
		const payloadPath = installFakePublishingGh();

		for (const event of [
			{ text: "post the inline review", source: "extension" },
			{ text: "post the inline review", source: "interactive", streamingBehavior: "followUp" },
			{ text: "post the inline review", source: "rpc", streamingBehavior: "steer" },
		]) {
			const results = await harness.emit("input", event);
			expect(results).not.toContainEqual({ action: "handled" });
		}
		expect(() => readFileSync(payloadPath, "utf8")).toThrow();
	});

	test("does not publish an older cache entry while a review is active", async () => {
		const persisted = persistedInlineReview();
		const cacheEntry = { type: "custom", id: "cache", customType: COMPLETED_REVIEW_ENTRY_TYPE, data: persisted };
		const harness = createHarness([cacheEntry]);
		await harness.emit("session_start", { reason: "reload" });
		await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		const payloadPath = installFakePublishingGh();

		const handled = await harness.emit("input", { text: "post the inline review", source: "interactive" });
		expect(handled).toContainEqual({ action: "handled" });
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
		expect(harness.notifications.some((message) => message.includes("will not post an older cached result"))).toBeTrue();
		expect(() => readFileSync(payloadPath, "utf8")).toThrow();
	});

	test("publish command follows captured stale config unless explicitly overridden", async () => {
		const persisted = persistedInlineReview(session, false);
		const cacheEntry = { type: "custom", id: "cache", customType: COMPLETED_REVIEW_ENTRY_TYPE, data: persisted };
		const harness = createHarness([cacheEntry]);
		await harness.emit("session_start", { reason: "reload" });
		const currentHead = "b".repeat(40);
		const payloadPath = installFakePublishingGh(currentHead);

		await harness.commands.get("pr-review-publish")!("7", harness.ctx);
		expect(harness.notifications.some((message) => message.includes("--allow-stale"))).toBeTrue();
		expect(() => readFileSync(payloadPath, "utf8")).toThrow();

		harness.notifications.splice(0);
		await harness.commands.get("pr-review-publish")!("7 --allow-stale", harness.ctx);
		expect(harness.notifications.some((message) => message.includes("posted"))).toBeTrue();
		const payload = JSON.parse(readFileSync(payloadPath, "utf8"));
		expect(payload.comments).toBeUndefined();
		expect(payload.body).toContain("a".repeat(40));
		expect(payload.body).toContain(currentHead);
	});

	test("registered commands explicitly revoke an active review", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		expect(harness.activeTools()).toContain("review_subagent");
		await harness.commands.get("pr-review-publish")!("7", harness.ctx);
		expect(harness.activeTools()).not.toContain("review_subagent");
		expect(harness.notifications.some((message) => message.includes("review was cancelled"))).toBeTrue();
	});

	test("invalid publish commands revoke authority before argument parsing", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		expect(harness.activeTools()).toContain("review_subagent");
		await harness.commands.get("pr-review-publish")!("not-a-pr", harness.ctx);
		expect(harness.activeTools()).not.toContain("review_subagent");
		expect(harness.notifications.some((message) => message.includes("Invalid /pr-review-publish"))).toBeTrue();
	});

	test("preserves confirmed non-open authority through fallback publication", async () => {
		const harness = createHarness();
		await harness.emit("input", { text: "/pr-review 7 --comment", source: "rpc" });
		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "stop",
				content: [{
					type: "text",
					text: `PR #7 is MERGED (head ${"a".repeat(40)}). Review it anyway? Reply yes, or rerun with --include-closed to proceed non-interactively.`,
				}],
			},
		});
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);

		await harness.emit("input", { text: "yes", source: "rpc" });
		expect(harness.activeTools()).toEqual([...BASE_ACTIVE_TOOLS, ...REVIEW_LOOP_TOOL_NAMES]);

		const probe = installPublishingProbe({ state: "closed", mergedAt: "2026-07-24T00:00:00Z" });
		fallbackPayload = { commit_id: "a".repeat(40), event: "COMMENT", body: "confirmed fallback" };
		await harness.emit("message_end", {
			message: {
				role: "assistant",
				stopReason: "stop",
				content: [{ type: "text", text: `Review:\n${JSON.stringify(review)}` }],
			},
		});
		await new Promise((resolve) => setTimeout(resolve, 700));
		expect(probe.postCount()).toBe(1);
		expect(harness.notifications.some((message) => message.includes("non-open PR"))).toBeTrue();
	});

	test("does not append a redundant anchor for summarized tree navigation", async () => {
		const harness = createHarness();
		await harness.emit("session_tree", {
			newLeafId: "summary",
			oldLeafId: "old",
			summaryEntry: { type: "branch_summary", id: "summary" },
		});
		expect(harness.branch.some((entry) => entry.customType === COMPLETED_REVIEW_BRANCH_ANCHOR_TYPE)).toBeFalse();
	});
});

describe("end-to-end review posting invariants", () => {
	for (const postingPath of ["automatic", "comment"] as const) {
		test(`posts a completed review through the ${postingPath} authority path`, async () => {
			const { harness, probe } = await exercisePostingPath(postingPath);

			expect(probe.postCount()).toBe(1);
			expect(probe.payload()).toMatchObject({
				commit_id: "a".repeat(40),
				event: "COMMENT",
			});
			expect(harness.notifications.some((message) => message.includes("PR review posted"))).toBeTrue();
			expect(
				harness.branch.some((entry) => entry.type === "custom" && entry.customType === COMPLETED_REVIEW_ENTRY_TYPE),
			).toBeTrue();
		});
	}

	for (const postingPath of ["slash", "direct"] as const) {
		test(`publishes the cached review through the ${postingPath} path without an agent rerun`, async () => {
			const { harness, probe, inputResults } = await exercisePostingPath(postingPath);

			expect(probe.postCount()).toBe(1);
			expect(harness.sentMessages).toEqual([]);
			expect(harness.branch.filter((entry) => entry.type === "message")).toEqual([]);
			expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
			expect(harness.notifications.some((message) => message.includes("PR review posted"))).toBeTrue();
			if (postingPath === "direct") expect(inputResults).toContainEqual({ action: "handled" });
		});
	}

	test("keeps payload semantics equivalent across automatic, --comment, slash, and direct posting", async () => {
		const payloads: Record<PostingPath, Record<string, unknown>> = {} as Record<
			PostingPath,
			Record<string, unknown>
		>;
		for (const postingPath of ["automatic", "comment", "slash", "direct"] as const) {
			const { probe } = await exercisePostingPath(postingPath);
			const payload = probe.payload();
			expect(payload).toBeDefined();
			payloads[postingPath] = payload!;
		}

		expect(payloads.comment).toEqual(payloads.automatic);
		expect(payloads.slash).toEqual(payloads.automatic);
		expect(payloads.direct).toEqual(payloads.automatic);
		expect(payloads.automatic.event).toBe("COMMENT");
		expect(payloads.automatic.body).toContain("Checks lifecycle persistence.");
		expect(payloads.automatic.body).toContain("<!-- pi-pr-review:");
	});

	test("persists the completed review after message storage and before automatic POST", async () => {
		const sequenceDir = mkdtempSync(join(tmpdir(), "pi-pr-review-sequence-"));
		tempDirs.push(sequenceDir);
		const operationLogPath = join(sequenceDir, "operations.log");
		const harness = createHarness([], session, {
			projectConfig: { autoPostReviews: true },
			operationLogPath,
		});
		const probe = installPublishingProbe({ operationLogPath });
		await harness.emit("input", { text: "/pr-review 7", source: "interactive" });
		const message = completedReviewMessage();

		await harness.emit("message_end", { message });
		expect(
			harness.branch.some((entry) => entry.type === "custom" && entry.customType === COMPLETED_REVIEW_ENTRY_TYPE),
		).toBeFalse();
		expect(probe.postCount()).toBe(0);

		const assistantEntry = harness.appendMessage(message, "stored-review");
		await harness.emit("turn_end", { message, toolResults: [] });
		const persisted = harness.branch.findLast(
			(entry) => entry.type === "custom" && entry.customType === COMPLETED_REVIEW_ENTRY_TYPE,
		);
		const operations = readFileSync(operationLogPath, "utf8").trim().split("\n");
		const persistenceIndex = operations.indexOf(`append:${COMPLETED_REVIEW_ENTRY_TYPE}`);
		const postIndex = operations.indexOf("gh:POST");

		expect(persisted?.data.reviewEntryId).toBe(assistantEntry.id);
		expect(persistenceIndex).toBeGreaterThanOrEqual(0);
		expect(postIndex).toBeGreaterThan(persistenceIndex);
		expect(probe.postCount()).toBe(1);
	});

	test("warns about persistence failure before continuing with the frozen publication", async () => {
		const harness = createHarness([], session, {
			projectConfig: { autoPostReviews: true },
			persistenceFailure: "intentional persistence failure",
		});
		const probe = installPublishingProbe();
		await finishReviewTurn(harness, "/pr-review 7");

		const warningIndex = harness.notifications.findIndex((message) =>
			message.includes("cache will not survive an extension reload"),
		);
		const postedIndex = harness.notifications.findIndex((message) => message.includes("PR review posted"));
		expect(warningIndex).toBeGreaterThanOrEqual(0);
		expect(postedIndex).toBeGreaterThan(warningIndex);
		expect(probe.postCount()).toBe(1);
		expect(
			harness.branch.some((entry) => entry.type === "custom" && entry.customType === COMPLETED_REVIEW_ENTRY_TYPE),
		).toBeFalse();
	});

	test("denies queued and extension-generated review or cached-publish authority", async () => {
		const cacheEntry = {
			type: "custom",
			id: "cache",
			customType: COMPLETED_REVIEW_ENTRY_TYPE,
			data: persistedInlineReview(),
		};
		const harness = createHarness([cacheEntry]);
		await harness.emit("session_start", { reason: "reload" });
		const probe = installPublishingProbe();

		const extensionPublish = await harness.emit("input", {
			text: "publish the cached review for PR #7",
			source: "extension",
		});
		const queuedPublish = await harness.emit("input", {
			text: "publish the cached review for PR #7",
			source: "interactive",
			streamingBehavior: "followUp",
		});
		const extensionReview = await harness.emit("input", {
			text: "/pr-review 7 --comment",
			source: "extension",
		});
		const queuedReview = await harness.emit("input", {
			text: "/pr-review 7 --comment",
			source: "interactive",
			streamingBehavior: "followUp",
		});
		const message = completedReviewMessage();
		await harness.emit("message_end", { message });
		harness.appendMessage(message);
		await harness.emit("turn_end", { message, toolResults: [] });

		expect(extensionPublish).not.toContainEqual({ action: "handled" });
		expect(queuedPublish).not.toContainEqual({ action: "handled" });
		expect(extensionReview).toContainEqual({ action: "handled" });
		expect(queuedReview).toContainEqual({ action: "handled" });
		expect(harness.abortCount()).toBe(1);
		expect(harness.activeTools()).toEqual(BASE_ACTIVE_TOOLS);
		expect(probe.postCount()).toBe(0);
	});

	test("performs reconciliation after a rejected write without issuing a second POST", async () => {
		for (const postingPath of ["automatic", "comment", "slash", "direct"] as const) {
			const { harness, probe } = await exercisePostingPath(postingPath, {
				postFailure: "gh: HTTP 422: Validation Failed",
			});
			const calls = probe.calls();
			const postIndexes = calls
				.map((call, index) => call.includes("--method POST") ? index : -1)
				.filter((index) => index >= 0);
			const reconciliationCalls = calls.slice(postIndexes[0]! + 1);

			expect(probe.postCount()).toBe(1);
			expect(postIndexes).toHaveLength(1);
			expect(reconciliationCalls.some((call) => call.includes("pulls/7/reviews?per_page=100"))).toBeTrue();
			expect(reconciliationCalls.some((call) => call.includes("issues/7/comments?per_page=100"))).toBeTrue();
			expect(harness.notifications.some((message) => message.includes("publish failed"))).toBeTrue();
		}
	});
});
