import type {
	ExtensionAPI,
	ExtensionContext,
	Theme,
} from "@earendil-works/pi-coding-agent";
import {
	type Component,
	matchesKey,
	truncateToWidth,
	type TUI,
	wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import type {
	ReviewFocusPassSnapshot,
	ReviewFocusSnapshot,
} from "../lib/pr-review-focus.ts";
import { ReviewLoopCoordinator } from "../lib/pr-review-loop.ts";

const SHORTCUT = "ctrl+alt+r" as const;

function statusIcon(status: ReviewFocusPassSnapshot["status"]): string {
	switch (status) {
		case "queued": return "○";
		case "running": return "◉";
		case "retrying": return "↻";
		case "completed": return "✓";
		case "failed": return "✗";
		case "aborted": return "■";
	}
}

function statusColor(status: ReviewFocusPassSnapshot["status"]): "muted" | "warning" | "success" | "error" {
	switch (status) {
		case "queued": return "muted";
		case "running":
		case "retrying": return "warning";
		case "completed": return "success";
		case "failed":
		case "aborted": return "error";
	}
}

export class ReviewFocusView implements Component {
	private snapshot: ReviewFocusSnapshot;
	private selectedIndex = 0;
	private scrollTop = 0;
	private followTail = true;
	private unsubscribe?: () => void;
	private closed = false;
	private renderTimer?: ReturnType<typeof setTimeout>;

	constructor(
		private readonly tui: Pick<TUI, "requestRender" | "terminal">,
		private readonly theme: Theme,
		initial: ReviewFocusSnapshot,
		private readonly done: () => void,
	) {
		this.snapshot = initial;
	}

	setUnsubscribe(unsubscribe: (() => void) | undefined): void {
		this.unsubscribe = unsubscribe;
	}

	update(snapshot: ReviewFocusSnapshot | undefined): void {
		if (!snapshot) {
			this.close();
			return;
		}
		const selectedKey = this.snapshot.passes[this.selectedIndex]?.key;
		this.snapshot = snapshot;
		if (selectedKey) {
			const nextIndex = snapshot.passes.findIndex((pass) => pass.key === selectedKey);
			this.selectedIndex = nextIndex >= 0 ? nextIndex : Math.min(this.selectedIndex, Math.max(0, snapshot.passes.length - 1));
		} else {
			this.selectedIndex = Math.min(this.selectedIndex, Math.max(0, snapshot.passes.length - 1));
		}
		this.scheduleRender();
	}

	handleInput(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.close();
			return;
		}
		if (matchesKey(data, "tab") || matchesKey(data, "right")) {
			this.selectRelative(1);
			return;
		}
		if (matchesKey(data, "shift+tab") || matchesKey(data, "left")) {
			this.selectRelative(-1);
			return;
		}
		if (matchesKey(data, "up")) {
			this.followTail = false;
			this.scrollTop = Math.max(0, this.scrollTop - 1);
			this.tui.requestRender();
			return;
		}
		if (matchesKey(data, "down")) {
			this.followTail = false;
			this.scrollTop++;
			this.tui.requestRender();
			return;
		}
		if (matchesKey(data, "pageUp")) {
			this.followTail = false;
			this.scrollTop = Math.max(0, this.scrollTop - this.pageSize());
			this.tui.requestRender();
			return;
		}
		if (matchesKey(data, "pageDown")) {
			this.followTail = false;
			this.scrollTop += this.pageSize();
			this.tui.requestRender();
			return;
		}
		if (matchesKey(data, "home")) {
			this.followTail = false;
			this.scrollTop = 0;
			this.tui.requestRender();
			return;
		}
		if (matchesKey(data, "end")) {
			this.followTail = true;
			this.tui.requestRender();
		}
	}

	render(width: number): string[] {
		const safeWidth = Math.max(20, width);
		const height = Math.max(8, (this.tui.terminal.rows ?? 24) - 2);
		const passes = this.snapshot.passes;
		const pass = passes[this.selectedIndex];
		const lines: string[] = [];
		lines.push(truncateToWidth(this.theme.fg("accent", this.theme.bold("PR Review Focus")), safeWidth, "…", true));

		if (!pass) {
			lines.push(truncateToWidth(this.theme.fg("muted", "No reviewer passes have started yet."), safeWidth, "…", true));
			lines.push("");
			while (lines.length < height - 1) lines.push("");
			lines.push(truncateToWidth(this.theme.fg("dim", "Esc return to main thread"), safeWidth, "…", true));
			return lines;
		}

		const index = `${this.selectedIndex + 1}/${passes.length}`;
		const state = `${statusIcon(pass.status)} ${pass.status}`;
		lines.push(truncateToWidth(
			`${this.theme.fg("accent", `[${index}] ${pass.label}`)} ${this.theme.fg("muted", `(${pass.tier})`)} ${this.theme.fg(statusColor(pass.status), state)}`,
			safeWidth,
			"…",
			true,
		));
		const attempt = pass.attempt > 0 ? `attempt ${pass.attempt}` : "waiting to start";
		const model = pass.model ? ` · ${pass.model}` : "";
		lines.push(truncateToWidth(this.theme.fg("dim", `${attempt}${model}`), safeWidth, "…", true));
		lines.push(this.theme.fg("dim", "─".repeat(Math.max(1, safeWidth))));

		const body: string[] = [];
		if (pass.tools.length > 0) {
			body.push(this.theme.fg("muted", "Tool activity"));
			for (const tool of pass.tools) {
				const icon = tool.status === "running" ? "…" : tool.status === "completed" ? "✓" : "✗";
				const color = tool.status === "running" ? "warning" : tool.status === "completed" ? "success" : "error";
				body.push(`  ${this.theme.fg(color, icon)} ${this.theme.fg("toolOutput", tool.name)}`);
			}
			body.push("");
		}
		body.push(this.theme.fg("muted", "Assistant output"));
		if (pass.evictedBytes > 0) {
			body.push(this.theme.fg("warning", `… ${pass.evictedBytes} earlier UTF-8 bytes evicted by viewer limits …`));
		}
		const output = pass.assistantText || (pass.status === "queued" ? "(queued)" : "(waiting for assistant output…)");
		for (const outputLine of wrapTextWithAnsi(output, Math.max(1, safeWidth - 2))) {
			body.push(`  ${this.theme.fg("toolOutput", outputLine)}`);
		}
		if (this.snapshot.droppedPasses > 0) {
			body.push("");
			body.push(this.theme.fg("warning", `${this.snapshot.droppedPasses} older pass record(s) evicted`));
		}

		const footerRows = 2;
		const viewportRows = Math.max(1, height - lines.length - footerRows);
		const maxScroll = Math.max(0, body.length - viewportRows);
		if (this.followTail) this.scrollTop = maxScroll;
		else this.scrollTop = Math.min(this.scrollTop, maxScroll);
		const visible = body.slice(this.scrollTop, this.scrollTop + viewportRows);
		for (const line of visible) lines.push(truncateToWidth(line, safeWidth, "…", true));
		while (lines.length < height - footerRows) lines.push("");
		const scroll = maxScroll > 0 ? ` · lines ${this.scrollTop + 1}-${Math.min(body.length, this.scrollTop + viewportRows)}/${body.length}` : "";
		lines.push(truncateToWidth(this.theme.fg("dim", `Tab/←/→ pass · ↑/↓/PgUp/PgDn scroll${scroll}`), safeWidth, "…", true));
		lines.push(truncateToWidth(this.theme.fg("dim", "Esc return to main thread · viewer is read-only"), safeWidth, "…", true));
		return lines;
	}

	invalidate(): void {
		this.tui.requestRender();
	}

	dispose(): void {
		this.unsubscribe?.();
		this.unsubscribe = undefined;
		if (this.renderTimer !== undefined) {
			clearTimeout(this.renderTimer);
			this.renderTimer = undefined;
		}
	}

	private scheduleRender(): void {
		if (this.closed || this.renderTimer !== undefined) return;
		this.renderTimer = setTimeout(() => {
			this.renderTimer = undefined;
			if (!this.closed) this.tui.requestRender();
		}, 16);
	}

	private pageSize(): number {
		return Math.max(1, (this.tui.terminal.rows ?? 24) - 10);
	}

	private selectRelative(delta: number): void {
		const count = this.snapshot.passes.length;
		if (count === 0) return;
		this.selectedIndex = (this.selectedIndex + delta + count) % count;
		this.scrollTop = 0;
		this.followTail = true;
		this.tui.requestRender();
	}

	private close(): void {
		if (this.closed) return;
		this.closed = true;
		this.dispose();
		this.done();
	}
}

