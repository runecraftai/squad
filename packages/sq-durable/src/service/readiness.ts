/**
 * Service readiness. A live PID or an open socket never means ready: ready requires `resume()` done, the Session open,
 * a read on the mutation line answered within its deadline, and no decided approval left without continuation for
 * more than two poll intervals.
 */

export type ServiceState = "stopped" | "starting" | "ready" | "degraded" | "failed";

/** Lifecycle phase the service has reached in its startup order. */
export type Phase = "locking" | "opening" | "opened" | "resumed" | "failed";

export type ReadinessInput = {
	readonly phase: Phase;
	readonly failure?: string;
	/** Scheduling as reported by the engine; must be `running`, which only `resume()` turns on. */
	readonly scheduling?: "paused" | "running" | "closing";
	/** Whether the mutation-line read answered within its deadline. */
	readonly lineRead?: boolean;
	readonly blocked?: readonly string[];
	readonly parked?: readonly string[];
	readonly reconcile?: readonly string[];
	/** Approvals decided without a continuation receipt for more than two intervals. */
	readonly overdue?: readonly string[];
	readonly holds?: readonly string[];
};

export type Readiness = { readonly state: ServiceState; readonly reasons: string[] };

export function classify(input: ReadinessInput): Readiness {
	if (input.phase === "failed") return { state: "failed", reasons: [input.failure ?? "service failed"] };
	if (input.phase !== "resumed") {
		const reasons = [`startup at ${input.phase}; resume() not done`];
		if (input.holds?.includes("resume")) reasons.push("laboratory hold keeps resume() from running");
		return { state: "starting", reasons };
	}
	if (input.scheduling !== "running") {
		return { state: "starting", reasons: [`engine scheduling is ${input.scheduling ?? "unknown"}, not running`] };
	}
	const reasons: string[] = [];
	if (input.lineRead !== true) reasons.push("mutation-line read did not answer within its deadline");
	for (const id of input.blocked ?? []) reasons.push(`task ${id} is blocked`);
	for (const id of input.parked ?? []) reasons.push(`task ${id} is parked by the restart limit`);
	for (const id of input.reconcile ?? []) reasons.push(`mission ${id} needs reconciliation`);
	for (const id of input.overdue ?? []) reasons.push(`approval ${id} was decided but has no continuation after two intervals`);
	return reasons.length === 0 ? { state: "ready", reasons: [] } : { state: "degraded", reasons };
}

/** Commands that write run only when the engine has resumed and has not failed. */
export function acceptsMutations(state: ServiceState): boolean {
	return state === "ready" || state === "degraded";
}
