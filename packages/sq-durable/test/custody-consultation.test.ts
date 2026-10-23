import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { refusalLog, REPO_ROOT, runBash, runScript, sandboxBase, scriptEnv, seedTask, stateDigest } from "./custody-helpers.js";
import { cleanup, tempDir } from "./helpers.js";

afterEach(cleanup);

const EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

function owned(responsibility: string, id: string, generation: number): RegExp {
	return new RegExp(`^refused: ${responsibility} of mission ${id} belongs to the durable core \\(generation ${generation}\\)$`, "m");
}

function count(text: string, pattern: RegExp): number {
	return [...text.matchAll(new RegExp(pattern.source, "gm"))].length;
}

/** Source one of the repository's shell libraries and run `body` with the remaining arguments at $1.. */
function sourced(library: string, body: string, args: string[], env: NodeJS.ProcessEnv) {
	return runBash(["-c", `. "$1"; shift\n${body}`, "writer", join(REPO_ROOT, "bin", library), ...args], env);
}

/** A delivered remote-XO outbox with one queued item, and the commitment sq-backlog-receive.sh verifies. */
function handoff(base: string, xo: string, key: string): string[] {
	mkdirSync(join(base, "state", "handoff"), { recursive: true });
	mkdirSync(join(base, "bin"), { recursive: true });
	writeFileSync(join(base, ".sq-xo-home"), "");
	writeFileSync(join(base, "AGENTS.md"), "# agents\n");
	const rel = `state/handoff/${xo}.outbox.md`;
	const body = `## In flight\n\n## Queued\n\n- [ ] ${key} mirror the reply\n\n## Done\n`;
	writeFileSync(join(base, rel), body);
	const bytes = Buffer.byteLength(body);
	const hash = createHash("sha256").update(body).digest("hex");
	writeFileSync(join(base, "state", "handoff", `.${xo}.upload-generation`), `1\n${bytes}\n${hash}\n`);
	return [rel, String(bytes), hash, "1"];
}