export default function registerReviewFocus(
	pi: ExtensionAPI,
	loopCoordinator: ReviewLoopCoordinator,
): void {
	const open = async (ctx: ExtensionContext): Promise<void> => {
		const mode = (ctx as ExtensionContext & { mode?: string }).mode;
		if (!ctx.hasUI || (mode !== undefined && mode !== "tui") || typeof ctx.ui.custom !== "function") {
			ctx.ui.notify("/pr-review-focus is available only in the interactive TUI", "warning");
			return;
		}
		const initial = loopCoordinator.focusSnapshot(ctx);
		if (!initial) {
			ctx.ui.notify("No active user-initiated /pr-review loop to focus", "warning");
			return;
		}

		await ctx.ui.custom<void>((tui, theme, _keybindings, done) => {
			const view = new ReviewFocusView(tui, theme, initial, done);
			const unsubscribe = loopCoordinator.subscribeFocus(ctx, (snapshot) => view.update(snapshot));
			view.setUnsubscribe(unsubscribe);
			if (!unsubscribe) queueMicrotask(() => view.update(undefined));
			return view;
		});
	};

	pi.registerCommand("pr-review-focus", {
		description: "Focus the live read-only output of running /pr-review subagents",
		handler: async (args, ctx) => {
			if ((args ?? "").trim()) {
				ctx.ui.notify("Usage: /pr-review-focus", "warning");
				return;
			}
			await open(ctx);
		},
	});

	pi.registerShortcut(SHORTCUT, {
		description: "Focus running PR review subagents",
		handler: open,
	});
}
