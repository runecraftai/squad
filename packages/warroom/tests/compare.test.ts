import { describe, expect, test } from "bun:test";
import { digestContent, Warroom } from "../src/core.ts";

function seeded() {
	const warroom = new Warroom();
	warroom.command({ type: "initiative.create", id: "i1", title: "Proof" });
	warroom.command({ type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "line a\nline b" });
	return warroom;
}

describe("revision compare", () => {
	test("two genuinely different revisions report distinct digests and a structural diff", () => {
		const w = seeded();
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "line a\nline c" });
		const comparison = w.compare("i1", "p1", "p2");
		expect(comparison.sameIdentity).toBe(false);
		expect(comparison.identicalContent).toBe(false);
		expect(comparison.revisionA.digest).toBe(digestContent("line a\nline b"));
		expect(comparison.revisionB.digest).toBe(digestContent("line a\nline c"));
		expect(comparison.diff).toEqual([
			{ type: "unchanged", text: "line a" },
			{ type: "removed", text: "line b" },
			{ type: "added", text: "line c" },
		]);
		w.close();
	});

	test("restored identical content compares as same digest but different identity, with no diff", () => {
		const w = seeded();
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "line a\nline b changed" });
		w.command({ type: "revision.create", id: "p3", initiativeId: "i1", kind: "plan", content: "line a\nline b" });
		const comparison = w.compare("i1", "p1", "p3");
		expect(comparison.sameIdentity).toBe(false);
		expect(comparison.identicalContent).toBe(true);
		expect(comparison.revisionA.digest).toBe(comparison.revisionB.digest);
		expect(comparison.diff).toEqual([]);
		w.close();
	});

	test("comparing a revision to itself is same identity and identical content", () => {
		const w = seeded();
		const comparison = w.compare("i1", "p1", "p1");
		expect(comparison.sameIdentity).toBe(true);
		expect(comparison.identicalContent).toBe(true);
		expect(comparison.diff).toEqual([]);
		w.close();
	});

	test("comparing revisions of different kinds is rejected", () => {
		const w = seeded();
		w.command({ type: "revision.create", id: "c1", initiativeId: "i1", kind: "code", content: "code" });
		expect(() => w.compare("i1", "p1", "c1")).toThrow("different kinds");
		w.close();
	});

	test("comparing a revision that does not exist is rejected", () => {
		const w = seeded();
		expect(() => w.compare("i1", "p1", "missing")).toThrow("does not exist");
		w.close();
	});
});
