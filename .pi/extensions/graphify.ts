// Graphify-for-pi v1 pilot extension (scratch measurement, per
// data/squad-graphify-opencode-recon/report.md §4).
//
// Thin wrapper around the `graphify` CLI: four lazily-registered tools plus a
// session-start staleness check. No extraction is reimplemented here; every tool
// shells out to the pinned binary resolved from GRAPHIFY_BIN or PATH.
//
// Scope deliberately excluded for v1 (report §4): no bash-command prefixing,
// no AGENTS.md mutation, no background watcher.
//
// Config (env only): GRAPHIFY_BIN (binary path, default "graphify"),
// GRAPHIFY_BUDGET (default query token cap, default 2000),
// GRAPHIFY_STALE_COMMITS (drift threshold before notifying, default 1).
import { execFileSync } from "node:child_process";
import { statSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const CLI_TIMEOUT_MS = 60_000;

export default function graphifyExtension(pi: ExtensionAPI) {
	const bin = process.env.GRAPHIFY_BIN || "graphify";
	const defaultBudget = Number.parseInt(process.env.GRAPHIFY_BUDGET ?? "", 10) || 2000;
	const staleCommitThreshold = Number.parseInt(process.env.GRAPHIFY_STALE_COMMITS ?? "", 10);
	const staleCommitsAllowed = Number.isFinite(staleCommitThreshold) ? staleCommitThreshold : 1;

	let registered = false;

	function run(args: string[], cwd: string): string {
		return execFileSync(bin, args, { cwd, encoding: "utf8", timeout: CLI_TIMEOUT_MS });
	}

	function registerGraphTools(): void {
		if (registered) return;
		registered = true;

		pi.registerTool({
			name: "graphify_query",
			label: "Graphify Query",
			description:
				"Query this codebase's knowledge graph (BFS subgraph around concepts matching the question). Cheaper and more focused than grepping raw files for structural questions.",
			promptSnippet: "Query the codebase knowledge graph for a question",
			promptGuidelines: [
				"Use graphify_query when answering questions about this codebase's structure or how components relate, before falling back to grep/read.",
			],
			parameters: Type.Object({
				question: Type.String({ description: "Natural-language question about the codebase graph" }),
				budget: Type.Optional(
					Type.Number({ description: `Token cap for the returned subgraph (default ${defaultBudget})` }),
				),
				context_filter: Type.Optional(
					Type.Array(Type.String(), {
						description: "Explicit edge-context filters to restrict traversal",
					}),
				),
			}),
			async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
				const args = ["query", params.question, "--budget", String(params.budget ?? defaultBudget)];
				for (const filter of params.context_filter ?? []) args.push("--context", filter);
				const output = run(args, ctx.cwd);
				return { content: [{ type: "text", text: output }] };
			},
		});

		pi.registerTool({
			name: "graphify_path",
			label: "Graphify Path",
			description: 'Shortest path between two nodes in the codebase knowledge graph, e.g. graphify_path "sq-send.sh" "window-state".',
			promptSnippet: "Find the shortest relationship path between two graph nodes",
			promptGuidelines: [
				"Use graphify_path to trace how one function, file, or concept reaches another in this codebase.",
			],
			parameters: Type.Object({
				from: Type.String({ description: "Source node name (fuzzy match)" }),
				to: Type.String({ description: "Target node name (fuzzy match)" }),
				undirected: Type.Optional(
					Type.Boolean({ description: "Treat edges as undirected (recommended; directed misses are common)" }),
				),
			}),
			async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
				const args = ["path", params.from, params.to];
				if (params.undirected) args.push("--undirected");
				const output = run(args, ctx.cwd);
				return { content: [{ type: "text", text: output }] };
			},
		});

		pi.registerTool({
			name: "graphify_explain",
			label: "Graphify Explain",
			description: "Plain-language explanation of one node and its neighbors in the codebase knowledge graph.",
			promptSnippet: "Explain one node and its neighbors from the codebase graph",
			promptGuidelines: [
				"Use graphify_explain to get what a single file, function, or concept connects to in this codebase.",
			],
			parameters: Type.Object({
				node: Type.String({ description: "Node name to explain (fuzzy match)" }),
			}),
			async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
				const output = run(["explain", params.node], ctx.cwd);
				return { content: [{ type: "text", text: output }] };
			},
		});

		pi.registerTool({
			name: "graphify_update",
			label: "Graphify Update",
			description:
				"Incrementally re-extract changed code files into graphify-out/graph.json. AST-only, no LLM/API cost. Run after modifying code so graph answers stay accurate.",
			promptSnippet: "Refresh the codebase knowledge graph after code edits",
			promptGuidelines: [
				"After modifying code with edit/write, run graphify_update once so subsequent graphify_query/path/explain results reflect your changes.",
			],
			parameters: Type.Object({}),
			async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
				const output = run(["update", "."], ctx.cwd);
				return { content: [{ type: "text", text: output }] };
			},
		});
	}

	pi.on("session_start", (_event, ctx) => {
		const graphPath = join(ctx.cwd, "graphify-out", "graph.json");
		let graphMtimeMs: number;
		try {
			graphMtimeMs = statSync(graphPath).mtimeMs;
		} catch {
			// No graph: zero-footprint no-op. Tools stay unregistered so the system prompt stays clean.
			return;
		}

		registerGraphTools();

		// Staleness check: count commits newer than the graph build. Never auto-run update here.
		try {
			const since = new Date(graphMtimeMs).toISOString();
			const count = Number.parseInt(
				execFileSync("git", ["rev-list", "--count", "HEAD", `--since=${since}`], {
					cwd: ctx.cwd,
					encoding: "utf8",
					timeout: CLI_TIMEOUT_MS,
				}).trim(),
				10,
			);
			if (Number.isFinite(count) && count > staleCommitsAllowed) {
				ctx.ui.notify(`[graphify] graph is ${count} commits stale — run graphify_update`, "info");
			}
		} catch {
			// Outside a git repo or git unavailable: skip the drift check silently.
		}
	});
}
