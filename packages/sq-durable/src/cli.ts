#!/usr/bin/env -S node --disable-warning=ExperimentalWarning
import { randomUUID } from "node:crypto";
import { userInfo } from "node:os";
import { parseArgs } from "node:util";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
	CUSTODY_TABLE_DIGESTS,
	CUSTODY_TABLES,
	INSTALLED_CUSTODY_GENERATION,
	inventoryViolations,
	LEGACY_WRITERS,
	scanLegacyWriters,
	squadCustodyScheme,
} from "./adapter/legacy-writers.js";
import { terminalOrigin } from "./adapter/squad.js";
import { CUSTODY_REFUSAL_EXIT, type CustodyDecision, decideCustody, type GenerationSignal, staleWriters, tableDigest } from "./core/index.js";
import { readLedger } from "./lab/executor.js";
import { PROTOCOL_VERSION, type Response } from "./service/protocol.js";
import { callSocket, ServiceUnavailable } from "./service/socket.js";
import { resolveStore, storePaths } from "./service/store.js";

const USAGE = `sq-durable - durable mission core, laboratory slice A1 (protocol ${PROTOCOL_VERSION})

Store and service:
  sq-durable init --store DIR [--lab]          create a new store (refuses a non-empty directory)
  sq-durable serve --store DIR [--poll-ms N]   run the single-writer service of DIR
  sq-durable ready --store DIR [--wait S]      readiness probe; exit 0 only when ready

Terminal surface (every command talks to the service socket):
  sq-durable admit --store DIR --mission dm1-<slug> --action NAME --revision REV [--args JSON]
  sq-durable approvals pending --store DIR
  sq-durable answer --store DIR --approval ID --revision REV --decision approve|reject
                    [--response-id ID] [--action-digest D] [--timeout S]
  sq-durable receipt --store DIR --approval ID
  sq-durable mission --store DIR --mission ID
  sq-durable stats --store DIR
  sq-durable ledger --store DIR                laboratory executor ledger, read from its own file

Custody (plan section 12; the shell side is bin/sq-durable-custody.sh):
  sq-durable custody check --mission ID --responsibility R[,R...] [--loaded-generation N] [--store DIR]
                    may a legacy writer exercise R on mission ID? Asks the store's service; when no service
                    answers, decides from the ID and its generation table alone, and never confirms a condition
  sq-durable custody tables                    published custody tables, their digests and the installed generation
  sq-durable custody inventory --repo DIR      legacy writers derived from DIR/bin, the inventory, and violations
  sq-durable custody signals --state DIR [--generation N]
                    live long-running writers whose loaded custody generation is older than N (default: installed)

Every command accepts --json. Exit codes: 0 ok; 1 usage or internal error; 2 definitive refusal (conflict, stale
revision, not found, invalid); 3 service stopped, starting or failed (for answer: whether the decision was recorded is
unconfirmed, so resend the same --response-id or read 'sq-durable receipt'); 4 protocol major version mismatch.
custody: 0 allowed; 3 refused, with the refusal message on stderr; 1 usage or an inventory violation.

Laboratory stores only (init --lab): SQ_DURABLE_LAB_FAULT=<point>[@n],... makes the service SIGKILL itself at named
points; SQ_DURABLE_LAB_HOLD=resume keeps it alive without resume().`;

const REFUSALS = new Set(["conflict", "stale_revision", "not_found", "invalid", "action_mismatch", "closed", "unknown_command", "bad_request"]);
const UNAVAILABLE = new Set(["not_ready", "failed"]);

type Flags = Record<string, string | boolean | undefined>;

function exitCodeFor(response: Response): number {
	if (response.ok) return 0;
	if (response.code === "protocol_mismatch") return 4;
	if (UNAVAILABLE.has(response.code)) return 3;
	if (REFUSALS.has(response.code)) return 2;
	return 1;
}

function print(flags: Flags, value: unknown, human?: string): void {
	if (flags.json === true || human === undefined) process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
	else process.stdout.write(`${human}\n`);
}

function required(flags: Flags, name: string): string {
	const value = flags[name];
	if (typeof value !== "string" || value === "") throw new UsageError(`--${name} is required`);
	return value;
}

