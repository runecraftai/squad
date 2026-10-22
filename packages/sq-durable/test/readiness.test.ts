import { existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { acceptsMutations, classify } from "../src/service/readiness.js";
import { admit, cleanup, cli, initStore, Service, startReady, tempDir, until } from "./helpers.js";

afterEach(cleanup);

describe("readiness classification", () => {
	it("is never ready before resume(), and ready only with a running engine and a fast line read", () => {
		expect(classify({ phase: "opened" }).state).toBe("starting");
		expect(classify({ phase: "opened", holds: ["resume"] }).reasons.join(" ")).toContain("hold");
		expect(classify({ phase: "resumed", scheduling: "paused", lineRead: true }).state).toBe("starting");
		expect(classify({ phase: "resumed", scheduling: "running", lineRead: true })).toEqual({ state: "ready", reasons: [] });
		expect(classify({ phase: "resumed", scheduling: "running", lineRead: false }).state).toBe("degraded");
		expect(classify({ phase: "resumed", scheduling: "running", lineRead: true, parked: ["t#1"] }).state).toBe("degraded");
		expect(classify({ phase: "resumed", scheduling: "running", lineRead: true, overdue: ["a"] }).state).toBe("degraded");
		expect(classify({ phase: "failed", failure: "boom" })).toEqual({ state: "failed", reasons: ["boom"] });
		expect(acceptsMutations("starting")).toBe(false);
		expect(acceptsMutations("degraded")).toBe(true);
	});
});

describe("service lifecycle", () => {
	it("keeps a live process without resume() out of ready and refuses writes, while reads work", async () => {
		const store = await initStore();
		const held = Service.start(store, { env: { SQ_DURABLE_LAB_HOLD: "resume" } });
		const probe = await until(
			async () => {
				const result = await cli(["ready", "--store", store, "--json"]);
				return result.json?.openedAt ? result : undefined;
			},
			5_000,
			"the held service to open",
		);
		expect(probe.code).toBe(3);
		expect(probe.json).toMatchObject({ state: "starting", resumedAt: null, pid: held.pid, holds: ["resume"] });
		const write = await admit(store);
		expect(write.code).toBe(3);
		expect(write.json.code).toBe("not_ready");
		const read = await cli(["approvals", "pending", "--store", store, "--json"]);
		expect(read.code).toBe(0);
		expect(read.json.pending).toEqual([]);
		expect(held.alive()).toBe(true);
	});

	it("allows one owner: a second service and an alias path are refused, and a SIGKILLed owner is replaced at once", async () => {
		const store = await initStore();
		const owner = await startReady(store);

		const second = Service.start(store);
		expect((await second.exited).code).toBe(2);
		expect(second.log).toContain("another service owns this store");

		const alias = join(tempDir(), "alias");
		symlinkSync(store, alias);
		const viaAlias = Service.start(alias);
		expect((await viaAlias.exited).code).toBe(2);
		expect(owner.alive()).toBe(true);

		expect(await owner.kill9()).toEqual({ code: null, signal: "SIGKILL" });
		const started = Date.now();
		await startReady(store);
		expect(Date.now() - started).toBeLessThan(5_000);
	});

	it("refuses laboratory fault injection on a store not marked laboratory", async () => {
		const store = await initStore(false);
		const service = Service.start(store, { env: { SQ_DURABLE_LAB_FAULT: "after-open" } });
		expect((await service.exited).code).toBe(2);
		expect(service.log).toContain("not marked laboratory");
		const held = Service.start(store, { env: { SQ_DURABLE_LAB_HOLD: "resume" } });
		expect((await held.exited).code).toBe(2);
	});

	it("never creates a new database for a missing one and never recreates a missing ownership file", async () => {
		const store = await initStore();
		rmSync(join(store, "pi.sqlite"), { force: true });
		rmSync(join(store, "pi.sqlite-wal"), { force: true });
		rmSync(join(store, "pi.sqlite-shm"), { force: true });
		const noDatabase = Service.start(store);
		expect((await noDatabase.exited).code).toBe(1);
		expect(noDatabase.log).toContain("never recreated");
		expect(existsSync(join(store, "pi.sqlite"))).toBe(false);

		const other = await initStore();
		rmSync(join(other, "owner.sqlite"));
		const noOwner = Service.start(other);
		expect((await noOwner.exited).code).toBe(2);
		expect(existsSync(join(other, "owner.sqlite"))).toBe(false);
	});

	it("stops the live owner when its ownership file is removed, and refuses new starts", async () => {
		const store = await initStore();
		const owner = await startReady(store);
		rmSync(join(store, "owner.sqlite"));
		const exit = await owner.exited;
		expect(exit.code).toBe(1);
		expect(owner.log).toContain("no longer names the locked inode");
		const next = Service.start(store);
		expect((await next.exited).code).toBe(2);
	});

	it("refuses a client speaking another protocol major version with an explicit message", async () => {
		const store = await initStore();
		await startReady(store);
		const result = await cli(["call", "--store", store, "--command", "ready", "--protocol", "2.0", "--json"]);
		expect(result.code).toBe(4);
		expect(result.json).toMatchObject({ ok: false, code: "protocol_mismatch" });
		expect(result.json.message).toContain("not supported");
		const minor = await cli(["call", "--store", store, "--command", "ready", "--protocol", "1.7", "--json"]);
		expect(minor.code).toBe(0);
	});

	it("refuses to initialize a directory that already holds anything", async () => {
		const dir = join(tempDir(), "busy");
		mkdirSync(dir);
		writeFileSync(join(dir, "something"), "x");
		const result = await cli(["init", "--store", dir, "--lab"]);
		expect(result.code).toBe(1);
		expect(result.stderr).toContain("not empty");
		const existing = await initStore();
		const twice = await cli(["init", "--store", existing]);
		expect(twice.code).toBe(1);
		expect(existsSync(dirname(existing))).toBe(true);
	});
});
