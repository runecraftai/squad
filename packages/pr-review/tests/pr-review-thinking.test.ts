import { describe, expect, test } from "bun:test";
import {
	appendTierThinkingArgs,
	modelSpecThinkingLevel,
	normalizeThinkingLevel,
	normalizeTierThinkingLevels,
	resolveThinkingLevel,
	sharedThinkingInheritanceWarning,
	THINKING_LEVELS,
	thinkingShadowingWarning,
} from "../lib/pr-review-thinking.ts";

describe("tier thinking validation", () => {
	test("accepts every Pi-supported thinking level", () => {
		for (const level of THINKING_LEVELS) expect(normalizeThinkingLevel(level)).toBe(level);
		expect(normalizeTierThinkingLevels({ light: "off", medium: "minimal", heavy: "max" })).toEqual({
			light: "off",
			medium: "minimal",
			heavy: "max",
		});
	});

	test("strictly rejects unsupported levels and unknown tiers", () => {
		expect(() => normalizeTierThinkingLevels({ light: "auto" }, "User config")).toThrow(
			"User config.thinkingLevels.light must be one of off|minimal|low|medium|high|xhigh|max",
		);
		expect(() => normalizeTierThinkingLevels({ overview: "low" }, "User config")).toThrow(
			'User config.thinkingLevels has unknown tier "overview"',
		);
		expect(() => normalizeTierThinkingLevels("high", "User config")).toThrow(
			"User config.thinkingLevels must be an object",
		);
	});
});

describe("tier thinking precedence and argv", () => {
	test("an explicit model-spec thinking suffix wins and suppresses --thinking", () => {
		expect(modelSpecThinkingLevel("provider/model:xhigh")).toBe("xhigh");
		expect(resolveThinkingLevel("provider/model:xhigh", "low")).toEqual({
			level: "xhigh",
			source: "model",
			shadowedTierLevel: "low",
		});
		expect(appendTierThinkingArgs(["--model", "provider/model:xhigh"], "provider/model:xhigh", "low")).toEqual([
			"--model",
			"provider/model:xhigh",
		]);
	});

	test("tier thinking is passed when the model spec has no supported suffix", () => {
		expect(resolveThinkingLevel("provider/model", "medium")).toEqual({ level: "medium", source: "tier" });
		expect(appendTierThinkingArgs(["--model", "provider/model"], "provider/model", "medium")).toEqual([
			"--model",
			"provider/model",
			"--thinking",
			"medium",
		]);
	});

	test("unset tier thinking inherits without emitting a flag", () => {
		expect(resolveThinkingLevel(undefined, undefined)).toEqual({ source: "inherited" });
		expect(appendTierThinkingArgs([], undefined, undefined)).toEqual([]);
	});
});

describe("tier thinking warnings", () => {
	test("emits one actionable shared-inheritance warning without guessing xhigh", () => {
		const warning = sharedThinkingInheritanceWarning(["light", "medium", "heavy"]);
		expect(warning).toContain("light_thinking=<level> medium_thinking=<level> heavy_thinking=<level>");
		expect(warning?.match(/WARNING:/g)).toHaveLength(1);
		expect(warning).not.toContain("xhigh");
		expect(sharedThinkingInheritanceWarning([])).toBeUndefined();
	});

	test("warns that model-spec thinking shadows tier thinking", () => {
		const warning = thinkingShadowingWarning([
			{ tier: "heavy", modelSpec: "provider/model:xhigh", tierLevel: "high", modelLevel: "xhigh" },
		]);
		expect(warning).toBe(
			"WARNING: Model-spec :thinking takes precedence over tier thinking: heavy model provider/model:xhigh selects xhigh instead of heavy_thinking=high.",
		);
	});
});
