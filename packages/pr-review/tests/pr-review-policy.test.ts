import { describe, expect, test } from "bun:test";
import {
	appendToolPolicyArgs,
	buildReviewBaseArgs,
	normalizeToolPolicy,
	resolveToolPolicy,
} from "../lib/pr-review-policy.ts";

describe("tool policy resolution", () => {
	test("request override wins over tier config", () => {
		expect(resolveToolPolicy("none", "configured")).toBe("none");
		expect(resolveToolPolicy("configured", "none")).toBe("configured");
	});

	test("tier config applies when request omits policy", () => {
		expect(resolveToolPolicy(undefined, "none")).toBe("none");
	});

	test("omission preserves legacy configured behavior", () => {
		expect(resolveToolPolicy(undefined, undefined)).toBe("configured");
	});

	test("normalization rejects unknown values", () => {
		expect(normalizeToolPolicy("none")).toBe("none");
		expect(normalizeToolPolicy("configured")).toBe("configured");
		expect(normalizeToolPolicy("auto")).toBeUndefined();
	});
});

describe("tool policy argv", () => {
	test("base args isolate explicit review context", () => {
		expect(buildReviewBaseArgs()).toEqual([
			"--mode",
			"json",
			"-p",
			"--no-session",
			"--no-context-files",
			"--no-extensions",
			"--no-skills",
			"--no-prompt-templates",
			"--no-themes",
		]);
	});

	test("none emits explicit --no-tools", () => {
		const args = ["--mode", "json"];
		expect(appendToolPolicyArgs(args, "none", ["read", "bash"])).toEqual([
			"--mode",
			"json",
			"--no-tools",
		]);
	});

	test("configured emits the configured allowlist", () => {
		const args = ["--mode", "json"];
		expect(appendToolPolicyArgs(args, "configured", ["read", "grep"])).toEqual([
			"--mode",
			"json",
			"--tools",
			"read,grep",
		]);
	});

	test("configured with an empty list fails closed with no tools", () => {
		const args = ["--mode", "json"];
		expect(appendToolPolicyArgs(args, "configured", [])).toEqual([
			"--mode",
			"json",
			"--no-tools",
		]);
	});

	test("configured strips recursive review tools and deduplicates the child allowlist", () => {
		const args: string[] = [];
		expect(
			appendToolPolicyArgs(args, "configured", [
				"read",
				"review_subagent",
				"review_subagents",
				"pr_review_verify",
				"self_review_subagent",
				"read",
				"grep",
			]),
		).toEqual(["--tools", "read,grep"]);
	});

	test("one resolved policy can be reused across fallback attempts", () => {
		const policy = resolveToolPolicy("none", "configured");
		const first = appendToolPolicyArgs([], policy, ["read"]);
		const fallback = appendToolPolicyArgs([], policy, ["read"]);
		expect(first).toEqual(["--no-tools"]);
		expect(fallback).toEqual(["--no-tools"]);
	});
});
