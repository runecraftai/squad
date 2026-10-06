import { describe, expect, test } from "bun:test";
import { lineDiff } from "../src/diff.ts";

describe("lineDiff", () => {
	test("identical content produces only unchanged lines", () => {
		const result = lineDiff("a\nb\nc", "a\nb\nc");
		expect(result.every((line) => line.type === "unchanged")).toBe(true);
		expect(result.map((line) => line.text)).toEqual(["a", "b", "c"]);
	});

	test("an inserted line is reported as added without disturbing surrounding context", () => {
		const result = lineDiff("a\nb\nc", "a\nx\nb\nc");
		expect(result).toEqual([
			{ type: "unchanged", text: "a" },
			{ type: "added", text: "x" },
			{ type: "unchanged", text: "b" },
			{ type: "unchanged", text: "c" },
		]);
	});

	test("a removed line is reported as removed", () => {
		const result = lineDiff("a\nb\nc", "a\nc");
		expect(result).toEqual([
			{ type: "unchanged", text: "a" },
			{ type: "removed", text: "b" },
			{ type: "unchanged", text: "c" },
		]);
	});

	test("wholly different content reports every line as removed then added", () => {
		const result = lineDiff("one\ntwo", "three\nfour");
		expect(result).toEqual([
			{ type: "removed", text: "one" },
			{ type: "removed", text: "two" },
			{ type: "added", text: "three" },
			{ type: "added", text: "four" },
		]);
	});

	test("empty content is treated as zero lines, not one blank line", () => {
		expect(lineDiff("", "a")).toEqual([{ type: "added", text: "a" }]);
		expect(lineDiff("a", "")).toEqual([{ type: "removed", text: "a" }]);
		expect(lineDiff("", "")).toEqual([]);
	});
});
