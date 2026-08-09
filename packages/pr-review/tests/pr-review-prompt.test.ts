import { readFileSync } from "node:fs";
import { describe, expect, test } from "bun:test";

const prompt = readFileSync(new URL("../prompts/pr-review.md", import.meta.url), "utf8");
const extension = readFileSync(new URL("../extensions/pr-review-subagent.ts", import.meta.url), "utf8");
const focusExtension = readFileSync(new URL("../extensions/pr-review-focus.ts", import.meta.url), "utf8");
const entrypoint = readFileSync(new URL("../extensions/index.ts", import.meta.url), "utf8");
const readme = readFileSync(new URL("../README.md", import.meta.url), "utf8");
const packageJson = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));

describe("PR review prompt scheduling policy", () => {
	test("registers review tools and publication behind one shared loop coordinator", () => {
		expect(packageJson.pi.extensions).toEqual(["./extensions/index.ts"]);
		expect(packageJson.peerDependencies["@earendil-works/pi-coding-agent"]).toBe(">=0.80.5");
		expect(entrypoint).toContain("const loopCoordinator = new ReviewLoopCoordinator(pi)");
		expect(entrypoint).toContain("const selfReviewCoordinator = new SelfReviewPermitCoordinator");
		expect(entrypoint).toContain("registerPrReviewSubagents(pi, loopCoordinator, selfReviewCoordinator)");
		expect(entrypoint).toContain("registerReviewFocus(pi, loopCoordinator)");
		expect(entrypoint).toContain("registerReviewTable(pi, loopCoordinator, selfReviewCoordinator)");
		expect(focusExtension).toContain('pi.registerCommand("pr-review-focus"');
		expect(focusExtension).toContain('pi.registerShortcut(SHORTCUT');
		expect(focusExtension).not.toContain('"(waiting for assistant output…) "');
		expect(entrypoint).not.toContain("CachedPublishAuthorizationGate");
		expect(extension).toContain("allow_stale_publish");
		expect(extension).toContain("allowStalePublish: allowStale.valid ? allowStale.value : false");
	});

	test("documents the read-only live focus viewer", () => {
		expect(readme).toContain("/pr-review-focus");
		expect(readme).toContain("Ctrl+Alt+R");
		expect(readme).toContain("Return to the main thread without cancelling the review");
		expect(readme).toContain("never stores the pass objective, input context, captured diff");
		expect(readme).toContain("cannot send prompts, steering, or follow-ups");
	});

	test("uses balanced five-pass coverage by default", () => {
		expect(prompt).toContain("The default is balanced");
		expect(prompt).toContain("By default, and when `--balanced` is present");
		expect(prompt).toContain("`major_only: true`, `minor_hygiene: true`");
		expect(prompt).toContain("exactly these five passes: `overview`, `correctness`, `correctness-contracts`, `security-performance`, and `performance-resources`");
		expect(prompt).toContain("For an ordinary diff use `max_parallel: 5`");
		expect(prompt).toContain("Do **not** dispatch `conventions-maintainability`");
	});

	test("preserves the comprehensive six-pass review behind full mode", () => {
		expect(prompt).toContain("| `overview` | `light` | `none` |");
		expect(prompt).toContain("| `conventions-maintainability` | `medium` | `configured` |");
		expect(prompt).toContain("| `correctness` | `heavy` | `configured` |");
		expect(prompt).toContain("| `correctness-contracts` | `heavy` | `configured` |");
		expect(prompt).toContain("| `security-performance` | `heavy` | `configured` |");
		expect(prompt).toContain("| `performance-resources` | `heavy` | `configured` |");
		expect(prompt).toContain("When `$@` includes `--full`");
		expect(prompt).toContain("use all six passes");
		expect(prompt).toContain("For an ordinary diff use `max_parallel: 6`");
		expect(prompt).toContain("mode-0600 temporary file is the exact base↔head `context_file`");
		expect(prompt).toContain('gh pr diff $1 > "$diff_file" || { status=$?; rm -f -- "$diff_file"');
		expect(prompt).toContain("remove it before every early return, skipped JSON, confirmation pause");
		expect(prompt).toContain("first remove the captured temporary diff");
		expect(prompt).toContain("Remove the captured temporary diff before stopping");
		expect(prompt).toContain("Do not dump or embed the complete diff into the parent conversation");
		expect(prompt).toContain("independently read candidate-specific hunks/surrounding code");
		expect(extension.match(/context_file: Type.Optional/g)).toHaveLength(3);
		expect(extension).toContain("loadReviewContext(ctx.cwd, params.context, params.context_file)");
		expect(extension).toContain('stdio: ["pipe", "pipe", "pipe"]');
		expect(extension).toContain('proc.stdin.end(input, "utf8")');
		expect(extension).not.toContain("args.push(buildPassTask(pass.objective, pass.context))");
		expect(prompt).toContain("Inspect the complete diff so cross-file flows remain visible");
		expect(prompt).toContain("Inspect the complete diff so cross-file contracts remain visible");
	});

	test("supports an opt-in major-only mode without dropping heavy-lens coverage", () => {
		expect(prompt).toContain('argument-hint: "<PR-NUM> [--comment|--no-comment] [--full|--major-only|--balanced]"');
		expect(prompt).toContain("When `$@` includes `--major-only`");
		expect(prompt).toContain("exactly these five passes: `overview`, `correctness`, `correctness-contracts`, `security-performance`, and `performance-resources`");
		expect(prompt).toContain("Do **not** dispatch `conventions-maintainability`");
		expect(prompt).toContain("For an ordinary diff use `max_parallel: 5`");
		expect(prompt).toContain("discard P3/nit candidates before parent validation and finalization");
		expect(prompt).toContain("never relabel a minor issue as P2");
		expect(extension).toContain("major_only: Type.Optional");
		expect(extension).toContain("buildSubagentSystemPrompt(");
		expect(extension).toContain("pass.majorOnly === true");
		expect(extension).not.toContain('pass.majorOnly && pass.tier === "heavy"');
		expect(extension).toContain("report only substantiated P0, P1, or P2 defects");
	});

	test("offers bounded minor coverage by default and through the balanced alias", () => {
		expect(prompt).toContain("`--balanced` is a backward-compatible explicit alias for this default");
		expect(prompt).toContain("at most three direct-diff P3/nit candidates");
		expect(prompt).toContain("both `major_only: true` and `minor_hygiene: true`");
		expect(prompt).toContain("validate every retained candidate independently");
		expect(extension).toContain("minor_hygiene: Type.Optional");
		expect(extension).toContain("This is a bounded minor-hygiene scan");
		expect(extension).toContain("minorHygiene && tier === \"light\" && baseId === \"overview\"");
	});

	test("shards every lens for large multi-file diffs", () => {
		expect(prompt).toContain("200,000–399,999 byte multi-file diffs");
		expect(prompt).toContain("`shard_count: 2` and `max_parallel: 10`");
		expect(prompt).toContain("diffs at least 400,000 bytes with at least three changed files");
		expect(prompt).toContain("`shard_count: 3` and `max_parallel: 15`");
		expect(prompt).toContain("two- and three-shard policies use `max_parallel: 12` and `max_parallel: 18`");
		expect(prompt).toContain("runs every selected lens once per shard");
		expect(prompt).toContain("Configured specialists may read the full `context_file` path");
		expect(prompt).toContain("Never shard a single-file diff");
		expect(extension).toContain("const MAX_BATCH_PARALLEL = 18");
		expect(extension).toContain("maximum: 3");
		expect(extension).toContain("shardUnifiedDiff(loadedContext.contextFileText!, requestedShardCount)");
		expect(extension).toContain("shard_count>1 requires a top-level context_file");
		expect(extension).toContain("const tierPriority: Record<Tier, number> = { heavy: 0, medium: 1, light: 2 }");
		expect(extension).toContain("dispatchResults.sort((a, b) => a.originalIndex - b.originalIndex)");
		expect(extension).toContain("firstAssistantMs");
		expect(extension).toContain("toolElapsedMs");
	});

	test("balances correctness work without dropping error or resource coverage", () => {
		expect(prompt).toContain("API/data/error-contract violations");
		expect(prompt).toContain("error propagation/handling defects");
		expect(prompt).toContain("resource ownership/cleanup leaks");
		expect(prompt).toContain("Treat definite resource leaks as correctness findings");
	});

	test("discovers user-level names concurrently with independent initial context", () => {
		const decision = prompt.indexOf("Use the result of the single `pr_review_verify` call emitted concurrently");
		const dispatch = prompt.indexOf("If Step 2 selected a discovered baseline name");
		expect(decision).toBeGreaterThan(-1);
		expect(dispatch).toBeGreaterThan(decision);
		expect(prompt).toContain('`pr_review_verify` `{ "action": "list" }` discovery calls together');
		expect(prompt).toContain("Applicability discovery depends only on the current repository");
		expect(prompt).toContain("repository-wide convention-path listing (paths only)");
		expect(prompt).toContain("project-local definitions are ignored");
		expect(prompt).toContain("missing config disables verification");
		expect(prompt).toContain("Select **at most one** applicable name");
	});

	test("dispatches named verification with the review batch and no model overrides", () => {
		expect(prompt).toContain('one `pr_review_verify` `action: "run"` call in the **same assistant turn**');
		expect(prompt).toContain("`baseline_name`: the exact applicable name returned by `action: \"list\"`");
		expect(prompt).toContain("Never send legacy `command` or `timeout_ms` fields");
		expect(prompt).toContain("never replace an unavailable `pr_review_verify` with a prompt-owned `bash` worktree lifecycle");
	});

	test("exposes strict list/run schemas and rejects legacy run overrides", () => {
		const start = extension.indexOf("const PrReviewVerifyParams");
		const end = extension.indexOf("const ReviewSubagentParams");
		const schema = extension.slice(start, end);
		expect(schema).toContain('Type.Literal("list"');
		expect(schema).toContain('Type.Literal("run")');
		expect(schema).toContain("baseline_name: Type.String");
		expect(schema.match(/additionalProperties: false/g)).toHaveLength(2);
		expect(schema).not.toContain("command: Type.String");
		expect(schema).not.toContain("timeout_ms:");
	});

	test("documents strict applicability, containment, output, cleanup, and unsandboxed risk", () => {
		expect(prompt).toContain("matching repository host/owner/repo");
		expect(prompt).toContain("canonical absolute executable and fixed argv");
		expect(prompt).toContain("fails closed on Windows");
		expect(prompt).toContain("`--no-write-fetch-head`");
		expect(prompt).toContain("minimal secret-scrubbed environment and temporary HOME/cache");
		expect(prompt).toContain("canonical `git` and `gh` executables from the trusted extension-startup PATH");
		expect(prompt).toContain("rejects a fork unless the trusted profile has `allowForks: true`");
		expect(prompt).toContain("freshly initialized extension-owned bare staging repository");
		expect(prompt).toContain("without system/global/local Git config or installed hooks");
		expect(prompt).toContain("temporary askpass helper/environment");
		expect(prompt).toContain("imports that already-fetched ref into the original repository over a local path");
		expect(prompt).toContain("`FETCH_HEAD` is preserved");
		expect(prompt).toContain("all captured fetch stdout and stderr is zeroed and suppressed");
		expect(prompt).toContain("every observed byte is accounted as dropped");
		expect(prompt).toContain("generic trusted context rather than raw fetch diagnostics");
		expect(prompt).toContain("unauthenticated public fetch remains permitted with bounded diagnostics");
		expect(prompt).toContain("fixed 2-second emergency cleanup allowance");
		expect(prompt).toContain("unconditionally available to bounded cleanup");
		expect(prompt).toContain("Verification is disabled by default");
		expect(prompt).toContain("acknowledgeUnsandboxedPrCodeRisk=true");
		expect(prompt).toContain("without a filesystem or network sandbox");
		expect(prompt).toContain("only the original POSIX process group");
		expect(prompt).toContain("deliberately call `setsid`");
		expect(prompt).toContain("external sandbox or container wrapper for untrusted pull requests");
		expect(prompt).toContain("unconditional KILL after grace");
		expect(prompt).toContain("shared raw-output accounting");
		expect(prompt).toContain("`primaryOutcome`, `terminationOutcome`, and `cleanupOutcome`");
	});

	test("does not delay review and batches independent candidate validation", () => {
		expect(prompt).toContain("If no profile is configured/applicable");
		expect(prompt).toContain("let the default/major-only five-pass batch (or 10/15 sharded passes) proceed immediately");
		expect(prompt).toContain("the `--full` six-pass batch (or 12/18 sharded passes)");
		expect(prompt).toContain("Only after the batch results (and any concurrently scheduled baseline result) are available");
		expect(prompt).toContain("make an internal confirm/reject/evidence-needed decision");
		expect(prompt).toContain("navigational evidence index");
		expect(prompt).toContain("never as a trusted conclusion");
		expect(prompt).toContain("do **not** launch a tool call merely to rediscover");
		expect(prompt).toContain("one parallel tool-call turn");
		expect(prompt).toContain("Use at most one additional validation turn");
		expect(prompt).toContain("not permission to skip evidence");
		expect(prompt).toContain("independent source-grounded confirmation");
		expect(prompt).toContain("resolve every candidate as confirmed or rejected");
		expect(prompt).toContain("baseline verification never replaces this post-batch validation");
	});

	test("batches specialist evidence gathering without weakening substantiation", () => {
		expect(extension).toContain("Use repository tools only to substantiate a concrete candidate caused by that diff");
		expect(extension).toContain("Issue independent reads/searches/checks together");
		expect(extension).toContain("Use at most one follow-up tool turn");
		expect(extension).toContain("never permits skipping evidence needed to substantiate a finding");
	});
});
