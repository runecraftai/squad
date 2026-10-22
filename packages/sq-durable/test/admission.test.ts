import { afterEach, describe, expect, it } from "vitest";
import { admit, cleanup, cli, initStore, Service, startReady, stats } from "./helpers.js";

afterEach(cleanup);

describe("idempotent admission", () => {
	it("returns the original mission for the same key and content, and refuses different content without writing", async () => {
		const store = await initStore();
		await startReady(store);

		const first = await admit(store);
		expect(first.code).toBe(0);
		expect(first.json.outcome).toBe("created");
		expect(first.json.missionId).toBe("dm1-test");

		const again = await admit(store);
		expect(again.code).toBe(0);
		expect(again.json).toEqual({ ...first.json, outcome: "existing" });

		const before = await stats(store);
		const conflict = await admit(store, "dm1-test", "r2");
		expect(conflict.code).toBe(2);
		expect(conflict.json.code).toBe("conflict");
		const otherArgs = await admit(store, "dm1-test", "r1", '{"k":"other"}');
		expect(otherArgs.code).toBe(2);
		expect(otherArgs.json.code).toBe("conflict");
		const after = await stats(store);
		expect(after).toEqual(before);
		expect(after.missions).toBe(1);
		expect(after.pending).toBe(1);
		expect(after.liveGates).toBe(1);
	});

	it("creates one mission, one approval and one gate for concurrent duplicate admissions", async () => {
		const store = await initStore();
		await startReady(store);

		const results = await Promise.all(Array.from({ length: 6 }, () => admit(store, "dm1-race")));
		expect(results.every((result) => result.code === 0)).toBe(true);
		expect(results.filter((result) => result.json.outcome === "created")).toHaveLength(1);
		const ids = new Set(results.map((result) => `${result.json.approvalId}#${result.json.gateTaskId}`));
		expect(ids.size).toBe(1);

		const counters = await stats(store);
		expect(counters).toMatchObject({ missions: 1, pending: 1, liveGates: 1, seq: 1 });
	});

	it("admits only dm1-<slug> IDs in the laboratory and writes nothing for the rest", async () => {
		const store = await initStore();
		await startReady(store);

		for (const id of ["dm-x", "dmz1-x", "dm2-x", "sq-legacy", "dm1-", "dm1-UPPER"]) {
			const result = await admit(store, id);
			expect(result.code, id).toBe(2);
			expect(result.json.code, id).toBe("invalid");
		}
		expect(await stats(store)).toMatchObject({ missions: 0, seq: 0, liveGates: 0 });
	});

	it("finds the original after a crash between the admission commit and the reply", async () => {
		const store = await initStore();
		const crashing = Service.start(store, { env: { SQ_DURABLE_LAB_FAULT: "after-admit-commit" } });
		await cli(["ready", "--store", store, "--wait", "10"]);

		const lost = await admit(store, "dm1-crash");
		expect(lost.code).toBe(3);
		expect(await crashing.exited).toEqual({ code: null, signal: "SIGKILL" });
		expect(crashing.log).toContain('"point":"after-admit-commit"');

		await startReady(store);
		const resent = await admit(store, "dm1-crash");
		expect(resent.code).toBe(0);
		expect(resent.json.outcome).toBe("existing");
		expect(await stats(store)).toMatchObject({ missions: 1, pending: 1, liveGates: 1, seq: 1 });
	});
});
