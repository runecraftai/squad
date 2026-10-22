import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { refusalLog, REPO_ROOT, runBash, runScript, sandboxBase, scriptEnv, seedTask, stateDigest } from "./custody-helpers.js";
import { cleanup } from "./helpers.js";

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

	it("refuses to write a durable mission's parent status for a pending reply", async () => {
		const base = sandboxBase();
		const status = join(base, "state", "dm2-pilot.status");
		writeFileSync(status, "working: started\n");
		const before = readFileSync(status, "utf8");
		const logged = refusalLog(base).length;
		const result = await sourced("sq-pending-reply-lib.sh", 'fm_pending_reply_parent_custody "$1" || printf "rc=%s\\n" "$?"', [status], scriptEnv(base));
		expect(result.stdout.trim()).toBe("rc=3");
		expect(result.stderr).toMatch(owned("xo-routing", "dm2-pilot", 2));
		expect(readFileSync(status, "utf8")).toBe(before);
		const record = refusalLog(base).slice(logged);
		expect(record).toHaveLength(1);
		expect(record[0]).toContain("\tdm2-pilot\txo-routing\t");
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
		expect(refusalLog(base).filter((line) => line.includes("\tdm1-lab\tmetadata\t"))).toHaveLength(3);
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
		expect(outcomes).toHaveLength(3);
		for (const outcome of outcomes) expect(outcome).toMatch(/=[1-9][0-9]*$/);
		expect(count(result.stderr, owned("metadata", "dm1-lab", 1))).toBe(3);
		expect(stateDigest(base)).toBe(before);
		expect(refusalLog(base).filter((line) => line.includes("\tdm1-lab\tmetadata\t"))).toHaveLength(3);
	});
});
