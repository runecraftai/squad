import { existsSync } from "node:fs";
import { join } from "node:path";
import { Warroom } from "./core.ts";
import { captureReview, checkPacket } from "./review.ts";

/**
 * Review capture and read-only currentness CLI.
 *
 * `capture` writes only Warroom data: the private database plus content-addressed artifacts under
 * the explicitly provided data directory. It never writes the reviewed repository, the Drill
 * database, or Drill logs, and it never runs validation, checkout, push or merge.
 *
 * `check` exits non-zero unless the packet is ready and its currentness was verified against the
 * recorded local source. The serving layer calls the same `checkPacket` function before acceptance,
 * so this manual command is not a weaker path.
 */

interface Parsed { command: string; flags: Record<string, string> }

const CAPTURE_FLAGS = ["repo", "drill-db", "drill-logs", "repo-id", "run", "target-ref", "head-ref", "plan", "warroom-data", "provenance"];
const CHECK_FLAGS = ["warroom-data", "packet"];

function parse(argv: string[]): Parsed {
	const [command, ...rest] = argv;
	if (!command) throw new Error("usage: review-cli.ts <capture|check> [flags]");
	const flags: Record<string, string> = {};
	for (let index = 0; index < rest.length; index++) {
		const token = rest[index];
		if (!token.startsWith("--")) throw new Error(`unexpected argument ${token}`);
		const name = token.slice(2);
		const value = rest[index + 1];
		if (value === undefined || value.startsWith("--")) throw new Error(`flag --${name} requires a value`);
		flags[name] = value;
		index++;
	}
	return { command, flags };
}

function requireFlags(flags: Record<string, string>, names: string[]): void {
	for (const name of names) if (!flags[name]) throw new Error(`missing required flag --${name}`);
	for (const name of Object.keys(flags)) if (!names.includes(name)) throw new Error(`unknown flag --${name}`);
}

function openWarroom(dataDir: string): Warroom {
	return new Warroom(join(dataDir, "warroom.db"), { id: process.env.WARROOM_ACTOR ?? "operator" });
}

export function main(argv: string[]): number {
	try {
		const { command, flags } = parse(argv);
		if (command === "capture") {
			requireFlags(flags, CAPTURE_FLAGS);
			if (flags.provenance !== "drill" && flags.provenance !== "fixture") throw new Error("--provenance must be explicitly drill or fixture");
			const warroom = openWarroom(flags["warroom-data"]);
			try {
				const result = captureReview(warroom, flags["warroom-data"], {
					repo: flags.repo,
					drillDb: flags["drill-db"],
					drillLogs: flags["drill-logs"],
					repoId: flags["repo-id"],
					runId: flags.run,
					targetRef: flags["target-ref"],
					headRef: flags["head-ref"],
					planRevisionId: flags.plan,
					provenance: flags.provenance,
				});
				console.log(JSON.stringify(result, null, 2));
				return 0;
			} finally {
				warroom.close();
			}
		}
		if (command === "check") {
			requireFlags(flags, CHECK_FLAGS);
			const dbPath = join(flags["warroom-data"], "warroom.db");
			if (!existsSync(dbPath)) {
				console.log(JSON.stringify({ packetId: flags.packet, status: "missing", currentness: "unverified", reasons: ["Warroom database does not exist"] }, null, 2));
				return 1;
			}
			const warroom = openWarroom(flags["warroom-data"]);
			try {
				const check = checkPacket(warroom, flags["warroom-data"], flags.packet);
				const { packet: _packet, capture: _capture, manifest: _manifest, ...report } = check;
				console.log(JSON.stringify(report, null, 2));
				return check.status === "ready" && check.currentness === "verified" && check.evidenceEligible && check.unreviewableFiles.length === 0 ? 0 : 1;
			} finally {
				warroom.close();
			}
		}
		throw new Error(`unknown command ${command}`);
	} catch (error) {
		console.error(JSON.stringify({ error: (error as Error).message }, null, 2));
		return 1;
	}
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
