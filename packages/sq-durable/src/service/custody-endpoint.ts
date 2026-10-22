import {
	type CustodyDecision,
	type CustodyQuery,
	type CustodyServiceView,
	decideCustody,
	type MissionDocument,
	missionCustodyView,
	needsService,
} from "../core/index.js";
import { squadCustodyScheme } from "../adapter/legacy-writers.js";
import type { ServiceState } from "./readiness.js";

/**
 * Service side of custody: the check legacy writers reach over the store's socket, so none of them ever opens the
 * storage. The static part of the decision (ID, generation table, loaded generation) is the same one `sq-durable custody
 * check` computes without a service; the service adds only what the engine alone can confirm, the state of the mission
 * a conditioned responsibility depends on, and only while it is ready or degraded.
 */

export type CustodyArgs = { readonly query: CustodyQuery } | { readonly error: string };

/** Validate the socket arguments of a `custody` request. */
export function parseCustodyArgs(args: Record<string, unknown>): CustodyArgs {
	const id = args.missionId;
	const responsibilities = args.responsibilities;
	const loaded = args.loadedGeneration;
	if (typeof id !== "string" || id === "") return { error: "missionId must be a non-empty string" };
	if (!Array.isArray(responsibilities) || responsibilities.some((r) => typeof r !== "string" || r === "")) {
		return { error: "responsibilities must be a list of non-empty strings" };
	}
	if (loaded !== undefined && (typeof loaded !== "number" || !Number.isSafeInteger(loaded) || loaded < 0)) {
		return { error: "loadedGeneration must be a non-negative integer" };
	}
	return {
		query: {
			id,
			responsibilities: responsibilities as string[],
			...(loaded === undefined ? {} : { loadedGeneration: loaded as number }),
		},
	};
}

export type CustodyEndpointDeps = {
	/** Readiness of this service right now. */
	readonly state: () => Promise<{ state: ServiceState; reasons: readonly string[] }>;
	/** Current mission document, read from the engine; undefined when none was admitted under that ID. */
	readonly mission: (missionId: string) => Promise<MissionDocument | undefined>;
};

export async function custodyDecision(query: CustodyQuery, deps: CustodyEndpointDeps): Promise<CustodyDecision> {
	const scheme = squadCustodyScheme();
	if (!needsService(query, scheme)) return decideCustody(query, scheme, { state: "stopped" });
	const readiness = await deps.state();
	const view: CustodyServiceView =
		readiness.state === "ready" || readiness.state === "degraded"
			? { state: readiness.state, mission: missionCustodyView(await deps.mission(query.id)) }
			: { state: readiness.state, reason: readiness.reasons.join("; ") || readiness.state };
	return decideCustody(query, scheme, view);
}
