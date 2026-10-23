import { digestOf, type Json } from "./canonical.js";
import type { MissionDocument, MissionStatus } from "./mission.js";

/**
 * Custody: which side may act on each responsibility of a durable mission.
 *
 * Authority is fixed by identity at birth. A durable mission ID is `<prefix><generation>-<slug>`; the generation never
 * changes, and the table published for that generation names, for every responsibility, whether the engine owns it or
 * a legacy writer keeps it, possibly only once the engine confirms a condition. Tables are immutable once published and
 * accumulate, so publishing a newer generation never changes the owner of a living mission.
 *
 * The core is neutral: responsibility names, the prefix and the tables come from the host's adapter.
 */

/** A condition the engine must confirm before a legacy writer may act. */
export type CustodyCondition = "admitted" | "terminal-reconciled";

export type CustodyOwner =
	| { readonly kind: "engine" }
	| { readonly kind: "legacy"; readonly requires?: CustodyCondition };

export type CustodyTable = {
	readonly generation: number;
	readonly owners: Readonly<Record<string, CustodyOwner>>;
};

export type CustodyScheme = {
	/** Reserved prefix: an ID matching `^<prefix>[0-9]+-` is a durable mission, any other ID stays legacy. */
	readonly prefix: string;
	/** Every published generation, never edited and never removed while a mission of that generation lives. */
	readonly tables: readonly CustodyTable[];
};

/** Exit code of a custody refusal, shared by the CLI and every legacy consultation point. */
export const CUSTODY_REFUSAL_EXIT = 3;

export type CustodyRefusalCode =
	| "engine_owned"
	| "unknown_generation"
	| "unknown_responsibility"
	| "stale_writer"
	| "library_regressed"
	| "condition_unmet";

export type CustodyDecision =
	| {
			readonly allowed: true;
			readonly id: string;
			readonly reserved: boolean;
			readonly generation: number | null;
			readonly responsibilities: readonly string[];
	  }
	| {
			readonly allowed: false;
			readonly id: string;
			readonly reserved: true;
			readonly generation: number;
			readonly responsibility: string;
			readonly code: CustodyRefusalCode;
			readonly message: string;
	  };

export type CustodyQuery = {
	readonly id: string;
	readonly responsibilities: readonly string[];
	/**
	 * Newest generation the writer loaded when it started. A long-running writer that loaded an older generation than the
	 * one installed now, or a newer one than is installed, is refused on every reserved ID.
	 */
	readonly loadedGeneration?: number;
};

/** What the engine can confirm about one mission; `stopped` and every non-mutating state confirm nothing. */
export type CustodyServiceView = {
	readonly state: "ready" | "degraded" | "starting" | "stopped" | "failed";
	readonly mission?: CustodyMissionView;
	/** Why the service could not confirm anything, when it is not ready. */
	readonly reason?: string;
};

export type CustodyMissionView = {
	readonly status: MissionStatus;
	/** No effect was attempted, or the attempted effect has a receipt. */
	readonly effectReconciled: boolean;
	/**
	 * The mission itself is blocked, parked, in reconcile or waiting on an overdue continuation. A degraded service still
	 * answers for the rest of the store, but confirms nothing about an affected mission.
	 */
	readonly affected?: boolean;
};

const TERMINAL: readonly MissionStatus[] = ["completed", "rejected", "cancelled"];

