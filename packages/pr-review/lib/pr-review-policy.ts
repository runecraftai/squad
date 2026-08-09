export type ToolPolicy = "none" | "configured";

const RECURSIVE_REVIEW_TOOLS = new Set([
	"review_subagent",
	"review_subagents",
	"pr_review_verify",
	"self_review_subagent",
]);

/** Isolated review subprocesses receive all review context explicitly. */
export function buildReviewBaseArgs(): string[] {
	return [
		"--mode",
		"json",
		"-p",
		"--no-session",
		"--no-context-files",
		"--no-extensions",
		"--no-skills",
		"--no-prompt-templates",
		"--no-themes",
	];
}

export function normalizeToolPolicy(value: unknown): ToolPolicy | undefined {
	return value === "none" || value === "configured" ? value : undefined;
}

/** Request override wins, then explicit tier config, then legacy configured behavior. */
export function resolveToolPolicy(
	requested: ToolPolicy | undefined,
	configured: ToolPolicy | undefined,
): ToolPolicy {
	return requested ?? configured ?? "configured";
}

/** Reviewer children never receive recursive review tools or implicit defaults. */
export function appendToolPolicyArgs(
	args: string[],
	policy: ToolPolicy,
	configuredTools: string[],
): string[] {
	const tools = configuredTools.filter((name) => !RECURSIVE_REVIEW_TOOLS.has(name));
	if (policy === "none" || tools.length === 0) {
		args.push("--no-tools");
	} else {
		args.push("--tools", [...new Set(tools)].join(","));
	}
	return args;
}
