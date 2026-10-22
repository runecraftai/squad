import type { MissionIdScheme } from "../core/index.js";

/**
 * Squad adapter boundary: the one module that names Squad concepts. The core takes these as plain parameters; it never
 * imports this file (see test/dependency-direction.test.ts).
 *
 * In A1 the adapter only fixes names. Backlog, instructions, harness selection, isolated copies, Drill and supervision
 * stay outside this slice and connect here in later slices.
 */

/** Namespace of the durable documents and the gate task: `sq.mission`, `sq.approval`, `sq.approval-gate`. */
export const SQUAD_NAMESPACE = "sq";

/** Reserved prefix of durable mission IDs: `dm<generation>-<slug>`. */
export const DURABLE_MISSION_PREFIX = "dm";

/** Custody generation of the laboratory slice. A1 never touches legacy scripts, so it admits only `dm1-*`. */
export const LAB_CUSTODY_GENERATION = 1;

/** Classification used by every Squad entry point: any other ID, `dm-…` or `dmz-…` included, stays legacy. */
export const DURABLE_ID_PATTERN = /^dm[0-9]+-/;

export function isDurableMissionId(id: string): boolean {
	return DURABLE_ID_PATTERN.test(id);
}

/** The only ID scheme the laboratory service admits. */
export function labMissionScheme(): MissionIdScheme {
	return { prefix: DURABLE_MISSION_PREFIX, generation: LAB_CUSTODY_GENERATION };
}

/** Origin recorded with a decision answered from the terminal: the local user of this base. */
export function terminalOrigin(user: string | undefined): string {
	return `terminal:${user && user.length > 0 ? user : "unknown"}`;
}