export function reservedPattern(prefix: string): RegExp {
	return new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}([0-9]+)-`);
}

/** Generation of a reserved ID, or undefined for a legacy ID. */
export function reservedGeneration(id: string, prefix: string): number | undefined {
	const match = reservedPattern(prefix).exec(id);
	if (match === null) return undefined;
	const generation = Number(match[1]);
	return Number.isSafeInteger(generation) ? generation : Number.POSITIVE_INFINITY;
}

/** Newest published generation: the custody generation a freshly started writer loads. */
export function installedGeneration(scheme: CustodyScheme): number {
	return scheme.tables.reduce((max, table) => Math.max(max, table.generation), 0);
}

export function tableFor(scheme: CustodyScheme, generation: number): CustodyTable | undefined {
	return scheme.tables.find((table) => table.generation === generation);
}

/** Content identity of a published table; an adapter pins it so a published table can never be edited. */
export function tableDigest(table: CustodyTable): string {
	return digestOf(table as unknown as Json);
}

export function missionCustodyView(mission: MissionDocument | undefined): CustodyMissionView {
	if (mission === undefined) return { status: "absent", effectReconciled: false };
	const effect = mission.effect;
	return {
		status: mission.status,
		effectReconciled: effect === null || effect.attempts === 0 || effect.receipt !== null,
	};
}

function refusal(
	id: string,
	generation: number,
	responsibility: string,
	code: CustodyRefusalCode,
	message: string,
): CustodyDecision {
	return { allowed: false, id, reserved: true, generation, responsibility, code, message };
}

/** The refusal message of an engine-owned responsibility; every consultation point prints it verbatim. */
export function engineOwnedMessage(responsibility: string, id: string, generation: number): string {
	return `refused: ${responsibility} of mission ${id} belongs to the durable core (generation ${generation})`;
}

const CONDITION_TEXT: Record<CustodyCondition, string> = {
	admitted: "admitted",
	"terminal-reconciled": "terminal with every effect reconciled",
};

function conditionMet(condition: CustodyCondition, mission: CustodyMissionView): boolean {
	if (condition === "admitted") return mission.status !== "absent" && !TERMINAL.includes(mission.status);
	return TERMINAL.includes(mission.status) && mission.effectReconciled;
}

/**
 * Decide whether a legacy writer may act on `query.responsibilities` of `query.id`. A legacy ID is always allowed and
 * costs nothing. For a durable ID the decision comes only from the ID, its generation's table and the writer's loaded
 * generation; the service view is consulted only for a condition, and a service that is stopped, starting or failed
 * never confirms one. Nothing here ever grants legacy authority from a missing file or projection.
 */
export function decideCustody(query: CustodyQuery, scheme: CustodyScheme, service: CustodyServiceView): CustodyDecision {
	const generation = reservedGeneration(query.id, scheme.prefix);
	if (generation === undefined) {
		return { allowed: true, id: query.id, reserved: false, generation: null, responsibilities: [...query.responsibilities] };
	}
	const first = query.responsibilities[0] ?? "";
	if (query.responsibilities.length === 0) {
		return refusal(query.id, generation, first, "unknown_responsibility", `refused: no responsibility named for mission ${query.id}`);
	}
	const installed = installedGeneration(scheme);
	if (query.loadedGeneration !== undefined && query.loadedGeneration < installed) {
		return refusal(
			query.id,
			generation,
			first,
			"stale_writer",
			`refused: this writer loaded custody generation ${query.loadedGeneration} but generation ${installed} is installed; restart it before it acts on mission ${query.id}`,
		);
	}
	if (query.loadedGeneration !== undefined && query.loadedGeneration > installed) {
		return refusal(
			query.id,
			generation,
			first,
			"library_regressed",
			`refused: this writer loaded custody generation ${query.loadedGeneration} but only generation ${installed} is installed; the custody library regressed, so mission ${query.id} is refused`,
		);
	}
	const table = tableFor(scheme, generation);
	if (table === undefined) {
		const known = scheme.tables.map((t) => t.generation).join(", ") || "none";
		return refusal(
			query.id,
			generation,
			first,
			"unknown_generation",
			`refused: mission ${query.id} has custody generation ${generation}, which the installed custody library does not know (known: ${known}); every responsibility is refused`,
		);
	}
	for (const responsibility of query.responsibilities) {
		const owner = Object.hasOwn(table.owners, responsibility) ? table.owners[responsibility] : undefined;
		if (owner === undefined) {
			return refusal(
				query.id,
				generation,
				responsibility,
				"unknown_responsibility",
				`refused: ${responsibility} is not a responsibility of custody generation ${generation}; mission ${query.id} is refused`,
			);
		}
		if (owner.kind === "engine") {
			return refusal(query.id, generation, responsibility, "engine_owned", engineOwnedMessage(responsibility, query.id, generation));
		}
		if (owner.requires !== undefined) {
			const affected = service.mission?.affected === true;
			const confirmable = service.state === "ready" || (service.state === "degraded" && !affected);
			if (!confirmable || service.mission === undefined || !conditionMet(owner.requires, service.mission)) {
				const detail = service.reason ? ` (${service.reason})` : "";
				const why = affected
					? `the durable service is degraded and mission ${query.id} is affected${detail}`
					: !confirmable
						? `the durable service is ${service.state}${detail}`
						: `the mission is ${service.mission?.status ?? "unknown"}${service.mission !== undefined && !service.mission.effectReconciled ? " with an unreconciled effect" : ""}`;
				return refusal(
					query.id,
					generation,
					responsibility,
					"condition_unmet",
					`refused: ${responsibility} of mission ${query.id} needs the durable core to confirm the mission is ${CONDITION_TEXT[owner.requires]} (generation ${generation}); ${why}`,
				);
			}
		}
	}
	return { allowed: true, id: query.id, reserved: true, generation, responsibilities: [...query.responsibilities] };
}

/** Whether any of the query's responsibilities needs the engine to confirm a condition. */
export function needsService(query: CustodyQuery, scheme: CustodyScheme): boolean {
	const generation = reservedGeneration(query.id, scheme.prefix);
	if (generation === undefined) return false;
	const table = tableFor(scheme, generation);
	return query.responsibilities.some((r) => {
		const owner = table !== undefined && Object.hasOwn(table.owners, r) ? table.owners[r] : undefined;
		return owner !== undefined && owner.kind === "legacy" && owner.requires !== undefined;
	});
}

/** A generation signal: what a live long-running writer loaded. */
export type GenerationSignal = { readonly name: string; readonly pid: number; readonly generation: number };

/**
 * Long-running writers whose loaded generation is older than `generation`. Admitting a mission of `generation` must wait
 * until none is left, so no live writer can act on it under a table it never loaded.
 */
export function staleWriters(signals: readonly GenerationSignal[], generation: number): GenerationSignal[] {
	return signals.filter((signal) => signal.generation < generation);
}
