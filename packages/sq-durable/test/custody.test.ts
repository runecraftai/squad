import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
	CUSTODY_TABLE_DIGESTS,
	CUSTODY_TABLES,
	SQUAD_RESPONSIBILITIES,
	squadCustodyScheme,
} from "../src/adapter/legacy-writers.js";
import { decideCustody, engineOwnedMessage, tableDigest } from "../src/core/index.js";
import { custodyCheck, refusalLog, runScript, sandboxBase, scriptEnv, seedTask, stateDigest } from "./custody-helpers.js";
import { cleanup, cli, initStore, type Service, startReady } from "./helpers.js";

const scheme = squadCustodyScheme();
const stopped = { state: "stopped" } as const;

describe("custody contract (neutral core over the Squad tables)", () => {
	it("leaves every legacy ID alone, including near misses of the reserved prefix", () => {
		for (const id of ["task-1", "dm-x", "dmz-x", "xdm2-x", "dm2", "DM2-x"]) {
			expect(decideCustody({ id, responsibilities: ["landing"] }, scheme, stopped)).toMatchObject({ allowed: true, reserved: false });
		}
	});

	it("refuses an engine-owned responsibility with the explicit message, and allows a legacy one", () => {
		const refused = decideCustody({ id: "dm2-pilot", responsibilities: ["landing"] }, scheme, stopped);
		expect(refused).toMatchObject({ allowed: false, code: "engine_owned", generation: 2, responsibility: "landing" });
		expect(refused.allowed ? "" : refused.message).toBe("refused: landing of mission dm2-pilot belongs to the durable core (generation 2)");
		expect(engineOwnedMessage("landing", "dm2-pilot", 2)).toBe(refused.allowed ? "" : refused.message);
		expect(decideCustody({ id: "dm2-pilot", responsibilities: ["claim", "spawn", "wait"] }, scheme, stopped)).toMatchObject({ allowed: true, reserved: true });
	});

	it("refuses every responsibility, legacy ones included, of a generation the tables do not know", () => {
		for (const responsibility of Object.keys(SQUAD_RESPONSIBILITIES)) {
			expect(decideCustody({ id: "dm3-next", responsibilities: [responsibility] }, scheme, stopped)).toMatchObject({ allowed: false, code: "unknown_generation" });
		}
		expect(decideCustody({ id: "dm99999999999999999999-x", responsibilities: ["claim"] }, scheme, stopped)).toMatchObject({ allowed: false });
	});

	it("never confirms a condition without a ready service, and confirms it from the mission once ready", () => {
		const admission = { id: "dm2-pilot", responsibilities: ["admission"] };
		for (const state of ["stopped", "starting", "failed"] as const) {
			expect(decideCustody(admission, scheme, { state })).toMatchObject({ allowed: false, code: "condition_unmet" });
		}
		expect(decideCustody(admission, scheme, { state: "ready", mission: { status: "absent", effectReconciled: false } })).toMatchObject({ allowed: false });
		expect(decideCustody(admission, scheme, { state: "ready", mission: { status: "awaiting_approval", effectReconciled: true } })).toMatchObject({ allowed: true });

		const cleanupQuery = { id: "dm2-pilot", responsibilities: ["cleanup"] };
		expect(decideCustody(cleanupQuery, scheme, { state: "ready", mission: { status: "awaiting_approval", effectReconciled: true } })).toMatchObject({ allowed: false });
		expect(decideCustody(cleanupQuery, scheme, { state: "ready", mission: { status: "reconcile", effectReconciled: false } })).toMatchObject({ allowed: false });
		expect(decideCustody(cleanupQuery, scheme, { state: "degraded", mission: { status: "completed", effectReconciled: false } })).toMatchObject({ allowed: false });
		expect(decideCustody(cleanupQuery, scheme, { state: "degraded", mission: { status: "completed", effectReconciled: true } })).toMatchObject({ allowed: true });
	});

	it("keeps every published table frozen and equal to its pinned digest", () => {
		expect(CUSTODY_TABLES.map((table) => table.generation)).toEqual([1, 2]);
		for (const table of CUSTODY_TABLES) {
			expect(Object.isFrozen(table) && Object.isFrozen(table.owners)).toBe(true);
			expect(tableDigest(table)).toBe(CUSTODY_TABLE_DIGESTS[table.generation]);
			expect(Object.keys(table.owners).sort()).toEqual(Object.keys(SQUAD_RESPONSIBILITIES).sort());
		}
	});
});

