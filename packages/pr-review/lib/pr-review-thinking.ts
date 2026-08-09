export const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;

export type ThinkingLevel = (typeof THINKING_LEVELS)[number];
export type ReviewTier = "light" | "medium" | "heavy";

const THINKING_LEVEL_SET = new Set<string>(THINKING_LEVELS);

export function normalizeThinkingLevel(value: unknown): ThinkingLevel | undefined {
	return typeof value === "string" && THINKING_LEVEL_SET.has(value) ? (value as ThinkingLevel) : undefined;
}

export function normalizeTierThinkingLevels(
	raw: unknown,
	source = "pr-review config",
): Partial<Record<ReviewTier, ThinkingLevel>> {
	if (raw === undefined) return {};
	if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
		throw new Error(`${source}.thinkingLevels must be an object keyed by light, medium, or heavy`);
	}
	const record = raw as Record<string, unknown>;
	const unknownTiers = Object.keys(record).filter((key) => !["light", "medium", "heavy"].includes(key));
	if (unknownTiers.length > 0) {
		throw new Error(`${source}.thinkingLevels has unknown tier ${JSON.stringify(unknownTiers[0])}`);
	}
	const out: Partial<Record<ReviewTier, ThinkingLevel>> = {};
	for (const tier of ["light", "medium", "heavy"] as const) {
		const value = record[tier];
		if (value === undefined) continue;
		const level = normalizeThinkingLevel(value);
		if (!level) {
			throw new Error(
				`${source}.thinkingLevels.${tier} must be one of ${THINKING_LEVELS.join("|")} (received ${JSON.stringify(value)})`,
			);
		}
		out[tier] = level;
	}
	return out;
}

/** Return only a Pi-supported explicit thinking suffix from a model spec. */
export function modelSpecThinkingLevel(spec: string | undefined): ThinkingLevel | undefined {
	if (!spec) return undefined;
	const suffix = spec.match(/:([^/:]+)$/)?.[1];
	return normalizeThinkingLevel(suffix);
}

export interface ThinkingResolution {
	level?: ThinkingLevel;
	source: "model" | "tier" | "inherited";
	shadowedTierLevel?: ThinkingLevel;
}

/** Model-spec thinking wins, then tier config, otherwise the child Pi inherits its ambient default. */
export function resolveThinkingLevel(
	modelSpec: string | undefined,
	tierLevel: ThinkingLevel | undefined,
): ThinkingResolution {
	const modelLevel = modelSpecThinkingLevel(modelSpec);
	if (modelLevel) {
		return {
			level: modelLevel,
			source: "model",
			...(tierLevel ? { shadowedTierLevel: tierLevel } : {}),
		};
	}
	if (tierLevel) return { level: tierLevel, source: "tier" };
	return { source: "inherited" };
}

/** Add an explicit CLI level only when the model spec did not already select one. */
export function appendTierThinkingArgs(
	args: string[],
	modelSpec: string | undefined,
	tierLevel: ThinkingLevel | undefined,
): string[] {
	const resolution = resolveThinkingLevel(modelSpec, tierLevel);
	if (resolution.source === "tier" && resolution.level) args.push("--thinking", resolution.level);
	return args;
}

function joinTiers(tiers: ReviewTier[]): string {
	if (tiers.length <= 1) return tiers[0] ?? "";
	if (tiers.length === 2) return `${tiers[0]} and ${tiers[1]}`;
	return `${tiers.slice(0, -1).join(", ")}, and ${tiers.at(-1)}`;
}

/** One actionable inheritance warning, without guessing the ambient Pi default. */
export function sharedThinkingInheritanceWarning(
	inherited: readonly ReviewTier[],
): string | undefined {
	if (inherited.length === 0) return undefined;
	const examples = inherited.map((tier) => `${tier}_thinking=<level>`).join(" ");
	return `WARNING: ${joinTiers([...inherited])} thinking ${inherited.length === 1 ? "is" : "are"} unset, so ${inherited.length === 1 ? "this child Pi process inherits" : "these child Pi processes inherit"} the ambient Pi default. Set it explicitly with /pr-review-config ${examples}.`;
}

export interface ThinkingShadow {
	tier: ReviewTier;
	modelSpec: string;
	tierLevel: ThinkingLevel;
	modelLevel: ThinkingLevel;
}

/** One warning for every supplied model spec whose suffix shadows configured tier thinking. */
export function thinkingShadowingWarning(shadows: readonly ThinkingShadow[]): string | undefined {
	if (shadows.length === 0) return undefined;
	const details = shadows
		.map(
			({ tier, modelSpec, tierLevel, modelLevel }) =>
			`${tier} model ${modelSpec} selects ${modelLevel} instead of ${tier}_thinking=${tierLevel}`,
		)
		.join("; ");
	return `WARNING: Model-spec :thinking takes precedence over tier thinking: ${details}.`;
}
