import { afterEach, describe, expect, it } from "vitest";
import { cleanup, cli, initStore } from "./helpers.js";

afterEach(cleanup);

describe("numeric flag validation", () => {
	it("refuses a non-numeric --wait instead of probing forever", async () => {
		const store = await initStore();
		const startedAt = Date.now();
		const result = await cli(["ready", "--store", store, "--wait", "soon"]);
		expect(Date.now() - startedAt).toBeLessThan(20_000);
		expect(result.code).toBe(1);
		expect(result.stderr).toContain("usage: --wait");
	});

	it("refuses a non-numeric --timeout instead of resending forever", async () => {
		const store = await initStore();
		const startedAt = Date.now();
		const result = await cli(["answer", "--store", store, "--approval", "ap-1", "--revision", "r1", "--decision", "approve", "--timeout", "soon"]);
		expect(Date.now() - startedAt).toBeLessThan(20_000);
		expect(result.code).toBe(1);
		expect(result.stderr).toContain("usage: --timeout");
	});
});
