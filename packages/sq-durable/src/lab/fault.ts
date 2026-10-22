import { writeSync } from "node:fs";

/**
 * Deterministic laboratory fault injection.
 *
 * `SQ_DURABLE_LAB_FAULT=<point>[@<n>][,<point>[@<n>]...]` makes the service SIGKILL itself the n-th time (default the
 * first) it reaches a named point. `SQ_DURABLE_LAB_HOLD=resume` keeps a live process from ever calling `resume()`.
 * Both are accepted only for storage that `init --lab` marked as laboratory; any other storage refuses to start with
 * them set, so a production store can never be killed or held by an environment variable.
 */

export const FAULT_ENV = "SQ_DURABLE_LAB_FAULT";
export const HOLD_ENV = "SQ_DURABLE_LAB_HOLD";

/** Points the service and the gate announce; an unknown name in the spec is refused, so typos never pass silently. */
export const FAULT_POINTS = [
	"after-lock",
	"after-open",
	"before-resume",
	"after-admit-commit",
	"after-decision-commit",
	"gate-wait",
	"effect-after-attempt",
	"effect-before-apply",
	"effect-applied-before-receipt",
] as const;

export const HOLDS = ["resume"] as const;

export type FaultInjector = {
	/** Points armed for this process, for the readiness probe and evidence. */
	readonly armed: readonly string[];
	readonly holds: readonly string[];
	checkpoint(point: string): void;
	holding(name: (typeof HOLDS)[number]): boolean;
};

export function parseFaultSpec(spec: string | undefined): Map<string, number> {
	const plan = new Map<string, number>();
	if (spec === undefined || spec.trim() === "") return plan;
	for (const raw of spec.split(",")) {
		const item = raw.trim();
		if (item === "") continue;
		const match = /^([a-z-]+)(?:@([1-9][0-9]*))?$/.exec(item);
		if (match === null) throw new Error(`${FAULT_ENV}: cannot parse ${JSON.stringify(item)}`);
		const point = match[1] as string;
		if (!(FAULT_POINTS as readonly string[]).includes(point)) {
			throw new Error(`${FAULT_ENV}: unknown fault point ${point}; known points: ${FAULT_POINTS.join(", ")}`);
		}
		plan.set(point, Number(match[2] ?? "1"));
	}
	return plan;
}

export function parseHoldSpec(spec: string | undefined): string[] {
	if (spec === undefined || spec.trim() === "") return [];
	const holds = spec.split(",").map((item) => item.trim()).filter((item) => item !== "");
	for (const hold of holds) {
		if (!(HOLDS as readonly string[]).includes(hold)) {
			throw new Error(`${HOLD_ENV}: unknown hold ${hold}; known holds: ${HOLDS.join(", ")}`);
		}
	}
	return holds;
}

const NOOP: FaultInjector = { armed: [], holds: [], checkpoint: () => {}, holding: () => false };

export function createFaultInjector(options: {
	readonly lab: boolean;
	readonly storeDir: string;
	readonly faultSpec: string | undefined;
	readonly holdSpec: string | undefined;
}): FaultInjector {
	const plan = parseFaultSpec(options.faultSpec);
	const holds = parseHoldSpec(options.holdSpec);
	if (plan.size === 0 && holds.length === 0) return NOOP;
	if (!options.lab) {
		throw new Error(
			`lab fault injection refused: store ${options.storeDir} is not marked laboratory (unset ${FAULT_ENV} and ${HOLD_ENV})`,
		);
	}
	const hits = new Map<string, number>();
	return {
		armed: [...plan.entries()].map(([point, n]) => `${point}@${n}`),
		holds,
		checkpoint(point: string): void {
			const target = plan.get(point);
			if (target === undefined) return;
			const count = (hits.get(point) ?? 0) + 1;
			hits.set(point, count);
			if (count !== target) return;
			// Synchronous write: the line must reach the log before the signal, with no buffered stream in between.
			writeSync(2, `${JSON.stringify({ ts: Date.now(), event: "lab_fault", point, hit: count, signal: "SIGKILL", pid: process.pid })}\n`);
			process.kill(process.pid, "SIGKILL");
			// Never run another line of this process: block until the signal lands.
			Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
		},
		holding(name): boolean {
			return holds.includes(name);
		},
	};
}
