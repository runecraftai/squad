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

	test("oversized input still finds the true longest common subsequence via linear-space Hirschberg", () => {
		const size = 3000;
		const a = ["shared-start", ...Array.from({ length: size }, (_, i) => `a-${i}`), "shared-end"].join("\n");
		const b = ["shared-start", ...Array.from({ length: size }, (_, i) => `b-${i}`), "shared-end"].join("\n");
		const result = lineDiff(a, b);
		expect(result[0]).toEqual({ type: "unchanged", text: "shared-start" });
		expect(result[result.length - 1]).toEqual({ type: "unchanged", text: "shared-end" });
		expect(result.filter((line) => line.type === "unchanged")).toHaveLength(2);
		expect(result.filter((line) => line.type === "removed")).toHaveLength(size);
		expect(result.filter((line) => line.type === "added")).toHaveLength(size);
	});

	test("a single changed line inside a large oversized block stays isolated, not a full-file replacement", () => {
		const size = 3000;
		const linesA = Array.from({ length: size }, (_, i) => `line-${i}`);
		const linesB = [...linesA];
		linesB[1500] = "changed-line";
		const result = lineDiff(linesA.join("\n"), linesB.join("\n"));
		expect(result.filter((line) => line.type === "unchanged")).toHaveLength(size - 1);
		expect(result.filter((line) => line.type === "removed")).toEqual([{ type: "removed", text: "line-1500" }]);
		expect(result.filter((line) => line.type === "added")).toEqual([{ type: "added", text: "changed-line" }]);
	});
});
