import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CUSTODY_LIB, custodyCheck, REPO_ROOT, refusalLog, runBash, runScript, sandboxBase, scriptEnv, seedTask, stateDigest } from "./custody-helpers.js";
import { admit, answer, cleanup, initStore, receipt, startReady, tempDir, until, waitEffect } from "./helpers.js";

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
		expect((await runScript("sq-exec-state.sh", ["recover-all"], env)).code).toBe(3);
		expect((await runScript("sq-self-heal.sh", ["--apply"], env)).code).toBe(3);
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

	it("refuses teardown, forced or not, of a legacy XO home that holds a non-terminal durable child", async () => {
		const base = sandboxBase();
		const xo = join(tempDir(), "xo-home");
		mkdirSync(join(xo, "state"), { recursive: true });
		writeFileSync(join(xo, ".sq-xo-home"), "domain\n");
		writeFileSync(join(xo, "AGENTS.md"), "# agents\n");
		writeFileSync(
			join(base, "state", "domain.meta"),
			[
				"window=Squad:sq-domain",
				`worktree=${xo}`,
				`project=${xo}`,
				"harness=echo",
				"kind=xo",
				"mode=xo",
				"yolo=off",
				`home=${xo}`,
				"projects=alpha",
				"",
			].join("\n"),
		);
		writeFileSync(join(xo, "state", "dm2-child.meta"), "window=Squad:sq-dm2-child\nkind=strike\n");
		const baseBefore = stateDigest(base);
		const xoBefore = stateDigest(xo);
		for (const args of [["domain"], ["domain", "--force"]]) {
			const result = await runScript("sq-teardown.sh", args, scriptEnv(base));
			expect({ args: args.join(" "), code: result.code }).toEqual({ args: args.join(" "), code: 3 });
			expect(result.stderr).toContain("refused: cleanup of mission dm2-child");
			expect(existsSync(join(xo, "state", "dm2-child.meta"))).toBe(true);
			expect(existsSync(join(base, "state", "domain.meta"))).toBe(true);
			expect(stateDigest(base)).toBe(baseBefore);
			expect(stateDigest(xo)).toBe(xoBefore);
		}
		expect(refusalLog(base).filter((line) => line.includes("\tdm2-child\tcleanup\tsq-teardown.sh\t"))).toHaveLength(2);
	});

	it("keeps a recover-all sweep going but exits 3 when it refused a durable mission", async () => {
		const base = sandboxBase();
		seedTask(base, MISSION);
		const durableExec = join(base, "state", `${MISSION}.exec`);
		writeFileSync(durableExec, "exec_state=running\nexec_last_activity=0\n");
		const legacyExec = join(base, "state", "legacy-orphan.exec");
		writeFileSync(legacyExec, "exec_state=running\nexec_last_activity=0\n");
		const before = readFileSync(durableExec, "utf8");
		const result = await runScript("sq-exec-state.sh", ["recover-all"], scriptEnv(base));
		expect(result.code).toBe(3);
		expect(readFileSync(durableExec, "utf8")).toBe(before);
		expect(existsSync(legacyExec)).toBe(false);
	});

	it("keeps a self-heal sweep going but exits 3 when it refused a durable mission", async () => {
		const base = sandboxBase();
		const durableStatus = join(base, "state", `${MISSION}.status`);
		writeFileSync(durableStatus, "working: started\n");
		const legacyStatus = join(base, "state", "legacy-orphan.status");
		writeFileSync(legacyStatus, "done: legacy\n");
		const before = readFileSync(durableStatus, "utf8");
		const result = await runScript("sq-self-heal.sh", ["--apply"], scriptEnv(base));
		expect(result.code).toBe(3);
		expect(readFileSync(durableStatus, "utf8")).toBe(before);
		expect(existsSync(join(base, "state", "archived", "legacy-orphan.status"))).toBe(true);
	});

	it("keeps a stall sweep going but exits 3 when it refused a durable mission", async () => {
		const base = sandboxBase();
		seedTask(base, MISSION);
		const durableExec = join(base, "state", `${MISSION}.exec`);
		writeFileSync(durableExec, "exec_state=running\nexec_last_activity=0\n");
		seedTask(base, "legacy-task");
		writeFileSync(join(base, "state", "legacy-task.status"), "working: started\n");
		const legacyExec = join(base, "state", "legacy-task.exec");
		writeFileSync(legacyExec, "exec_state=running\nexec_last_activity=0\nexec_retry_count=0\nexec_max_retries=3\n");
		const durableStatus = join(base, "state", `${MISSION}.status`);
		const before = readFileSync(durableStatus, "utf8");
		const result = await runScript(
			"sq-stall-detect.sh",
			["check"],
			scriptEnv(base, { SQUAD_STALL_TIMEOUT: "1", SQUAD_STALL_INTERRUPT_CMD: "/bin/true", SQUAD_STALL_AGENT_STATE: "dead" }),
		);
		expect(result.code).toBe(3);
		expect(readFileSync(durableStatus, "utf8")).toBe(before);
		expect(readFileSync(legacyExec, "utf8")).toContain("exec_state=retry_queued");
		expect(readFileSync(join(base, "state", "legacy-task.status"), "utf8")).toContain("stall interrupted");
	});
});