/** Every legacy entry point to a responsibility that table 2 gives the engine, with arguments that reach its custody check. */
function engineOwnedWriters(base: string): { name: string; script: string; args: string[]; message: RegExp }[] {
	const owned = (responsibility: string) => new RegExp(`^refused: ${responsibility} of mission dm2-pilot belongs to the durable core \\(generation 2\\)$`, "m");
	const conditioned = (responsibility: string) => new RegExp(`^refused: ${responsibility} of mission dm2-pilot needs the durable core to confirm`, "m");
	return [
		{ name: "local landing", script: "sq-merge-local.sh", args: ["dm2-pilot"], message: owned("landing") },
		{ name: "PR landing", script: "sq-pr-merge.sh", args: ["dm2-pilot", "https://github.com/o/r/pull/1"], message: owned("landing") },
		{ name: "decision answer", script: "sq-send.sh", args: ["dm2-pilot", "--resolve-key", "land", "approved"], message: owned("approval") },
		{ name: "decision hold", script: "sq-decision-hold.sh", args: ["complete", "dm2-pilot", "--none"], message: owned("approval") },
		{ name: "XO handoff", script: "sq-backlog-handoff.sh", args: ["xo-a", "dm2-pilot"], message: owned("xo-routing") },
		{ name: "XO launch", script: "sq-spawn.sh", args: ["dm2-pilot", "--xo"], message: owned("xo-routing") },
		{ name: "XO seed", script: "sq-home-seed.sh", args: ["dm2-pilot", join(base, "xo-home"), "p"], message: owned("xo-routing") },
		{ name: "remote XO seed", script: "sq-remote-home-seed.sh", args: ["dm2-pilot", "xo-host", "/srv/squad", "/home/xo", "--no-projects"], message: owned("xo-routing") },
		{ name: "XO report", script: "sq-xo-report.sh", args: [join(base, "state", "dm2-pilot.status"), "done", "c1", "note"], message: owned("xo-routing") },
		{ name: "launch without admission", script: "sq-spawn.sh", args: ["dm2-pilot", base, "--mode", "local-only", "--yolo", "off"], message: conditioned("admission") },
		{ name: "brief without admission", script: "sq-brief.sh", args: ["dm2-pilot", base, "--mode", "local-only", "--no-playbook", "custody test"], message: conditioned("admission") },
		{ name: "promotion without admission", script: "sq-promote.sh", args: ["dm2-pilot", "--mode", "local-only", "--yolo", "off"], message: conditioned("admission") },
		{ name: "cleanup", script: "sq-teardown.sh", args: ["dm2-pilot"], message: conditioned("cleanup") },
		{ name: "forced cleanup", script: "sq-teardown.sh", args: ["dm2-pilot", "--force"], message: conditioned("cleanup") },
	];
}

type Mode = { name: string; meta: boolean; service: boolean };
const MODES: Mode[] = [
	{ name: "service stopped", meta: true, service: false },
	{ name: "service ready", meta: true, service: true },
	{ name: "projection and .meta deleted", meta: false, service: false },
];

describe.each(MODES)("legacy writers against dm2-* with $name", (mode) => {
	let base: string;
	let env: NodeJS.ProcessEnv;
	let service: Service | undefined;

	beforeAll(async () => {
		base = sandboxBase();
		if (mode.meta) seedTask(base, "dm2-pilot");
		if (mode.service) {
			const store = await initStore();
			service = await startReady(store);
			env = scriptEnv(base, { SQ_DURABLE_STORE: store });
		} else {
			env = scriptEnv(base);
		}
	});
	afterAll(cleanup);

	it("refuses every write on a responsibility table 2 gives the engine: exit 3, explicit message, refusal record, no state change", async () => {
		for (const writer of engineOwnedWriters(base)) {
			const before = stateDigest(base);
			const logged = refusalLog(base).length;
			const result = await runScript(writer.script, writer.args, env);
			expect({ writer: writer.name, code: result.code }).toEqual({ writer: writer.name, code: 3 });
			expect(result.stderr, writer.name).toMatch(writer.message);
			expect(stateDigest(base), writer.name).toBe(before);
			const record = refusalLog(base).slice(logged);
			expect(record, writer.name).toHaveLength(1);
			expect(record[0], writer.name).toContain("\tdm2-pilot\t");
			expect(record[0], writer.name).toContain(`\t${writer.script}\t`);
		}
		if (service !== undefined) expect(service.alive()).toBe(true);
	});

	it("keeps every responsibility table 2 leaves with the legacy path working for the same mission", async () => {
		for (const [command, expected] of [
			["claim", "claimed"],
			["running", "running"],
			["heartbeat", ""],
			["retry", "retry_queued"],
			["recover", "retry_queued"],
		] as const) {
			const result = await runScript("sq-exec-state.sh", [command, "dm2-pilot"], env);
			expect({ command, code: result.code, stderr: result.stderr }).toEqual({ command, code: 0, stderr: "" });
			expect(result.stdout.trim()).toBe(expected);
		}
		expect((await runScript("sq-exec-state.sh", ["get-recorded", "dm2-pilot"], env)).stdout.trim()).toBe("retry_queued");
		for (const responsibility of ["claim", "retry", "heartbeat", "recovery", "spawn", "wait", "status", "metadata"]) {
			expect((await custodyCheck("dm2-pilot", [responsibility], env)).code, responsibility).toBe(0);
		}
		expect(refusalLog(base).some((line) => /\t(claim|retry|heartbeat|recovery)\t/.test(line))).toBe(false);
	});
});

