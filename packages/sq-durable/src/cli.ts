#!/usr/bin/env -S node --disable-warning=ExperimentalWarning
import { randomUUID } from "node:crypto";
import { userInfo } from "node:os";
import { parseArgs } from "node:util";
import { terminalOrigin } from "./adapter/squad.js";
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

Every command accepts --json. Exit codes: 0 ok; 1 usage or internal error; 2 definitive refusal (conflict, stale
revision, not found, invalid); 3 service stopped, starting or failed (for answer: whether the decision was recorded is
unconfirmed, so resend the same --response-id or read 'sq-durable receipt'); 4 protocol major version mismatch.

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
