import * as fs from "node:fs/promises";
import * as path from "node:path";

export const MAX_REVIEW_CONTEXT_FILE_BYTES = 16 * 1024 * 1024;

/** Split whole changed-file blocks into deterministic, changed-line-balanced shards. */
export function shardUnifiedDiff(diff: string, requested: number): string[] {
	const starts = [...diff.matchAll(/^diff --git /gm)].map((match) => match.index!);
	if (requested <= 1 || starts.length <= 1) return [diff.trim()];
	const blocks = starts.map((start, index) => {
		const text = diff.slice(start, starts[index + 1] ?? diff.length).trim();
		const weight = Math.max(
			1,
			text.split("\n").filter((line) =>
				(line.startsWith("+") && !line.startsWith("+++")) ||
				(line.startsWith("-") && !line.startsWith("---")),
			).length,
		);
		return { index, text, weight };
	});
	const count = Math.min(Math.max(1, Math.floor(requested)), blocks.length);
	const shards = Array.from({ length: count }, () => ({ weight: 0, blocks: [] as typeof blocks }));
	for (const block of [...blocks].sort((a, b) => b.weight - a.weight || a.index - b.index)) {
		const target = shards.reduce((best, shard) => (shard.weight < best.weight ? shard : best), shards[0]!);
		target.blocks.push(block);
		target.weight += block.weight;
	}
	return shards.map((shard) =>
		shard.blocks.sort((a, b) => a.index - b.index).map((block) => block.text).join("\n"),
	);
}

export interface LoadedReviewContext {
	context?: string;
	contextFile?: string;
	/** Internal raw text used for deterministic sharding; never exposed in tool details. */
	contextFileText?: string;
	contextFileBytes: number;
}

/** Load a complete diff from disk without echoing it through the orchestrator's tool arguments. */
export async function loadReviewContext(
	cwd: string,
	inlineContext: string | undefined,
	contextFile: string | undefined,
	maxBytes = MAX_REVIEW_CONTEXT_FILE_BYTES,
): Promise<LoadedReviewContext> {
	const inline = inlineContext?.trim();
	if (!contextFile?.trim()) {
		return { context: inline || undefined, contextFileBytes: 0 };
	}

	const resolved = path.resolve(cwd, contextFile.trim());
	const stat = await fs.stat(resolved);
	if (!stat.isFile()) throw new Error(`review context_file is not a regular file: ${contextFile}`);
	if (stat.size <= 0) throw new Error(`review context_file is empty: ${contextFile}`);
	if (stat.size > maxBytes) {
		throw new Error(`review context_file exceeds ${maxBytes} bytes: ${contextFile}`);
	}
	const fileContext = (await fs.readFile(resolved, "utf8")).trim();
	if (!fileContext) throw new Error(`review context_file contains no text: ${contextFile}`);
	const context = inline
		? `${inline}\n\n--- Complete PR diff from context_file ---\n${fileContext}`
		: fileContext;
	return {
		context,
		contextFile: resolved,
		contextFileText: fileContext,
		contextFileBytes: stat.size,
	};
}
