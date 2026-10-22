import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { DURABLE_MISSION_PREFIX } from "../src/adapter/squad.js";
import { reservedGeneration } from "../src/core/index.js";
import { CUSTODY_LIB, runBash, sandboxBase, scriptEnv } from "./custody-helpers.js";
import { cleanup, cli, PACKAGE_DIR, tempDir, until } from "./helpers.js";

/**
 * A long-running legacy writer: it sources the custody library once, like the sentry sourcing sq-stall-detect, and then
 * answers one check per input line for as long as it lives.
 */
class LongRunningWriter {
	readonly child: ChildProcessWithoutNullStreams;
	private out = "";
	private err = "";
	private answered = 0;

	constructor(lib: string, env: NodeJS.ProcessEnv) {
		const script = [
			'. "$1"',
			'durable_custody_publish_signal long-writer || exit 9',
			'echo published',
			'while read -r id responsibility; do',
			'  if durable_custody_check "$id" "$responsibility"; then echo "rc=0"; else echo "rc=$?"; fi',
			'  echo "--" >&2',
			"done",
		].join("\n");
		this.child = spawn("bash", ["-c", script, "writer", lib], { env });
		this.child.stdout.setEncoding("utf8").on("data", (chunk: string) => {
			this.out += chunk;
		});
		this.child.stderr.setEncoding("utf8").on("data", (chunk: string) => {
			this.err += chunk;
		});
	}

	async ready(): Promise<void> {
		await until(async () => (this.out.includes("published\n") ? true : undefined), 10_000, "long-running writer start");
	}

	/** Run one check inside the long-running process and return its exit code and refusal text. */
	async check(id: string, responsibility: string): Promise<{ code: number; stderr: string }> {
		const index = this.answered++;
		const errBefore = this.err.length;
		this.child.stdin.write(`${id} ${responsibility}\n`);
		const code = await until(
			async () => {
				const codes = [...this.out.matchAll(/^rc=([0-9]+)$/gm)];
				return codes.length > index ? Number(codes[index]?.[1]) : undefined;
			},
			30_000,
			`check ${index}`,
		);
		await until(async () => (this.err.slice(errBefore).includes("--\n") ? true : undefined), 10_000, "check stderr");
		return { code, stderr: this.err.slice(errBefore).replace(/--\n$/, "") };
	}

	stop(): Promise<void> {
		return new Promise((resolve) => {
			if (this.child.exitCode !== null) return resolve();
			this.child.once("exit", () => resolve());
			this.child.stdin.end();
		});
	}
}

/** A scratch install: the custody library under bin/ and the built package beside it, as in the repository. */
function scratchInstall(): { root: string; lib: string } {
	const root = join(tempDir(), "install");
	mkdirSync(join(root, "bin"), { recursive: true });
	mkdirSync(join(root, "packages"), { recursive: true });
	symlinkSync(PACKAGE_DIR, join(root, "packages", "sq-durable"));
	const lib = join(root, "bin", "sq-durable-custody.sh");
	writeFileSync(lib, readFileSync(CUSTODY_LIB, "utf8"));
	return { root, lib };
}

function installGeneration(lib: string, generation: number): void {
	writeFileSync(lib, readFileSync(lib, "utf8").replace(/^SQ_DURABLE_CUSTODY_GENERATION=[0-9]+$/m, `SQ_DURABLE_CUSTODY_GENERATION=${generation}`));
}

afterEach(cleanup);