function numberFlag(flags: Flags, name: string, fallback: number, minimum: number): number {
	const raw = flags[name];
	if (raw === undefined) return fallback;
	const value = typeof raw === "string" && raw.trim() !== "" ? Number(raw) : Number.NaN;
	if (!Number.isFinite(value) || value < minimum) throw new UsageError(`--${name} must be a number of at least ${minimum}`);
	return value;
}

class UsageError extends Error {}

function socketOf(flags: Flags): string {
	return resolveStore(required(flags, "store")).socket;
}

async function call(flags: Flags, command: string, args: Record<string, unknown> = {}): Promise<number> {
	let response: Response;
	try {
		response = await callSocket(socketOf(flags), command, args, typeof flags.protocol === "string" ? { protocol: flags.protocol } : {});
	} catch (error) {
		if (error instanceof ServiceUnavailable) {
			process.stderr.write(`${error.message}\n`);
			return 3;
		}
		throw error;
	}
	if (response.ok) print(flags, response.result);
	else {
		print(flags, response);
		process.stderr.write(`refused (${response.code}): ${response.message}\n`);
	}
	return exitCodeFor(response);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function ready(flags: Flags): Promise<number> {
	const socket = socketOf(flags);
	const waitMs = numberFlag(flags, "wait", 0, 0) * 1000;
	const deadline = Date.now() + waitMs;
	let last: unknown = { state: "stopped", reasons: ["no service answers on the socket"] };
	for (;;) {
		try {
			const response = await callSocket(socket, "ready", {}, { timeoutMs: 3_000 });
			if (!response.ok) {
				print(flags, response);
				return exitCodeFor(response);
			}
			last = response.result;
			if ((response.result as { state: string }).state === "ready") {
				print(flags, last);
				return 0;
			}
		} catch (error) {
			if (!(error instanceof ServiceUnavailable)) throw error;
			last = { state: "stopped", reasons: [error.message] };
		}
		if (Date.now() >= deadline) break;
		await sleep(100);
	}
	print(flags, last);
	return 3;
}

/**
 * Resend the same answer, with the same responseId, until the service returns a receipt or a definitive refusal. A
 * service that is stopped or not ready only means the recording is unconfirmed: the decision may have been committed
 * just before the service died. The resend is harmless because the first recorded decision wins and a repeat returns its
 * receipt.
 */
async function answer(flags: Flags): Promise<number> {
	const socket = socketOf(flags);
	const args = {
		approvalId: required(flags, "approval"),
		revision: required(flags, "revision"),
		decision: required(flags, "decision"),
		responseId: typeof flags["response-id"] === "string" ? flags["response-id"] : `term-${randomUUID()}`,
		origin: terminalOrigin(safeUser()),
		...(typeof flags["action-digest"] === "string" ? { actionDigest: flags["action-digest"] } : {}),
	};
	const deadline = Date.now() + numberFlag(flags, "timeout", 15, 0) * 1000;
	let reason = "";
	for (;;) {
		try {
			const response = await callSocket(socket, "answer", args, { timeoutMs: 5_000 });
			if (response.ok || !UNAVAILABLE.has(response.code)) {
				if (response.ok) print(flags, response.result);
				else {
					print(flags, response);
					process.stderr.write(`refused (${response.code}): ${response.message}\n`);
				}
				return exitCodeFor(response);
			}
			reason = response.message;
		} catch (error) {
			if (!(error instanceof ServiceUnavailable)) throw error;
			reason = error.message;
		}
		if (Date.now() >= deadline) break;
		process.stderr.write(`answer not confirmed yet (${reason}); resending responseId ${args.responseId}\n`);
		await sleep(250);
	}
	print(flags, { confirmed: false, responseId: args.responseId, reason });
	process.stderr.write(`answer not confirmed: ${reason}; the decision may still be recorded, resend responseId ${args.responseId} or read \`sq-durable receipt\`\n`);
	return 3;
}

function integerFlag(flags: Flags, name: string): number | undefined {
	const raw = flags[name];
	if (raw === undefined) return undefined;
	if (typeof raw !== "string" || !/^[0-9]+$/.test(raw)) throw new UsageError(`--${name} must be a non-negative integer`);
	return Number(raw);
}

function printDecision(flags: Flags, decision: CustodyDecision, source: string): number {
	if (flags.json === true) process.stdout.write(`${JSON.stringify({ ...decision, source }, null, 2)}\n`);
	if (decision.allowed) return 0;
	process.stderr.write(`${decision.message}\n`);
	return CUSTODY_REFUSAL_EXIT;
}

/**
 * Ask the service of the store first, so every check of a durable mission reaches the engine's side; fall back to the
 * decision from the ID and its table alone when no service answers. That fallback is the same decision, except that it
 * can never confirm a condition, so a conditioned responsibility is refused.
 */
async function custodyCheck(flags: Flags): Promise<number> {
	const query = {
		id: required(flags, "mission"),
		responsibilities: required(flags, "responsibility")
			.split(",")
			.map((r) => r.trim())
			.filter((r) => r !== ""),
		...(integerFlag(flags, "loaded-generation") === undefined ? {} : { loadedGeneration: integerFlag(flags, "loaded-generation") as number }),
	};
	let reason = "no store was named";
	const store = typeof flags.store === "string" && flags.store !== "" ? flags.store : process.env.SQ_DURABLE_STORE;
	if (store !== undefined && store !== "") {
		let socket: string | undefined;
		try {
			socket = resolveStore(store).socket;
		} catch (error) {
			reason = error instanceof Error ? error.message : String(error);
		}
		if (socket !== undefined) {
			try {
				const response = await callSocket(socket, "custody", { missionId: query.id, responsibilities: query.responsibilities, ...(query.loadedGeneration === undefined ? {} : { loadedGeneration: query.loadedGeneration }) }, { timeoutMs: 5_000 });
				if (response.ok) return printDecision(flags, response.result as CustodyDecision, "service");
				process.stderr.write(`refused: the durable service did not answer the custody check of mission ${query.id} (${response.code}: ${response.message})\n`);
				return CUSTODY_REFUSAL_EXIT;
			} catch (error) {
				if (!(error instanceof ServiceUnavailable)) throw error;
				reason = error.message;
			}
		}
	}
	return printDecision(flags, decideCustody(query, squadCustodyScheme(), { state: "stopped", reason }), "local");
}

function readSignals(dir: string): GenerationSignal[] {
	if (!existsSync(dir)) return [];
	const signals: GenerationSignal[] = [];
	for (const name of readdirSync(dir)) {
		const match = /^\.custody-signal-([A-Za-z0-9._-]+)$/.exec(name);
		if (match === null) continue;
		const fields = new Map<string, string>();
		for (const line of readFileSync(join(dir, name), "utf8").split("\n")) {
			const eq = line.indexOf("=");
			if (eq > 0) fields.set(line.slice(0, eq), line.slice(eq + 1));
		}
		const pid = Number(fields.get("pid"));
		const generation = Number(fields.get("generation"));
		if (!Number.isSafeInteger(pid) || pid <= 0 || !Number.isSafeInteger(generation)) continue;
		try {
			process.kill(pid, 0);
		} catch (error) {
			// ESRCH: the writer is gone and its signal is history. EPERM: alive under another user, still a writer.
			if ((error as NodeJS.ErrnoException).code === "ESRCH") continue;
		}
		signals.push({ name: match[1] as string, pid, generation });
	}
	return signals;
}

async function custody(flags: Flags, sub: string | undefined): Promise<number> {
	switch (sub) {
		case "check":
			return custodyCheck(flags);
		case "tables": {
			const tables = CUSTODY_TABLES.map((table) => ({ ...table, digest: tableDigest(table), pinned: CUSTODY_TABLE_DIGESTS[table.generation] ?? null }));
			print(flags, { installed: INSTALLED_CUSTODY_GENERATION, tables });
			return 0;
		}
		case "inventory": {
			const repo = required(flags, "repo");
			const violations = inventoryViolations(repo);
			const scanned = scanLegacyWriters(repo).map((writer) => ({ path: writer.path, lines: writer.hits.map((hit) => `${hit.line} ${hit.signature}`) }));
			print(flags, { writers: LEGACY_WRITERS, scanned, violations });
			for (const violation of violations) process.stderr.write(`inventory violation: ${violation}\n`);
			return violations.length === 0 ? 0 : 1;
		}
		case "signals": {
			const generation = integerFlag(flags, "generation") ?? INSTALLED_CUSTODY_GENERATION;
			const live = readSignals(required(flags, "state"));
			const stale = staleWriters(live, generation);
			print(flags, { generation, live, stale });
			if (stale.length === 0) return 0;
			process.stderr.write(
				`refused: admission of custody generation ${generation} must wait for ${stale.map((s) => `${s.name} (pid ${s.pid}, loaded generation ${s.generation})`).join(", ")} to restart\n`,
			);
			return CUSTODY_REFUSAL_EXIT;
		}
		default:
			throw new UsageError("usage: sq-durable custody check|tables|inventory|signals ...");
	}
}

function safeUser(): string | undefined {
	try {
		return userInfo().username;
	} catch {
		return undefined;
	}
}

async function main(argv: string[]): Promise<number> {
	const { values, positionals } = parseArgs({
		args: argv,
		allowPositionals: true,
		strict: true,
		options: {
			store: { type: "string" },
			lab: { type: "boolean" },
			"poll-ms": { type: "string" },
			wait: { type: "string" },
			json: { type: "boolean" },
			mission: { type: "string" },
			action: { type: "string" },
			args: { type: "string" },
			revision: { type: "string" },
			approval: { type: "string" },
			decision: { type: "string" },
			"response-id": { type: "string" },
			"action-digest": { type: "string" },
			timeout: { type: "string" },
			command: { type: "string" },
			protocol: { type: "string" },
			responsibility: { type: "string" },
			"loaded-generation": { type: "string" },
			repo: { type: "string" },
			state: { type: "string" },
			generation: { type: "string" },
			help: { type: "boolean", short: "h" },
		},
	});
	const flags = values as Flags;
	const [command, sub] = positionals;
	if (flags.help === true || command === undefined || command === "help") {
		process.stdout.write(`${USAGE}\n`);
		return command === undefined && flags.help !== true ? 1 : 0;
	}
	switch (command) {
		case "init": {
			const { initStore } = await import("./service/main.js");
			const result = await initStore(required(flags, "store"), { lab: flags.lab === true });
			print(flags, result, `initialized store ${result.dir} (storeId ${result.storeId}${result.lab ? ", laboratory" : ""})`);
			return 0;
		}
		case "serve": {
			const { runService, StartRefused } = await import("./service/main.js");
			const pollMs = numberFlag(flags, "poll-ms", 1_000, 50);
			if (!Number.isInteger(pollMs)) throw new UsageError("--poll-ms must be an integer of at least 50");
			try {
				await runService({ storeDir: required(flags, "store"), pollMs, env: process.env });
			} catch (error) {
				if (error instanceof StartRefused) {
					process.stderr.write(`${JSON.stringify({ ts: Date.now(), pid: process.pid, event: "start_refused", reason: error.message })}\n`);
					return 2;
				}
				throw error;
			}
			return -1; // keep running
		}
		case "ready":
			return ready(flags);
		case "admit": {
			let actionArgs: unknown = {};
			if (typeof flags.args === "string") {
				try {
					actionArgs = JSON.parse(flags.args);
				} catch {
					throw new UsageError("--args must be a JSON object");
				}
			}
			return call(flags, "admit", {
				missionId: required(flags, "mission"),
				action: { name: required(flags, "action"), args: actionArgs },
				revision: required(flags, "revision"),
			});
		}
		case "approvals":
			if (sub !== "pending") throw new UsageError("usage: sq-durable approvals pending --store DIR");
			return call(flags, "pending");
		case "answer":
			return answer(flags);
		case "receipt":
			return call(flags, "receipt", { approvalId: required(flags, "approval") });
		case "mission":
			return call(flags, "mission", { missionId: required(flags, "mission") });
		case "stats":
			return call(flags, "stats");
		case "ledger": {
			const path = storePaths(resolveStore(required(flags, "store")).dir).ledger;
			print(flags, { path, ...readLedger(path) });
			return 0;
		}
		case "custody":
			return custody(flags, sub);
		case "call": {
			let callArgs: Record<string, unknown> = {};
			if (typeof flags.args === "string") callArgs = JSON.parse(flags.args) as Record<string, unknown>;
			return call(flags, required(flags, "command"), callArgs);
		}
		default:
			throw new UsageError(`unknown command ${command}`);
	}
}

main(process.argv.slice(2)).then(
	(code) => {
		if (code >= 0) process.exitCode = code;
	},
	(error: unknown) => {
		process.stderr.write(`${error instanceof UsageError ? `usage: ${error.message}` : error instanceof Error ? error.message : String(error)}\n`);
		process.exitCode = 1;
	},
);