describe("custody ahead of every gate and mutation of the legacy writers", () => {
	it("refuses a retire of a durable mission even when the relay is inactive, with no state change", async () => {
		const { base, env } = await pendingMission();
		const before = stateDigest(base);
		const result = await runScript("sq-public-followup.sh", ["retire", MISSION], env);
		expect(result.code).toBe(3);
		expect(result.stderr).toContain(`refused: metadata of mission ${MISSION} belongs to the durable core (generation 1)`);
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses an emit for a durable mission even when the owning home's relay is inactive", async () => {
		const { base, env } = await pendingMission();
		const before = stateDigest(base);
		const result = await runScript(
			"sq-public-followup-emit.sh",
			["--home", base, "--obligation", MISSION, "--relation", "rel-1", "--source-home", "main", "--work-id", "work-1", "--generation", "1", "--outcome", "done", "--outcome-text", "finished"],
			env,
		);
		expect(result.code).toBe(3);
		expect(result.stderr).toContain(`refused: metadata of mission ${MISSION} belongs to the durable core (generation 1)`);
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses to remove a non-terminal durable mission's PR-watch records under the sentry-style and migrate callers, leaving every record", async () => {
		const { base, env } = await pendingMission();
		const state = join(base, "state");
		const template = join(REPO_ROOT, "bin", "sq-pr-poll.sh");
		for (const name of [`${MISSION}.pr-poll-retirement`, `${MISSION}.pr-poll`, `${MISSION}.pr-poll-registration`, `${MISSION}.check.sh`]) {
			writeFileSync(join(state, name), "retained\n");
		}
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const lib = join(REPO_ROOT, "bin", "sq-pr-lib.sh");
		const sentry = await runBash(["-c", '. "$1"; fm_pr_poll_retirement_recover_one "$2" "$3" "$4"', "sentry", lib, state, MISSION, template], env);
		expect(sentry.code).toBe(3);
		expect(sentry.stderr).toMatch(new RegExp(`^refused: cleanup of mission ${MISSION} needs the durable core to confirm`, "m"));
		const migrate = await runBash(
			["-c", '. "$1"; fm_pr_poll_retirement_recover_all "$2" "$3"; printf "rc=%s\\n" "$?"', "migrate", lib, state, template],
			env,
		);
		expect(migrate.stdout.trim()).toBe("rc=3");
		expect(stateDigest(base)).toBe(before);
		const records = refusalLog(base).slice(logged);
		expect(records).toHaveLength(2);
		expect(records[0]).toContain(`\t${MISSION}\tcleanup\tsentry\t`);
		expect(records[1]).toContain(`\t${MISSION}\tcleanup\tmigrate\t`);
	});

	it("grants the PR-watch retirement cleanup once the durable mission is terminal and reconciled, and only then validates the records", async () => {
		const { store, base, env } = await pendingMission();
		await complete(store);
		const state = join(base, "state");
		const template = join(REPO_ROOT, "bin", "sq-pr-poll.sh");
		writeFileSync(join(state, `${MISSION}.pr-poll-retirement`), "not a receipt\n");
		const lib = join(REPO_ROOT, "bin", "sq-pr-lib.sh");
		const retire = await runBash(["-c", '. "$1"; fm_pr_poll_retirement_recover_one "$2" "$3" "$4"', "sentry", lib, state, MISSION, template], env);
		expect(retire.code).toBe(1);
		expect(retire.stderr).toBe("");
		expect(existsSync(join(state, `${MISSION}.pr-poll-retirement`))).toBe(true);
	});

	it("leaves a durable mission's quarantined artifact untouched by the PR-check migration", async () => {
		const { base, env } = await pendingMission();
		const quarantine = join(base, "state", ".pr-check-quarantine");
		mkdirSync(quarantine, { recursive: true });
		chmodSync(quarantine, 0o700);
		const artifact = join(quarantine, `${MISSION}.diagnostic.pending-canonical`);
		writeFileSync(artifact, "diagnostic\n");
		chmodSync(artifact, 0o644);
		const result = await runScript("sq-pr-check-migrate.sh", [], env);
		expect(result.code).toBe(3);
		expect(statSync(artifact).mode & 0o777).toBe(0o644);
	});
});

