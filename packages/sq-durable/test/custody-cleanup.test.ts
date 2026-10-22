import { existsSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { custodyCheck, refusalLog, runScript, sandboxBase, scriptEnv, seedTask, stateDigest } from "./custody-helpers.js";
import { admit, answer, cleanup, initStore, receipt, startReady, until, waitEffect } from "./helpers.js";

afterEach(cleanup);

const MISSION = "dm1-test";
const APPROVAL = "dm1-test/lab-deploy/r1";

/** A lab store with one admitted `dm1-*` mission whose approval is still pending, and the base that holds its records. */
async function pendingMission() {
	const store = await initStore();
	const service = await startReady(store);
	expect((await admit(store, MISSION)).code).toBe(0);
	const base = sandboxBase();
	seedTask(base, MISSION);
	writeFileSync(join(base, "state", `${MISSION}.exec`), "exec_state=running\nexec_last_activity=0\n");
	return { store, service, base, env: scriptEnv(base, { SQ_DURABLE_STORE: store }) };
}

async function complete(store: string): Promise<void> {
	expect((await answer(store, APPROVAL, ["--revision", "r1", "--decision", "approve", "--response-id", "c1"])).code).toBe(0);
	const view = await waitEffect(store, APPROVAL);
	expect(view.effect.state).toBe("applied");
	await until(async () => ((await receipt(store, APPROVAL)).missionStatus === "completed" ? true : undefined), 10_000, "mission completed");
}

describe("conditioned cleanup of engine-owned artifacts", () => {
	it("refuses teardown, forced or not, while the approval or the effect is pending, preserving every record", async () => {
		const { base, env } = await pendingMission();
		const before = stateDigest(base);
		for (const args of [[MISSION], [MISSION, "--force"]]) {
			const result = await runScript("sq-teardown.sh", args, env);
			expect(result.code).toBe(3);
			expect(result.stderr).toContain(`refused: cleanup of mission ${MISSION} needs the durable core to confirm the mission is terminal with every effect reconciled (generation 1); the mission is awaiting_approval`);
		}
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).filter((line) => line.includes("\tsq-teardown.sh\t"))).toHaveLength(2);
	});

	it("refuses teardown when the service is stopped, even for a mission that already finished", async () => {
		const { store, service, base, env } = await pendingMission();
		await complete(store);
		await service.kill9();
		const before = stateDigest(base);
		const result = await runScript("sq-teardown.sh", [MISSION, "--force"], env);
		expect(result.code).toBe(3);
		expect(result.stderr).toContain("the durable service is stopped");
		expect(stateDigest(base)).toBe(before);
	});

	it("keeps housekeeping off a durable mission's records whose .meta is gone until the mission is terminal and reconciled", async () => {
		const { store, base, env } = await pendingMission();
		const exec = join(base, "state", `${MISSION}.exec`);
		const status = join(base, "state", `${MISSION}.status`);
		// Without its .meta the mission's records look orphaned to housekeeping; that never licenses removing them.
		rmSync(join(base, "state", `${MISSION}.meta`));
		expect((await runScript("sq-exec-state.sh", ["recover-all"], env)).code).toBe(0);
		expect((await runScript("sq-self-heal.sh", ["--apply"], env)).code).toBe(0);
		expect(existsSync(exec)).toBe(true);
		expect(existsSync(status)).toBe(true);
		expect(refusalLog(base).filter((line) => line.includes("\tcleanup\t")).length).toBeGreaterThanOrEqual(2);

		// Once the engine confirms the mission is terminal and reconciled, exactly one housekeeping pass removes each.
		await complete(store);
		expect((await runScript("sq-exec-state.sh", ["recover-all"], env)).code).toBe(0);
		expect(existsSync(exec)).toBe(false);
		expect((await runScript("sq-self-heal.sh", ["--apply"], env)).code).toBe(0);
		expect(existsSync(status)).toBe(false);
		expect(existsSync(join(base, "state", "archived", `${MISSION}.status`))).toBe(true);
	});

	it("grants teardown's cleanup consultation exactly when the mission is terminal and reconciled", async () => {
		const { store, base, env } = await pendingMission();
		expect((await custodyCheck(MISSION, ["cleanup"], env)).code).toBe(3);
		await complete(store);
		const granted = await custodyCheck(MISSION, ["cleanup"], env);
		expect(granted).toMatchObject({ code: 0, stderr: "" });
		// Every other responsibility of a laboratory mission stays with the engine.
		for (const responsibility of ["claim", "recovery", "landing", "spawn"]) {
			expect((await custodyCheck(MISSION, [responsibility], env)).code, responsibility).toBe(3);
		}
		expect(refusalLog(base).filter((line) => line.includes("\tcleanup\t"))).toHaveLength(1);
	});
});