describe("every inventoried consultation point refuses a durable mission before it writes", () => {
	it("refuses a delivered handoff of a durable mission before the destination backlog is touched", async () => {
		const base = sandboxBase();
		seedTask(base, "dm2-pilot");
		const args = handoff(base, "xo-a", "dm2-pilot");
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const result = await runScript("sq-backlog-receive.sh", args, scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(owned("xo-routing", "dm2-pilot", 2));
		expect(stateDigest(base)).toBe(before);
		const record = refusalLog(base).slice(logged);
		expect(record).toHaveLength(1);
		expect(record[0]).toContain("\tdm2-pilot\t");
		expect(record[0]).toContain("\tsq-backlog-receive.sh\t");
	});

	it("refuses a remote reply that would append to a durable mission's status log", async () => {
		const base = sandboxBase();
		seedTask(base, "dm2-pilot");
		const delivered = join(base, "remote-reply.result");
		writeFileSync(
			delivered,
			[
				"schema=sq-remote-delta.v1",
				"status=continuity-broken",
				"path=state/parent-replies.status",
				"from_offset=0",
				"to_offset=0",
				`from_prefix_sha256=${EMPTY_SHA256}`,
				`to_prefix_sha256=${EMPTY_SHA256}`,
				`payload_sha256=${EMPTY_SHA256}`,
				"payload_bytes=0",
				"reason=cursor moved",
				"",
				"",
			].join("\n"),
		);
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const result = await runScript("sq-procevent-remote-reply.sh", ["ingest", "dm2-pilot", delivered], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(owned("xo-routing", "dm2-pilot", 2));
		expect(stateDigest(base)).toBe(before);
		const record = refusalLog(base).slice(logged);
		expect(record).toHaveLength(1);
		expect(record[0]).toContain("\tdm2-pilot\t");
		expect(record[0]).toContain("\tsq-procevent-remote-reply.sh\t");
	});

	it("refuses a durable mission's remote reply before it stores a referenced document", async () => {
		const base = sandboxBase();
		seedTask(base, "dm2-pilot");
		const payload = "see data/report.md for the detail\n";
		const hash = createHash("sha256").update(payload).digest("hex");
		const delivered = join(base, "remote-reply.result");
		writeFileSync(
			delivered,
			[
				"schema=sq-remote-delta.v1",
				"status=delta",
				"path=state/parent-replies.status",
				"from_offset=0",
				"to_offset=5",
				`from_prefix_sha256=${EMPTY_SHA256}`,
				`to_prefix_sha256=${EMPTY_SHA256}`,
				`payload_sha256=${hash}`,
				`payload_bytes=${Buffer.byteLength(payload)}`,
				"reason=reply",
				"",
				payload,
			].join("\n"),
		);
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const result = await runScript("sq-procevent-remote-reply.sh", ["ingest", "dm2-pilot", delivered], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(owned("xo-routing", "dm2-pilot", 2));
		expect(existsSync(join(base, "data", "remote-XOs"))).toBe(false);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).slice(logged)).toHaveLength(1);
	});

	it("refuses to resolve a durable mission's pending reply before it mutates the record", async () => {
		const base = sandboxBase();
		seedTask(base, "dm2-pilot");
		const corr = "0123456789abcdef";
		const status = join(base, "state", "dm2-pilot.status");
		writeFileSync(status, `working: started\ncorr=${corr} done: reported\n`);
		const dir = join(base, "state", "pending-replies");
		mkdirSync(dir, { recursive: true });
		const rec = join(dir, corr);
		writeFileSync(
			rec,
			[
				"schema=sq-pending-reply.v1",
				`corr_id=${corr}`,
				"task_id=dm2-pilot",
				`parent_home=${base}`,
				`parent_status=${status}`,
				"parent_status_scan_signature=",
				"request_summary=test",
				"created_epoch=1",
				"delivered_epoch=1",
				"phase=awaiting_report",
				"resolved_epoch=",
				"resolved_via=",
				"",
			].join("\n"),
		);
		const recordBefore = readFileSync(rec, "utf8");
		const statusBefore = readFileSync(status, "utf8");
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const result = await sourced(
			"sq-pending-reply-lib.sh",
			'fm_pending_reply_try_resolve "$1" "$2" >/dev/null || printf "rc=%s\\n" "$?"',
			[join(base, "state"), corr],
			scriptEnv(base),
		);
		expect(result.stdout.trim()).toBe("rc=3");
		expect(result.stderr).toMatch(owned("xo-routing", "dm2-pilot", 2));
		expect(readFileSync(rec, "utf8")).toBe(recordBefore);
		expect(readFileSync(status, "utf8")).toBe(statusBefore);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).slice(logged)).toHaveLength(1);
	});

	it("propagates a custody refusal from the Relay follow-up writer instead of reporting a cleared link", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab", { x_request: "req-1", x_request_ts: "1", x_followups: "0" });
		const meta = join(base, "state", "dm1-lab.meta");
		const before = readFileSync(meta, "utf8");
		const logged = refusalLog(base).length;
		for (const args of [
			["dm1-lab", "--text-file", "/dev/null"],
			["--clear", "dm1-lab"],
		]) {
			const result = await runScript("sq-x-followup.sh", args, scriptEnv(base));
			expect({ args: args.join(" "), code: result.code }).toEqual({ args: args.join(" "), code: 3 });
			expect(result.stderr).toMatch(owned("metadata", "dm1-lab", 1));
			expect(readFileSync(meta, "utf8")).toBe(before);
		}
		expect(refusalLog(base).slice(logged)).toHaveLength(2);
	});

	it("refuses a pending outbox holding a durable mission before any transfer or generation bump", async () => {
		const base = sandboxBase();
		const handoffDir = join(base, "data", "handoff");
		mkdirSync(handoffDir, { recursive: true });
		writeFileSync(
			join(base, "data", "XOs.md"),
			"- xo-a - test (host: xo-host; root: /srv/squad; home: /home/xo; scope: test; projects: p; added 2026-01-01)\n",
		);
		const outbox = join(handoffDir, "xo-a.outbox.md");
		const body = "## In flight\n\n## Queued\n\n- [ ] dm2-pilot mirror it\n\n## Done\n";
		writeFileSync(outbox, body);
		const logged = refusalLog(base).length;
		const result = await runScript("sq-backlog-handoff.sh", ["--resume-pending"], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(owned("xo-routing", "dm2-pilot", 2));
		expect(readFileSync(outbox, "utf8")).toBe(body);
		expect(existsSync(join(base, "state", ".remote-handoff-xo-a.generation"))).toBe(false);
		expect(refusalLog(base).slice(logged)).toHaveLength(1);
	});

	it("refuses every Relay meta mutator of a durable mission before it rewrites the record", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab");
		const meta = join(base, "state", "dm1-lab.meta");
		const before = readFileSync(meta, "utf8");
		const result = await sourced(
			"sq-x-lib.sh",
			[
				'fmx_meta_link_set "$1" req-1 1700000000 0; printf "link_set=%s\\n" "$?"',
				'fmx_meta_followups_set "$1" 3; printf "followups_set=%s\\n" "$?"',
				'fmx_meta_link_clear "$1"; printf "link_clear=%s\\n" "$?"',
			].join("\n"),
			[meta],
			scriptEnv(base),
		);
		expect(result.stdout.trim().split("\n")).toEqual(["link_set=3", "followups_set=3", "link_clear=3"]);
		expect(count(result.stderr, owned("metadata", "dm1-lab", 1))).toBe(3);
		expect(readFileSync(meta, "utf8")).toBe(before);
		expect(refusalLog(base).filter((line) => line.includes("\tdm1-lab\tmetadata\t"))).toHaveLength(1);
	});

	it("refuses every Relay meta mutator of a durable mission whose meta is deleted, with exit 3 and no state change", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab");
		const meta = join(base, "state", "dm1-lab.meta");
		rmSync(meta);
		const before = stateDigest(base);
		const result = await sourced(
			"sq-x-lib.sh",
			[
				'fmx_meta_link_set "$1" req-1 1700000000 0; printf "link_set=%s\\n" "$?"',
				'fmx_meta_followups_set "$1" 3; printf "followups_set=%s\\n" "$?"',
				'fmx_meta_link_clear "$1"; printf "link_clear=%s\\n" "$?"',
			].join("\n"),
			[meta],
			scriptEnv(base),
		);
		expect(result.stdout.trim().split("\n")).toEqual(["link_set=3", "followups_set=3", "link_clear=3"]);
		expect(count(result.stderr, owned("metadata", "dm1-lab", 1))).toBe(3);
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses every Relay command of a durable mission whose meta is deleted, before any branch reads or posts", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab");
		rmSync(join(base, "state", "dm1-lab.meta"));
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		for (const [script, args] of [
			["sq-x-link.sh", ["dm1-lab", "req-1"]],
			["sq-x-followup.sh", ["--clear", "dm1-lab"]],
			["sq-x-followup.sh", ["dm1-lab", "--text-file", "/dev/null"]],
		] as const) {
			const result = await runScript(script, [...args], scriptEnv(base));
			expect({ script, args: args.join(" "), code: result.code }).toEqual({ script, args: args.join(" "), code: 3 });
			expect(result.stderr).toMatch(owned("metadata", "dm1-lab", 1));
			expect(result.stderr).not.toContain("no such task");
			expect(stateDigest(base)).toBe(before);
		}
		expect(refusalLog(base).slice(logged)).toHaveLength(3);
	});

	it("posts no Relay follow-up for a refused durable mission and leaves its link in place", async () => {
		const base = sandboxBase();
		const root = join(tempDir(), "root");
		mkdirSync(join(root, "bin"), { recursive: true });
		const posted = join(tempDir(), "posted");
		writeFileSync(join(root, "bin", "sq-x-reply.sh"), `#!/usr/bin/env bash\nprintf posted > "${posted}"\n`, { mode: 0o755 });
		seedTask(base, "dm1-lab", { x_request: "req-1", x_request_ts: "1700000000", x_followups: "0" });
		const before = stateDigest(base);
		const result = await runScript(
			"sq-x-followup.sh",
			["dm1-lab", "--text-file", "/dev/null"],
			scriptEnv(base, { SQUAD_ROOT_OVERRIDE: root, SQX_NOW_OVERRIDE: "1700000100" }),
		);
		expect(result.code).toBe(3);
		expect(result.stderr).toMatch(owned("metadata", "dm1-lab", 1));
		expect(existsSync(posted)).toBe(false);
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses a PR-watch migration of a durable mission before it quarantines the mission's legacy poll", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab");
		const state = join(base, "state");
		writeFileSync(join(state, "dm1-lab.check.sh"), "legacy check\n");
		writeFileSync(join(state, "dm1-lab.pr-poll"), "legacy poll\n");
		writeFileSync(join(state, "dm1-lab.pr-poll-registration"), "legacy registration\n");
		const before = stateDigest(base);
		const result = await runScript("sq-pr-check-migrate.sh", [], scriptEnv(base));
		expect(result.code).toBe(3);
		expect(result.stderr).toMatch(owned("metadata", "dm1-lab", 1));
		expect(existsSync(join(state, "dm1-lab.check.sh"))).toBe(true);
		expect(existsSync(join(state, "dm1-lab.pr-poll"))).toBe(true);
		expect(existsSync(join(state, "dm1-lab.pr-poll-registration"))).toBe(true);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).filter((line) => line.includes("\tdm1-lab\tmetadata\t"))).toHaveLength(1);
	});

	it("refuses a pending PR-watch retirement of a durable mission before the migration touches its records", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab");
		const state = join(base, "state");
		writeFileSync(join(state, "dm1-lab.pr-poll-retirement"), "retirement receipt\n");
		const before = stateDigest(base);
		const result = await runScript("sq-pr-check-migrate.sh", [], scriptEnv(base));
		expect(result.code).toBe(3);
		expect(result.stderr).toMatch(/^refused: cleanup of mission dm1-lab needs the durable core to confirm the mission is terminal/m);
		expect(existsSync(join(state, "dm1-lab.pr-poll-retirement"))).toBe(true);
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses the PR-check migration of a non-terminal durable mission's PR-watch records before it quarantines them", async () => {
		const base = sandboxBase();
		seedTask(base, "dm2-pilot");
		const state = join(base, "state");
		writeFileSync(join(state, "dm2-pilot.check.sh"), "#!/bin/sh\necho stale\n");
		writeFileSync(join(state, "dm2-pilot.pr-poll"), "poll\n");
		writeFileSync(join(state, "dm2-pilot.pr-poll-registration"), "registration\n");
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const result = await runScript("sq-pr-check-migrate.sh", [], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(/^refused: cleanup of mission dm2-pilot needs the durable core to confirm the mission is terminal/m);
		expect(stateDigest(base)).toBe(before);
		expect(existsSync(join(state, "dm2-pilot.pr-poll"))).toBe(true);
		expect(refusalLog(base).slice(logged).filter((line) => line.includes("\tdm2-pilot\tcleanup\t"))).toHaveLength(1);
	});

	it("refuses to publish the migration marker when a diagnostic obligation of a durable mission is custody-refused", async () => {
		const base = sandboxBase();
		const state = join(base, "state");
		const quarantine = join(state, ".pr-check-quarantine");
		mkdirSync(quarantine, { mode: 0o700 });
		chmodSync(quarantine, 0o700);
		const message = "task dm1-lab: canonical legacy poll rebuilt and armed";
		const obligation = join(quarantine, "dm1-lab.diagnostic.canonical");
		writeFileSync(obligation, `${message}\n`, { mode: 0o600 });
		const log = join(state, ".pr-check-migration.log");
		writeFileSync(log, `${message}\n`, { mode: 0o600 });
		const obligationBefore = readFileSync(obligation, "utf8");
		const logBefore = readFileSync(log, "utf8");
		const result = await runScript("sq-pr-check-migrate.sh", [], scriptEnv(base));
		expect(result.code).toBe(3);
		expect(result.stderr).toMatch(owned("metadata", "dm1-lab", 1));
		expect(existsSync(join(state, ".pr-check-migration-v1"))).toBe(false);
		expect(readFileSync(obligation, "utf8")).toBe(obligationBefore);
		expect(readFileSync(log, "utf8")).toBe(logBefore);
	});

	it("refuses a pending outcome obligation of a durable mission during recovery, with exit 3 and no state change", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab");
		const quarantine = join(base, "state", ".pr-check-quarantine");
		mkdirSync(quarantine, { mode: 0o700 });
		chmodSync(quarantine, 0o700);
		writeFileSync(join(quarantine, "dm1-lab.diagnostic.pending-canonical"), "task dm1-lab: migration outcome tracking started before legacy poll handling\n", {
			mode: 0o600,
		});
		const before = stateDigest(base);
		const result = await runScript("sq-pr-check-migrate.sh", [], scriptEnv(base));
		expect(result.code).toBe(3);
		expect(result.stderr).toMatch(owned("metadata", "dm1-lab", 1));
		expect(existsSync(join(quarantine, "dm1-lab.diagnostic.pending-canonical"))).toBe(true);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).filter((line) => line.includes("\tdm1-lab\tmetadata\t")).length).toBeGreaterThanOrEqual(1);
	});

	it("refuses every PR-watch mutator of a durable mission before it stages an artifact", async () => {
		const base = sandboxBase();
		seedTask(base, "dm1-lab");
		const state = join(base, "state");
		const template = join(base, "sq-pr-poll.sh");
		writeFileSync(template, "# poll\n");
		const before = stateDigest(base);
		const result = await sourced(
			"sq-pr-lib.sh",
			[
				'fm_pr_poll_prepare "$1" dm1-lab github https://github.com/o/r/pull/1 github.com o/r 1 "$2"; printf "prepare=%s\\n" "$?"',
				'fm_pr_poll_retirement_publish "$1" dm1-lab "$2" merged; printf "publish=%s\\n" "$?"',
				'fm_pr_poll_retirement_recover_one "$1" dm1-lab "$2"; printf "recover=%s\\n" "$?"',
			].join("\n"),
			[state, template],
			scriptEnv(base),
		);
		const outcomes = result.stdout.trim().split("\n");
		expect(outcomes).toEqual(["prepare=3", "publish=3", "recover=0"]);
		expect(count(result.stderr, owned("metadata", "dm1-lab", 1))).toBe(2);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).filter((line) => line.includes("\tdm1-lab\tmetadata\t"))).toHaveLength(1);
	});

	it("resolves the durable store and refusal log from SQUAD_ROOT_OVERRIDE like the writers it guards", async () => {
		const base = sandboxBase();
		seedTask(base, "dm2-pilot");
		const env = scriptEnv(base);
		delete env.SQUAD_BASE;
		delete env.SQUAD_HOME;
		env.SQUAD_ROOT_OVERRIDE = base;
		const before = stateDigest(base);
		const result = await runScript("sq-teardown.sh", ["dm2-pilot", "--force"], env);
		expect(result.code).toBe(3);
		expect(result.stderr).toContain(`${base}/data/durable/store does not exist`);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base)).toHaveLength(1);
	});

	it("refuses every public-followup mutation and publication of a durable obligation", async () => {
		const base = sandboxBase();
		const fakebin = join(tempDir(), "bin");
		mkdirSync(fakebin, { recursive: true });
		writeFileSync(
			join(fakebin, "tasks-axi"),
			[
				"#!/usr/bin/env bash",
				'case "$*" in',
				'  "public-followup list --json") printf \'%s\' \'{"public_followups":[{"id":"dm1-lab","state":"done","public_followup":{"delivery":{"state":"posted"},"request":{}}}]}\' ;;',
				"  *) exit 0 ;;",
				"esac",
				"",
			].join("\n"),
			{ mode: 0o755 },
		);
		writeFileSync(join(base, ".env"), "SQX_PAIRING_TOKEN=test-token\n");
		const state = join(base, "state");
		const registry = join(state, "public-followup", "registry");
		mkdirSync(registry, { recursive: true, mode: 0o700 });
		chmodSync(registry, 0o700);
		const registration = join(registry, "dm1-lab");
		writeFileSync(
			registration,
			[
				"obligation_id=dm1-lab",
				"relation_id=rel",
				"work_home=main",
				"work_id=legacy-work",
				"generation=1",
				"platform=x",
				"request_id=req",
				"",
			].join("\n"),
			{ mode: 0o600 },
		);
		const events = join(state, "public-followup", "events");
		mkdirSync(events, { recursive: true, mode: 0o700 });
		chmodSync(events, 0o700);
		const consumed = join(state, "public-followup", "consumed");
		mkdirSync(consumed, { recursive: true, mode: 0o700 });
		chmodSync(consumed, 0o700);
		const deliverables = "{}";
		const eventId = createHash("sha256")
			.update(["dm1-lab", "rel", "main", "legacy-work", "1", "pr-merged", deliverables].join("\x1f"))
			.digest("hex");
		const event = join(events, `${eventId}.json`);
		writeFileSync(
			event,
			JSON.stringify({
				schema_version: 1,
				event_id: eventId,
				obligation_id: "dm1-lab",
				relation_id: "rel",
				work_id: "legacy-work",
				generation: 1,
				source_home_id: "main",
				outcome_type: "pr-merged",
				deliverables: {},
				public_safe_outcome: "landed",
				occurred_at: "2026-01-01T00:00:00Z",
				successor: null,
			}),
			{ mode: 0o600 },
		);
		const env = scriptEnv(base, { PATH: `${fakebin}:${process.env.PATH ?? ""}` });
		const before = stateDigest(base);
		const registrationBefore = readFileSync(registration, "utf8");
		const commands: [string, string[]][] = [
			["register", ["dm1-lab", "--relation", "rel", "--work-home", "main", "--work-id", "legacy-work", "--generation", "1"]],
			["deliver", ["dm1-lab", "--text-file", "/dev/null"]],
			["record-posted", ["dm1-lab", "--attempt", "1", "--chunks", "1"]],
			["retire", ["dm1-lab"]],
			["pending", []],
			["consume", []],
		];
		for (const [command, args] of commands) {
			const result = await runScript("sq-public-followup.sh", [command, ...args], env);
			expect({ command, code: result.code }, `${command}\n${result.stderr}`).toEqual({ command, code: 3 });
			expect(result.stderr, command).toMatch(owned("metadata", "dm1-lab", 1));
			expect(readFileSync(registration, "utf8"), command).toBe(registrationBefore);
			expect(existsSync(event), command).toBe(true);
			expect(stateDigest(base), command).toBe(before);
		}
		const emitted = await runScript(
			"sq-public-followup-emit.sh",
			[
				"--home",
				base,
				"--obligation",
				"dm1-lab",
				"--relation",
				"rel",
				"--source-home",
				"main",
				"--work-id",
				"legacy-work",
				"--generation",
				"1",
				"--outcome",
				"pr-merged",
				"--outcome-text",
				"landed",
			],
			env,
		);
		expect(emitted.code).toBe(3);
		expect(emitted.stderr).toMatch(owned("metadata", "dm1-lab", 1));
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses a durable mission registered as a remote XO before the remote route writes its launch metadata", async () => {
		const base = sandboxBase();
		writeFileSync(
			join(base, "data", "XOs.md"),
			"- dm2-remote - remote route fixture (host: fake-host; root: /remote/root; home: /remote/home; scope: test; projects: alpha; added 2026-01-01)\n",
		);
		const before = stateDigest(base);
		const result = await runScript("sq-spawn.sh", ["dm2-remote", "--xo"], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(owned("xo-routing", "dm2-remote", 2));
		expect(existsSync(join(base, "state", "dm2-remote.meta"))).toBe(false);
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses a non-terminal durable mission's pending PR-watch retirement in sq-pr-check with exit 3 and no state change", async () => {
		const base = sandboxBase();
		seedTask(base, "dm2-pilot");
		const receipt = join(base, "state", "dm2-pilot.pr-poll-retirement");
		writeFileSync(receipt, "retirement receipt\n");
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const result = await runScript("sq-pr-check.sh", ["dm2-pilot", "https://github.com/acme/app/pull/7"], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(/^refused: cleanup of mission dm2-pilot needs the durable core to confirm the mission is terminal/m);
		expect(existsSync(receipt)).toBe(true);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).slice(logged).filter((line) => line.includes("\tdm2-pilot\tcleanup\t"))).toHaveLength(1);
	});

	it("refuses a noncanonical reserved PR-watch artifact in the migration before it quarantines it, consulting cleanup", async () => {
		const base = sandboxBase();
		const state = join(base, "state");
		writeFileSync(join(state, "dm2-pilot+x.check.sh"), "legacy check\n");
		writeFileSync(join(state, "dm2-pilot+x.pr-poll"), "legacy poll\n");
		writeFileSync(join(state, "dm2-pilot+x.pr-poll-registration"), "legacy registration\n");
		const before = stateDigest(base);
		const result = await runScript("sq-pr-check-migrate.sh", [], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(/^refused: cleanup of mission dm2-pilot\+x /m);
		expect(existsSync(join(state, "dm2-pilot+x.check.sh"))).toBe(true);
		expect(existsSync(join(state, "dm2-pilot+x.pr-poll"))).toBe(true);
		expect(existsSync(join(state, "dm2-pilot+x.pr-poll-registration"))).toBe(true);
		expect(stateDigest(base)).toBe(before);
	});

	it("refuses a case-variant noncanonical artifact of a durable mission in the migration before it quarantines it", async () => {
		const base = sandboxBase();
		const state = join(base, "state");
		writeFileSync(join(state, "DM2-pilot+x.check.sh"), "legacy check\n");
		writeFileSync(join(state, "DM2-pilot+x.pr-poll"), "legacy poll\n");
		writeFileSync(join(state, "DM2-pilot+x.pr-poll-registration"), "legacy registration\n");
		const before = stateDigest(base);
		const result = await runScript("sq-pr-check-migrate.sh", [], scriptEnv(base));
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(/^refused: metadata of mission DM2-pilot\+x collides with the reserved durable ID dm2-pilot\+x/m);
		expect(existsSync(join(state, "DM2-pilot+x.check.sh"))).toBe(true);
		expect(existsSync(join(state, "DM2-pilot+x.pr-poll"))).toBe(true);
		expect(existsSync(join(state, "DM2-pilot+x.pr-poll-registration"))).toBe(true);
		expect(stateDigest(base)).toBe(before);
	});

	it("consumes the legacy follow-up events of a batch past a durable one, which stays in place with exit 3", async () => {
		const base = sandboxBase();
		const fakebin = join(tempDir(), "bin");
		mkdirSync(fakebin, { recursive: true });
		writeFileSync(join(fakebin, "tasks-axi"), "#!/usr/bin/env bash\nexit 0\n", { mode: 0o755 });
		writeFileSync(join(base, ".env"), "SQX_PAIRING_TOKEN=test-token\n");
		const events = join(base, "state", "public-followup", "events");
		const consumed = join(base, "state", "public-followup", "consumed");
		mkdirSync(events, { recursive: true, mode: 0o700 });
		mkdirSync(consumed, { recursive: true, mode: 0o700 });
		const eventFor = (obligation: string) => {
			const eventId = createHash("sha256")
				.update([obligation, "rel", "main", `${obligation}-work`, "1", "pr-merged", "{}"].join("\x1f"))
				.digest("hex");
			const file = join(events, `${eventId}.json`);
			writeFileSync(
				file,
				JSON.stringify({
					schema_version: 1,
					event_id: eventId,
					obligation_id: obligation,
					relation_id: "rel",
					work_id: `${obligation}-work`,
					generation: 1,
					source_home_id: "main",
					outcome_type: "pr-merged",
					deliverables: {},
					public_safe_outcome: "landed",
					occurred_at: "2026-01-01T00:00:00Z",
					successor: null,
				}),
				{ mode: 0o600 },
			);
			return { eventId, file };
		};
		const durable = eventFor("dm1-lab");
		const legacy = eventFor("legacy-obl");
		const durableBefore = readFileSync(durable.file, "utf8");
		const env = scriptEnv(base, { PATH: `${fakebin}:${process.env.PATH ?? ""}` });
		const result = await runScript("sq-public-followup.sh", ["consume"], env);
		expect({ code: result.code }).toEqual({ code: 3 });
		expect(result.stderr).toMatch(owned("metadata", "dm1-lab", 1));
		expect(existsSync(legacy.file)).toBe(false);
		expect(existsSync(join(consumed, legacy.eventId))).toBe(true);
		expect(readFileSync(durable.file, "utf8")).toBe(durableBefore);
		expect(existsSync(join(consumed, durable.eventId))).toBe(false);
	});

	it("prints the crew state but exits 3 when custody refused the drill PR sidecar of a durable mission, and 0 for a legacy task", async () => {
		const base = sandboxBase();
		const worktree = join(base, "wt");
		mkdirSync(worktree);
		seedTask(base, "dm1-lab", { worktree });
		seedTask(base, "task-1", { worktree });
		const before = stateDigest(base);
		const logged = refusalLog(base).length;
		const durable = await runScript("sq-crew-state.sh", ["dm1-lab"], scriptEnv(base));
		expect(durable.stdout).toMatch(/^state: /);
		expect({ code: durable.code }).toEqual({ code: 3 });
		expect(durable.stderr).toMatch(owned("metadata", "dm1-lab", 1));
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).slice(logged)).toHaveLength(1);
		const legacy = await runScript("sq-crew-state.sh", ["task-1"], scriptEnv(base));
		expect(legacy.stdout).toMatch(/^state: /);
		expect({ code: legacy.code }).toEqual({ code: 0 });
	});
});
