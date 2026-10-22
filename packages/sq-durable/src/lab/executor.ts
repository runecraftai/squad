import { closeSync, existsSync, fsyncSync, openSync, readFileSync, renameSync, writeSync } from "node:fs";
import { dirname } from "node:path";
import { digestOf, type EffectRequest, type Executor, type ExternalReceipt, type LookupResult } from "../core/index.js";

/**
 * Controlled laboratory executor. Its "external world" is one JSON ledger file, separate from the durable store, with
 * its own independent counters. It performs no network effect and spawns nothing.
 *
 * Counters, kept apart on purpose so a reader can tell a continuation from a restart:
 * - `invocations`: times the gate entered the executor for an effect (one lookup per attempt);
 * - `applyCalls`: apply requests received, including repeats of an applied key;
 * - `distinctKeys`: distinct effect keys ever seen by apply;
 * - `appliedEffects`: effects actually applied (at most one per key);
 * - `receipts`: distinct receipts issued.
 */

export type LedgerCounters = {
	invocations: number;
	applyCalls: number;
	distinctKeys: number;
	appliedEffects: number;
	receipts: number;
};

export type LedgerEffect = { receipt: ExternalReceipt; applyCalls: number; lookups: number };

export type Ledger = { version: 1; counters: LedgerCounters; effects: Record<string, LedgerEffect> };

export const LAB_TARGET = "lab-ledger";

export function emptyLedger(): Ledger {
	return {
		version: 1,
		counters: { invocations: 0, applyCalls: 0, distinctKeys: 0, appliedEffects: 0, receipts: 0 },
		effects: {},
	};
}

/** Read the ledger; a missing file is an empty ledger, an unreadable one throws. */
export function readLedger(path: string): Ledger {
	if (!existsSync(path)) return emptyLedger();
	const parsed = JSON.parse(readFileSync(path, "utf8")) as Ledger;
	if (parsed.version !== 1 || typeof parsed.counters !== "object" || typeof parsed.effects !== "object") {
		throw new Error(`ledger ${path} has an unknown shape`);
	}
	return parsed;
}

/** Replace the ledger atomically and durably: write a temporary file, fsync it, rename over, fsync the directory. */
export function writeLedger(path: string, ledger: Ledger): void {
	const temporary = `${path}.tmp-${process.pid}`;
	const fd = openSync(temporary, "w", 0o600);
	try {
		writeSync(fd, `${JSON.stringify(ledger, null, 2)}\n`);
		fsyncSync(fd);
	} finally {
		closeSync(fd);
	}
	renameSync(temporary, path);
	const directory = openSync(dirname(path), "r");
	try {
		fsyncSync(directory);
	} finally {
		closeSync(directory);
	}
}

/** The receipt ID is derived from the key, so the same key can only ever have one receipt. */
export function receiptIdFor(effectKey: string): string {
	return `ext-${digestOf({ target: LAB_TARGET, effectKey }).slice(0, 24)}`;
}

export class LabLedgerExecutor implements Executor {
	readonly name = "lab-ledger";
	readonly #path: string;
	readonly #now: () => number;

	constructor(path: string, now: () => number = Date.now) {
		this.#path = path;
		this.#now = now;
	}

	get path(): string {
		return this.#path;
	}

	async lookup(effectKey: string, signal: AbortSignal): Promise<LookupResult> {
		signal.throwIfAborted();
		let ledger: Ledger;
		try {
			ledger = readLedger(this.#path);
		} catch (error) {
			return { status: "ambiguous", reason: `ledger unreadable: ${error instanceof Error ? error.message : String(error)}` };
		}
		ledger.counters.invocations += 1;
		const known = ledger.effects[effectKey];
		if (known !== undefined) known.lookups += 1;
		writeLedger(this.#path, ledger);
		return known === undefined ? { status: "absent" } : { status: "applied", receipt: known.receipt };
	}

	async apply(request: EffectRequest, signal: AbortSignal): Promise<ExternalReceipt> {
		signal.throwIfAborted();
		const ledger = readLedger(this.#path);
		ledger.counters.applyCalls += 1;
		const known = ledger.effects[request.effectKey];
		if (known !== undefined) {
			known.applyCalls += 1;
			writeLedger(this.#path, ledger);
			return known.receipt;
		}
		const receipt: ExternalReceipt = {
			receiptId: receiptIdFor(request.effectKey),
			effectKey: request.effectKey,
			payloadDigest: request.payloadDigest,
			target: LAB_TARGET,
			appliedAt: this.#now(),
		};
		ledger.effects[request.effectKey] = { receipt, applyCalls: 1, lookups: 0 };
		ledger.counters.distinctKeys += 1;
		ledger.counters.appliedEffects += 1;
		ledger.counters.receipts += 1;
		writeLedger(this.#path, ledger);
		return receipt;
	}
}