describe("generation signal of long-running writers", () => {
	it("pins the shell library's loaded generation and reserved prefix to the installed core", async () => {
		const tables = await cli(["custody", "tables", "--json"]);
		expect({ code: tables.code, stderr: tables.stderr }).toEqual({ code: 0, stderr: "" });
		const ids = ["dm0-a", "dm1-a", "dm2-pilot", "dm10-x", "dm-x", "dmz-x", "xdm2-x", "dm2", "DM2-x", "task-1"];
		const probe = await runBash(
			[
				"-c",
				[
					'. "$1"; shift',
					'printf "generation=%s\\n" "$_SQ_DURABLE_CUSTODY_LOADED"',
					'for id in "$@"; do',
					'  if durable_custody_reserved "$id"; then printf "reserved=%s\\n" "$id"; else printf "legacy=%s\\n" "$id"; fi',
					"done",
				].join("\n"),
				"probe",
				CUSTODY_LIB,
				...ids,
			],
			process.env,
		);
		expect({ code: probe.code, stderr: probe.stderr }).toEqual({ code: 0, stderr: "" });
		const [generation, ...classified] = probe.stdout.trim().split("\n");
		expect(generation).toBe(`generation=${tables.json.installed}`);
		expect(classified).toEqual(
			ids.map((id) => `${reservedGeneration(id, DURABLE_MISSION_PREFIX) === undefined ? "legacy" : "reserved"}=${id}`),
		);
	});
	it("refuses a writer that started before a generation change, while a legacy ID and a fresh writer are unaffected", async () => {
		const { lib } = scratchInstall();
		const base = sandboxBase();
		const env = scriptEnv(base);
		const writer = new LongRunningWriter(lib, env);
		try {
			await writer.ready();
			expect(await writer.check("dm2-pilot", "claim")).toEqual({ code: 0, stderr: "" });

			installGeneration(lib, 3);
			const stale = await writer.check("dm2-pilot", "claim");
			expect(stale.code).toBe(3);
			expect(stale.stderr).toContain("refused: this writer loaded custody generation 2 but generation 3 is installed; restart it before it acts on mission dm2-pilot");
			expect((await writer.check("task-legacy", "claim")).code).toBe(0);

			// The library going away leaves the old writer refused too, never authorized.
			writeFileSync(lib, "# removed\n");
			const removed = await writer.check("dm2-pilot", "claim");
			expect(removed.code).toBe(3);
			expect(removed.stderr).toContain("is missing or unreadable");
			const log = readFileSync(join(base, "data", "durable", "custody-refusals.log"), "utf8");
			expect(log.match(/\tdm2-pilot\tclaim\t/g)).toHaveLength(2);
		} finally {
			await writer.stop();
		}
	});

	it("refuses a writer whose library is newer than the installed custody core: the library or the core regressed", async () => {
		const { lib } = scratchInstall();
		installGeneration(lib, 3);
		const writer = new LongRunningWriter(lib, scriptEnv(sandboxBase()));
		try {
			await writer.ready();
			const regressed = await writer.check("dm2-pilot", "claim");
			expect(regressed.code).toBe(3);
			expect(regressed.stderr).toContain("loaded custody generation 3 but only generation 2 is installed; the custody library regressed");
		} finally {
			await writer.stop();
		}
	});

	it("applies the same comparison in the custody core for any caller that reports its loaded generation", async () => {
		const stale = await cli(["custody", "check", "--mission", "dm2-pilot", "--responsibility", "claim", "--loaded-generation", "1", "--json"]);
		expect(stale.code).toBe(3);
		expect(stale.json).toMatchObject({ allowed: false, code: "stale_writer" });
		const current = await cli(["custody", "check", "--mission", "dm2-pilot", "--responsibility", "claim", "--loaded-generation", "2"]);
		expect(current.code).toBe(0);
		const legacy = await cli(["custody", "check", "--mission", "task-legacy", "--responsibility", "claim", "--loaded-generation", "1"]);
		expect(legacy.code).toBe(0);
	});

	it("names every live writer that never loaded a generation before it may be admitted", async () => {
		const { lib } = scratchInstall();
		const base = sandboxBase();
		const writer = new LongRunningWriter(lib, scriptEnv(base));
		const state = join(base, "state");
		try {
			await writer.ready();
			expect((await cli(["custody", "signals", "--state", state, "--json"])).code).toBe(0);
			const blocked = await cli(["custody", "signals", "--state", state, "--generation", "3", "--json"]);
			expect(blocked.code).toBe(3);
			expect(blocked.stderr).toContain(`long-writer (pid ${writer.child.pid}, loaded generation 2)`);
		} finally {
			await writer.stop();
		}
		// A writer that is gone no longer holds anything back.
		expect((await cli(["custody", "signals", "--state", state, "--generation", "3"])).code).toBe(0);
	});
});
