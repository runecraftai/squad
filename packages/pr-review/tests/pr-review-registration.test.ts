import { afterEach, describe, expect, mock, test } from "bun:test";
import { tmpdir } from "node:os";

mock.module("@earendil-works/pi-ai", () => ({
	StringEnum: (values: readonly string[], options: Record<string, unknown> = {}) => ({ enum: values, ...options }),
}));
mock.module("@earendil-works/pi-coding-agent", () => ({
	CONFIG_DIR_NAME: ".pi",
	getAgentDir: () => tmpdir(),
	getSelectListTheme: () => ({}),
	getSettingsListTheme: () => ({}),
}));
mock.module("@earendil-works/pi-tui", () => ({
	Container: class { addChild() {} },
	fuzzyFilter: () => [],
	getKeybindings: () => ({ matches: () => false }),
	Input: class {},
	SelectList: class {},
	SettingsList: class {},
	Text: class {},
	matchesKey: (data: string, key: string) => ({
		escape: "\x1b",
		"ctrl+c": "\x03",
		tab: "\t",
		"shift+tab": "\x1b[Z",
		right: "\x1b[C",
		left: "\x1b[D",
		up: "\x1b[A",
		down: "\x1b[B",
		pageUp: "\x1b[5~",
		pageDown: "\x1b[6~",
		home: "\x1b[H",
		end: "\x1b[F",
	} as Record<string, string>)[key] === data,
	truncateToWidth: (text: string, width: number, ellipsis = "…", pad = false) => {
		const truncated = text.length > width ? `${text.slice(0, Math.max(0, width - ellipsis.length))}${ellipsis}` : text;
		return pad ? truncated.padEnd(width) : truncated;
	},
	wrapTextWithAnsi: (text: string, width: number) => text.split("\n").flatMap((line) => {
		if (!line) return [""];
		const chunks: string[] = [];
		for (let index = 0; index < line.length; index += width) chunks.push(line.slice(index, index + width));
		return chunks;
	}),
}));
mock.module("typebox", () => {
	const schema = () => ({});
	return {
		Type: {
			Array: schema,
			Boolean: schema,
			Integer: (options: Record<string, unknown> = {}) => ({ type: "integer", ...options }),
			Literal: schema,
			Number: schema,
			Object: (properties: Record<string, unknown>, options: Record<string, unknown> = {}) => ({
				type: "object",
				properties,
				...options,
			}),
			Optional: schema,
			String: schema,
			Union: schema,
		},
	};
});

const registerPrReview = (await import("../extensions/index.ts")).default;
const { SELF_REVIEW_TOOL_NAME } = await import("../lib/pr-self-review.ts");

const originalPlatform = Object.getOwnPropertyDescriptor(process, "platform")!;
const originalPath = process.env.PATH;

afterEach(() => {
	Object.defineProperty(process, "platform", originalPlatform);
	if (originalPath === undefined) delete process.env.PATH;
	else process.env.PATH = originalPath;
});

function registrationHarness() {
	const handlers = new Map<string, Array<(event: any, ctx: any) => any>>();
	const tools = new Set<string>();
	const commands = new Set<string>();
	let activeTools = ["read"];
	const pi = {
		on(name: string, handler: (event: any, ctx: any) => any) {
			const registered = handlers.get(name) ?? [];
			registered.push(handler);
			handlers.set(name, registered);
		},
		registerTool(definition: { name: string }) {
			tools.add(definition.name);
			if (!activeTools.includes(definition.name)) activeTools.push(definition.name);
		},
		registerCommand(name: string) {
			commands.add(name);
		},
		registerShortcut() {},
		getActiveTools: () => [...activeTools],
		setActiveTools(next: string[]) {
			activeTools = [...next];
		},
		appendEntry() {},
		getCommands: () => [],
		sendMessage() {},
	};
	return { handlers, tools, commands, activeTools: () => [...activeTools], pi };
}

function expectWholeExtensionRegistered(harness: ReturnType<typeof registrationHarness>) {
	expect(harness.tools).toContain(SELF_REVIEW_TOOL_NAME);
	expect(harness.tools).toContain("review_subagent");
	expect(harness.tools).toContain("review_subagents");
	expect(harness.tools).toContain("pr_review_verify");
	expect(harness.commands).toContain("pr-review-config");
	expect(harness.commands).toContain("pr-review-publish");
	expect(harness.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
}

async function beginDirectTask(harness: ReturnType<typeof registrationHarness>, cwd: string) {
	const ctx = {
		cwd,
		sessionManager: {
			getSessionId: () => "registration-test",
			getHeader: () => ({ id: "registration-test", timestamp: "2026-07-13T00:00:00.000Z" }),
		},
	};
	for (const handler of harness.handlers.get("input") ?? []) {
		await handler({ text: "implement a change", source: "interactive" }, ctx);
	}
	for (const handler of harness.handlers.get("before_agent_start") ?? []) {
		await handler({ prompt: "implement a change" }, ctx);
	}
}

describe("extension registration without self-review prerequisites", () => {
	test("registers without Git and keeps the startup PATH failure local to self-review", async () => {
		process.env.PATH = "";
		const harness = registrationHarness();
		expect(() => registerPrReview(harness.pi as any)).not.toThrow();
		expectWholeExtensionRegistered(harness);

		// A later PATH mutation must not provide task-time executable authority.
		process.env.PATH = originalPath;
		await beginDirectTask(harness, process.cwd());
		expect(harness.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
	});

	test("registers on an unsupported platform and leaves only self-review unavailable", async () => {
		Object.defineProperty(process, "platform", { ...originalPlatform, value: "win32" });
		const harness = registrationHarness();
		expect(() => registerPrReview(harness.pi as any)).not.toThrow();
		expectWholeExtensionRegistered(harness);

		await beginDirectTask(harness, "C:\\missing-repository");
		expect(harness.activeTools()).not.toContain(SELF_REVIEW_TOOL_NAME);
	});
});