describe("legacy metadata writers against dm1-*: the laboratory table gives the engine every responsibility", () => {
	let base: string;
	let env: NodeJS.ProcessEnv;

	beforeAll(async () => {
		base = sandboxBase();
		seedTask(base, "dm1-lab");
		env = scriptEnv(base);
	});
	afterAll(cleanup);

	it("refuses each covered metadata entry point with exit 3, the explicit message, a refusal record and no state change", async () => {
		const owned = (responsibility: string) =>
			new RegExp(`^refused: ${responsibility} of mission dm1-lab belongs to the durable core \\(generation 1\\)$`, "m");
		const writers = [
			{ name: "check registration", script: "sq-check-register.sh", args: ["dm1-lab"], message: owned("metadata") },
			{ name: "MCP link", script: "sq-mcp-link.sh", args: ["dm1-lab", "req-1"], message: owned("metadata") },
			{ name: "PR check", script: "sq-pr-check.sh", args: ["dm1-lab", "https://github.com/o/r/pull/1"], message: owned("metadata") },
			{ name: "X link", script: "sq-x-link.sh", args: ["dm1-lab", "req-1"], message: owned("metadata") },
		];
		for (const writer of writers) {
			const before = stateDigest(base);
			const logged = refusalLog(base).length;
			const result = await runScript(writer.script, writer.args, env);
			expect({ writer: writer.name, code: result.code }).toEqual({ writer: writer.name, code: 3 });
			expect(result.stderr, writer.name).toMatch(writer.message);
			expect(stateDigest(base), writer.name).toBe(before);
			const record = refusalLog(base).slice(logged);
			expect(record, writer.name).toHaveLength(1);
			expect(record[0], writer.name).toContain("\tdm1-lab\t");
			expect(record[0], writer.name).toContain(`\t${writer.script}\t`);
		}
	});
});

describe("refusal that comes from the ID, not from files", () => {
	afterAll(cleanup);

	it("refuses a generation the library does not know on every path, and leaves a legacy ID untouched", async () => {
		const base = sandboxBase();
		const env = scriptEnv(base);
		seedTask(base, "dm7-future");
		const before = stateDigest(base);
		for (const command of ["claim", "heartbeat", "retry", "recover", "release"]) {
			const result = await runScript("sq-exec-state.sh", [command, "dm7-future"], env);
			expect({ command, code: result.code }).toEqual({ command, code: 3 });
			expect(result.stderr).toContain("refused: mission dm7-future has custody generation 7, which the installed custody library does not know");
		}
		expect(stateDigest(base)).toBe(before);
		expect((await runScript("sq-exec-state.sh", ["claim", "legacy-task"], env)).stdout.trim()).toBe("claimed");
	});

	it("answers through the service socket while it runs, and alone from the ID when it does not", async () => {
		const store = await initStore();
		const service = await startReady(store);
		const viaService = await cli(["custody", "check", "--store", store, "--mission", "dm2-pilot", "--responsibility", "landing", "--json"]);
		expect(viaService.code).toBe(3);
		expect(viaService.json).toMatchObject({ allowed: false, code: "engine_owned", source: "service" });
		await service.kill9();
		const local = await cli(["custody", "check", "--store", store, "--mission", "dm2-pilot", "--responsibility", "landing", "--json"]);
		expect(local.code).toBe(3);
		expect(local.json).toMatchObject({ allowed: false, code: "engine_owned", source: "local" });
		const legacy = await cli(["custody", "check", "--store", store, "--mission", "dm2-pilot", "--responsibility", "claim", "--json"]);
		expect(legacy.code).toBe(0);
		expect(legacy.json).toMatchObject({ allowed: true, source: "local" });
	});
});
