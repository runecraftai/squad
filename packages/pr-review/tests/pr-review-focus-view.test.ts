import { describe, expect, mock, test } from "bun:test";
import { ReviewLoopCoordinator } from "../lib/pr-review-loop.ts";
import { parsePublishMode, resolveAutoPostSetting } from "../lib/pr-review-publish.ts";
import type { ReviewFocusSnapshot } from "../lib/pr-review-focus.ts";

const keyData: Record<string, string> = {
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
};

mock.module("@earendil-works/pi-tui", () => ({
	Container: class {
		addChild() {}
	},
	fuzzyFilter: (items: unknown[]) => items,
	getKeybindings: () => ({ matches: () => false }),
	Input: class {},
	SelectList: class {},
	SettingsList: class {},
	Text: class {},
	matchesKey: (data: string, key: string) => keyData[key] === data,
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

const { default: registerReviewFocus, ReviewFocusView } = await import("../extensions/pr-review-focus.ts");

const theme = {
	fg: (_color: string, text: string) => text,
	bold: (text: string) => text,
} as any;

function snapshot(): ReviewFocusSnapshot {
	return {
		generation: 1,
		sequence: 4,
		droppedPasses: 0,
		passes: [
			{
				key: "pass-1",
				label: "correctness",
				tier: "heavy",
				status: "running",
				attempt: 1,
				model: "provider/strong",
				assistantText: Array.from({ length: 30 }, (_, index) => `line ${index + 1}`).join("\n"),
				tools: [{ name: "read", status: "completed" }],
				evictedBytes: 0,
				sequence: 3,
			},
			{
				key: "pass-2",
				label: "security-performance",
				tier: "heavy",
				status: "queued",
				attempt: 0,
				assistantText: "",
				tools: [],
				evictedBytes: 0,
				sequence: 4,
			},
		],
	};
}

function viewHarness(initial = snapshot()) {
	let renders = 0;
	let closes = 0;
	let unsubscribes = 0;
	const tui = {
		terminal: { rows: 18 },
		requestRender: () => renders++,
	} as any;
	const view = new ReviewFocusView(tui, theme, initial, () => closes++);
	view.setUnsubscribe(() => unsubscribes++);
	return {
		view,
		tui,
		renders: () => renders,
		closes: () => closes,
		unsubscribes: () => unsubscribes,
	};
}

describe("review focus TUI", () => {
	test("renders live pass state and cycles between parallel reviewers", () => {
		const h = viewHarness();
		let rendered = h.view.render(80).join("\n");
		expect(rendered).toContain("PR Review Focus");
		expect(rendered).toContain("[1/2] correctness");
		expect(rendered).toContain("provider/strong");
		expect(rendered).toContain("read");
		expect(rendered).toContain("viewer is read-only");

		h.view.handleInput("\t");
		rendered = h.view.render(80).join("\n");
		expect(rendered).toContain("[2/2] security-performance");
		expect(rendered).toContain("(queued)");
		expect(h.renders()).toBeGreaterThan(0);

		h.view.handleInput("\x1b[Z");
		expect(h.view.render(80).join("\n")).toContain("[1/2] correctness");
	});

	test("coalesces burst snapshot updates into one render frame", async () => {
		const h = viewHarness();
		for (let index = 0; index < 25; index++) h.view.update({ ...snapshot(), sequence: 5 + index });
		expect(h.renders()).toBe(0);
		await Bun.sleep(25);
		expect(h.renders()).toBe(1);
	});

	test("scrolls long output and Escape only closes the viewer", () => {
		const h = viewHarness();
		const tail = h.view.render(60).join("\n");
		expect(tail).toContain("line 30");
		h.view.handleInput("\x1b[H");
		const top = h.view.render(60).join("\n");
		expect(top).toContain("Tool activity");
		expect(top).not.toContain("line 30");

		h.view.handleInput("\x1b");
		expect(h.closes()).toBe(1);
		expect(h.unsubscribes()).toBe(1);
		h.view.handleInput("\x1b");
		expect(h.closes()).toBe(1);
	});

	test("closes synchronously when loop authority purges the snapshot", async () => {
		const h = viewHarness();
		h.view.update({ ...snapshot(), sequence: 5 });
		h.view.update(undefined);
		expect(h.closes()).toBe(1);
		expect(h.unsubscribes()).toBe(1);
		await Bun.sleep(25);
		expect(h.renders()).toBe(0);
	});
});

function commandHarness(mode: "tui" | "json" = "tui") {
	let activeTools = ["read", "bash"];
	const commands = new Map<string, any>();
	const shortcuts = new Map<string, any>();
	const notifications: string[] = [];
	let component: ReviewFocusView | undefined;
	const pi = {
		getActiveTools: () => [...activeTools],
		setActiveTools: (next: string[]) => activeTools = [...next],
		registerCommand: (name: string, options: any) => commands.set(name, options.handler),
		registerShortcut: (key: string, options: any) => shortcuts.set(key, options.handler),
	};
	const coordinator = new ReviewLoopCoordinator(pi as any);
	const ctx = {
		cwd: "/tmp/repo",
		mode,
		hasUI: true,
		sessionManager: {
			getSessionId: () => "session-1",
			getHeader: () => ({ id: "session-1", timestamp: "2026-07-13T00:00:00.000Z" }),
		},
		ui: {
			notify: (message: string) => notifications.push(message),
			custom: <T>(factory: any) => new Promise<T>((resolve) => {
				component = factory(
					{ terminal: { rows: 20 }, requestRender: () => {} },
					theme,
					{},
					resolve,
				);
			}),
		},
	};
	registerReviewFocus(pi as any, coordinator);
	return { commands, shortcuts, notifications, coordinator, ctx, component: () => component };
}

describe("review focus activation", () => {
	test("opens through command or shortcut without revoking review authority", async () => {
		const h = commandHarness();
		h.coordinator.begin(
			parsePublishMode("/pr-review 7"),
			resolveAutoPostSetting({ autoPostReviews: false }),
			"interactive",
			h.ctx as any,
		);
		const lease = h.coordinator.acquire(h.ctx as any)!;
		const publisher = h.coordinator.createFocusPublisher(lease, h.ctx as any, {
			key: "pass-1",
			label: "overview",
			tier: "light",
		})!;
		publisher.publish({ type: "attempt_started", attempt: 1 });

		const command = h.commands.get("pr-review-focus")!("", h.ctx);
		await Promise.resolve();
		expect(h.component()).toBeDefined();
		expect(h.coordinator.isLeaseActive(lease, h.ctx as any)).toBeTrue();
		h.component()!.handleInput("\x1b");
		await command;
		expect(h.coordinator.isLeaseActive(lease, h.ctx as any)).toBeTrue();
		expect(h.shortcuts.has("ctrl+alt+r")).toBeTrue();
	});

	test("denies inactive and non-TUI activation", async () => {
		const inactive = commandHarness();
		await inactive.commands.get("pr-review-focus")!("", inactive.ctx);
		expect(inactive.notifications.at(-1)).toContain("No active user-initiated");

		const json = commandHarness("json");
		await json.commands.get("pr-review-focus")!("", json.ctx);
		expect(json.notifications.at(-1)).toContain("interactive TUI");
	});

	test("loop cancellation closes an open viewer", async () => {
		const h = commandHarness();
		h.coordinator.begin(
			parsePublishMode("/pr-review 7"),
			resolveAutoPostSetting({ autoPostReviews: false }),
			"interactive",
			h.ctx as any,
		);
		const command = h.commands.get("pr-review-focus")!("", h.ctx);
		await Promise.resolve();
		h.coordinator.clear();
		await command;
		expect(h.coordinator.focusSnapshot(h.ctx as any)).toBeUndefined();
	});
});