describe("custody refusals that hold even when the relay is inactive or the sweep repeats", () => {
	it("refuses every public-followup write subcommand for a durable mission before the relay gate", async () => {
		const { base, env } = await pendingMission();
		const before = stateDigest(base);
		const writes = [
			["register", MISSION, "--relation", "rel-1", "--work-home", "main", "--work-id", "work-1", "--generation", "1"],
			["deliver", MISSION],
			["record-posted", MISSION, "--attempt", "1", "--chunks", "1"],
			["retire", MISSION],
			["retire", MISSION, "--force"],
		];
		for (const args of writes) {
			const result = await runScript("sq-public-followup.sh", args, env);
			expect({ args: args.join(" "), code: result.code }).toEqual({ args: args.join(" "), code: 3 });
			expect(result.stderr).toContain(`refused: metadata of mission ${MISSION} belongs to the durable core (generation 1)`);
		}
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses consumption of a durable mission's event before the relay gate, leaving the event unconsumed", async () => {
		const { base, env } = await pendingMission();
		const events = join(base, "state", "public-followup", "events");
		mkdirSync(events, { recursive: true });
		writeFileSync(join(events, "evt-1.json"), JSON.stringify({ obligation_id: MISSION }));
		const before = stateDigest(base);
		const result = await runScript("sq-public-followup.sh", ["consume"], env);
		expect(result.code).toBe(3);
		expect(result.stderr).toContain(`refused: metadata of mission ${MISSION} belongs to the durable core (generation 1)`);
		expect(existsSync(join(events, "evt-1.json"))).toBe(true);
		expect(stateDigest(base)).toBe(before);
	});

	it("fails the PR-check migration, without publishing its marker, for a non-diagnostic durable artifact", async () => {
		const { base, env } = await pendingMission();
		const quarantine = join(base, "state", ".pr-check-quarantine");
		mkdirSync(quarantine, { recursive: true });
		chmodSync(quarantine, 0o700);
		const artifact = join(quarantine, `${MISSION}.pr-poll`);
		writeFileSync(artifact, "pr=https://example.invalid/pull/1\n");
		chmodSync(artifact, 0o644);
		const result = await runScript("sq-pr-check-migrate.sh", [], env);
		expect(result.code).toBe(3);
		expect(statSync(artifact).mode & 0o777).toBe(0o644);
		expect(existsSync(join(base, "state", ".pr-check-migration-v1"))).toBe(false);
	});

	it("appends a refusal to the log once per mission, responsibility and writer, while still printing and refusing every time", async () => {
		const { base, env } = await pendingMission();
		const script = ". \"$1\"; shift; for i in 1 2 3; do durable_custody_check \"$@\"; done; durable_custody_check \"$1\" retry";
		const result = await runBash(["-c", script, "custody", CUSTODY_LIB, MISSION, "claim"], env);
		expect(result.stderr.split("\n").filter((line) => line.includes(`refused: claim of mission ${MISSION}`))).toHaveLength(3);
		expect(refusalLog(base).filter((line) => line.includes(`\t${MISSION}\tclaim\t`))).toHaveLength(1);
		expect(refusalLog(base).filter((line) => line.includes(`\t${MISSION}\tretry\t`))).toHaveLength(1);
	});

	it("retires a terminal, reconciled durable mission's records completely under teardown's single cleanup decision", async () => {
		const { store, base, env } = await pendingMission();
		await complete(store);
		const worktree = join(tempDir(), "worktree");
		const project = join(tempDir(), "project");
		for (const dir of [worktree, project]) {
			mkdirSync(dir, { recursive: true });
			execFileSync("git", ["-C", dir, "init", "-q", "-b", "main"]);
			execFileSync("git", ["-C", dir, "-c", "user.email=test@example.invalid", "-c", "user.name=test", "commit", "-q", "--allow-empty", "-m", "init"]);
		}
		seedTask(base, MISSION, { window: `Squad:sq-${MISSION}`, worktree, project });
		writeFileSync(join(base, "state", `${MISSION}.status`), "done: landed\n");
		for (const suffix of ["turn-ended", "pi-ext.ts", "muse-session"]) writeFileSync(join(base, "state", `${MISSION}.${suffix}`), "x\n");
		const fobBin = join(tempDir(), "fob-bin");
		mkdirSync(fobBin, { recursive: true });
		writeFileSync(join(fobBin, "fob"), "#!/usr/bin/env bash\nexit 0\n");
		chmodSync(join(fobBin, "fob"), 0o755);
		const result = await runScript("sq-teardown.sh", [MISSION], { ...env, PATH: `${fobBin}:${env.PATH}` });
		expect(result.stderr).not.toContain("REFUSED");
		expect(result.code).toBe(0);
		for (const file of [".meta", ".status", ".exec", ".turn-ended", ".pi-ext.ts", ".muse-session"]) {
			expect(existsSync(join(base, "state", `${MISSION}${file}`)), file).toBe(false);
		}
	});
});
