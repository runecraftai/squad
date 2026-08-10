import type {
  EffectivePaceSummary,
  EffectiveRunway,
  QuotaPace,
  QuotaPaceReason,
  QuotaWindow,
} from "./types.js";

/** Reserve within this many percentage points of zero is treated as on_pace. */
export const PACE_ON_PACE_DEADBAND_PERCENT_POINTS = 1;

/**
 * Linear exhaustion projections before this much of the cycle has elapsed are
 * labeled `early` rather than `established`.
 */
export const PACE_EARLY_ELAPSED_PERCENT = 10;

type PaceOptions = {
  stale?: boolean;
};

type ResolvedCycle = {
  cycleSeconds: number;
  startsAtMs: number;
  resetsAtMs: number;
  cycleBasis: NonNullable<QuotaPace["cycleBasis"]>;
};

export function computeWindowPace(
  window: QuotaWindow,
  generatedAt: string,
  options: PaceOptions = {},
): QuotaPace {
  if (options.stale) return unknownPace("stale");

  const generatedAtMs = Date.parse(generatedAt);
  if (!Number.isFinite(generatedAtMs)) return unknownPace("invalid_cycle");

  const percentRemaining = finiteNumber(window.percentRemaining);
  const percentUsed = resolvePercentUsed(window, percentRemaining);
  if (percentRemaining === undefined || percentUsed === undefined) {
    return unknownPace("missing_usage");
  }

  const cycle = resolveCycle(window, generatedAtMs);
  if (!cycle.ok) return unknownPace(cycle.reason);

  const { cycleSeconds, startsAtMs, resetsAtMs, cycleBasis } = cycle.value;
  const remainingMs = resetsAtMs - generatedAtMs;
  const elapsedMs = generatedAtMs - startsAtMs;
  const timeRemainingPercent = (100 * remainingMs) / (cycleSeconds * 1000);
  const elapsedPercent = (100 * elapsedMs) / (cycleSeconds * 1000);
  const reservePercentPoints = percentRemaining - timeRemainingPercent;
  const status = classifyPace(reservePercentPoints);

  const pace: QuotaPace = {
    status,
    timeRemainingPercent: roundPace(timeRemainingPercent),
    elapsedPercent: roundPace(elapsedPercent),
    reservePercentPoints: roundPace(reservePercentPoints),
    cycleBasis,
    cycleSeconds,
  };

  if (elapsedPercent > 0) {
    pace.burnMultiple = roundPace(percentUsed / elapsedPercent);
  }

  if (percentUsed > 0 && elapsedMs > 0) {
    const remainingBudget = percentRemaining;
    const burnPerMs = percentUsed / elapsedMs;
    if (burnPerMs > 0 && remainingBudget >= 0) {
      const msToExhaust = remainingBudget / burnPerMs;
      const projectedExhaustedAtMs = generatedAtMs + msToExhaust;
      if (isRepresentableDateMs(projectedExhaustedAtMs)) {
        pace.projectedExhaustedAt = new Date(
          projectedExhaustedAtMs,
        ).toISOString();
        pace.projectionConfidence =
          elapsedPercent < PACE_EARLY_ELAPSED_PERCENT ? "early" : "established";
        pace.projectionBasis = "cycle_average";
      }
    }
  }

  return pace;
}

export function computeEffectiveRunway(
  windows: QuotaWindow[],
  generatedAt: string,
): EffectiveRunway {
  const exhausted = windows.find(
    (window) => finiteNumber(window.percentRemaining) === 0,
  );
  const generatedAtMs = Date.parse(generatedAt);

  if (exhausted) {
    return {
      status: "exhausted_now",
      usableRunwaySeconds: 0,
      limitingWindowId: exhausted.id,
      ...(isRepresentableDateMs(generatedAtMs)
        ? { projectedExhaustedAt: new Date(generatedAtMs).toISOString() }
        : {}),
    };
  }

  if (windows.length === 0 || !isRepresentableDateMs(generatedAtMs)) {
    return unknownRunway(windows);
  }

  const unmeasurableWindowIds: string[] = [];
  const projections: Array<{
    window: QuotaWindow;
    exhaustedAtMs: number;
  }> = [];
  let lowestConfidence: EffectiveRunway["projectionConfidence"] = "established";

  for (const window of windows) {
    const remaining = finiteNumber(window.percentRemaining);
    const pace = window.pace;
    const resetsAt = resolveResetsAtOutcome(window.resetsAt);

    if (resetsAt.kind === "missing") {
      // A missing resetsAt is non-bounding only when it also reports no
      // usage (100% remaining, 0% used) - e.g. a Claude five_hour window
      // before its first request this window. That shape's countdown has
      // simply not started yet, so it does not block the aggregate. A
      // missing resetsAt paired with any other usage shape (unknown usage,
      // or nonzero usage without an active clock) is a real data gap, not
      // "not yet triggered", and still fails closed.
      if (remaining !== undefined && isZeroUse(window, remaining)) {
        continue;
      }
      unmeasurableWindowIds.push(window.id);
      continue;
    }

    if (
      remaining === undefined ||
      remaining < 0 ||
      remaining > 100 ||
      pace === undefined ||
      pace.status === "unknown" ||
      resetsAt.kind === "malformed" ||
      resetsAt.ms <= generatedAtMs
    ) {
      unmeasurableWindowIds.push(window.id);
      continue;
    }
    const resetsAtMs = resetsAt.ms;

    if (isZeroUse(window, remaining)) {
      if ((pace.elapsedPercent ?? 0) < PACE_EARLY_ELAPSED_PERCENT) {
        lowestConfidence = "early";
      }
      continue;
    }

    const exhaustedAtMs = parseTimestamp(pace?.projectedExhaustedAt);
    if (
      exhaustedAtMs === undefined ||
      exhaustedAtMs <= generatedAtMs ||
      pace?.projectionConfidence === undefined ||
      pace.projectionBasis !== "cycle_average"
    ) {
      unmeasurableWindowIds.push(window.id);
      continue;
    }
    if (pace.projectionConfidence === "early") lowestConfidence = "early";
    if (exhaustedAtMs < resetsAtMs) {
      projections.push({ window, exhaustedAtMs });
    }
  }

  if (unmeasurableWindowIds.length > 0) {
    return { status: "unknown", unmeasurableWindowIds };
  }

  if (projections.length === 0) {
    return {
      status: "through_reset",
      projectionConfidence: lowestConfidence,
      projectionBasis: "cycle_average",
    };
  }

  const limiting = projections.reduce((earliest, candidate) =>
    candidate.exhaustedAtMs < earliest.exhaustedAtMs ? candidate : earliest,
  );
  return {
    status: "projected_exhaustion",
    usableRunwaySeconds: Math.max(
      0,
      Math.round((limiting.exhaustedAtMs - generatedAtMs) / 1000),
    ),
    projectedExhaustedAt: new Date(limiting.exhaustedAtMs).toISOString(),
    limitingWindowId: limiting.window.id,
    projectionConfidence: limiting.window.pace?.projectionConfidence,
    projectionBasis: "cycle_average",
  };
}

export function summarizeEffectivePace(
  windows: QuotaWindow[],
): EffectivePaceSummary {
  const aheadWindowIds: string[] = [];
  const behindWindowIds: string[] = [];
  const onPaceWindowIds: string[] = [];
  const unknownWindowIds: string[] = [];
  let worstReservePercentPoints: number | undefined;
  let worstReserveWindowId: string | undefined;

  for (const window of windows) {
    const pace = window.pace;
    switch (pace?.status) {
      case "ahead":
        aheadWindowIds.push(window.id);
        break;
      case "behind":
        behindWindowIds.push(window.id);
        break;
      case "on_pace":
        onPaceWindowIds.push(window.id);
        break;
      default:
        unknownWindowIds.push(window.id);
        break;
    }

    const reserve = pace?.reservePercentPoints;
    if (reserve === undefined) continue;
    if (
      worstReservePercentPoints === undefined ||
      reserve < worstReservePercentPoints
    ) {
      worstReservePercentPoints = reserve;
      worstReserveWindowId = window.id;
    }
  }

  const summary: EffectivePaceSummary = {
    status: aggregatePaceStatus({
      ahead: aheadWindowIds.length,
      behind: behindWindowIds.length,
      onPace: onPaceWindowIds.length,
      unknown: unknownWindowIds.length,
    }),
  };
  if (aheadWindowIds.length > 0) summary.aheadWindowIds = aheadWindowIds;
  if (behindWindowIds.length > 0) summary.behindWindowIds = behindWindowIds;
  if (onPaceWindowIds.length > 0) summary.onPaceWindowIds = onPaceWindowIds;
  if (unknownWindowIds.length > 0) summary.unknownWindowIds = unknownWindowIds;
  if (
    worstReservePercentPoints !== undefined &&
    worstReserveWindowId !== undefined
  ) {
    summary.worstReservePercentPoints = worstReservePercentPoints;
    summary.worstReserveWindowId = worstReserveWindowId;
  }
  return summary;
}

function unknownRunway(windows: QuotaWindow[]): EffectiveRunway {
  return {
    status: "unknown",
    ...(windows.length > 0
      ? { unmeasurableWindowIds: windows.map(({ id }) => id) }
      : {}),
  };
}

function isZeroUse(window: QuotaWindow, percentRemaining: number): boolean {
  const percentUsed = finiteNumber(window.percentUsed);
  return (
    percentRemaining === 100 && (percentUsed === undefined || percentUsed === 0)
  );
}

function resolveCycle(
  window: QuotaWindow,
  generatedAtMs: number,
): { ok: true; value: ResolvedCycle } | { ok: false; reason: QuotaPaceReason } {
  const resetsAtMs = parseTimestamp(window.resetsAt);
  if (resetsAtMs === undefined) return { ok: false, reason: "missing_cycle" };
  if (resetsAtMs <= generatedAtMs)
    return { ok: false, reason: "expired_reset" };

  const startsAtMs = parseTimestamp(window.startsAt);
  if (startsAtMs !== undefined) {
    if (startsAtMs >= resetsAtMs) return { ok: false, reason: "invalid_cycle" };
    if (startsAtMs > generatedAtMs)
      return { ok: false, reason: "future_cycle_start" };
    const cycleSeconds = (resetsAtMs - startsAtMs) / 1000;
    if (!(cycleSeconds > 0) || !Number.isFinite(cycleSeconds)) {
      return { ok: false, reason: "invalid_cycle" };
    }
    return {
      ok: true,
      value: {
        cycleSeconds,
        startsAtMs,
        resetsAtMs,
        cycleBasis: "starts_at_resets_at",
      },
    };
  }

  const windowSeconds = finiteNumber(window.windowSeconds);
  if (windowSeconds === undefined)
    return { ok: false, reason: "missing_cycle" };
  if (!(windowSeconds > 0)) return { ok: false, reason: "invalid_cycle" };

  const cycleDurationMs = windowSeconds * 1000;
  if (!Number.isFinite(cycleDurationMs)) {
    return { ok: false, reason: "invalid_cycle" };
  }
  const impliedStartsAtMs = resetsAtMs - cycleDurationMs;
  if (!isRepresentableDateMs(impliedStartsAtMs)) {
    return { ok: false, reason: "invalid_cycle" };
  }
  if (impliedStartsAtMs > generatedAtMs) {
    return { ok: false, reason: "future_cycle_start" };
  }
  return {
    ok: true,
    value: {
      cycleSeconds: windowSeconds,
      startsAtMs: impliedStartsAtMs,
      resetsAtMs,
      cycleBasis: "window_seconds",
    },
  };
}

function classifyPace(
  reservePercentPoints: number,
): Exclude<QuotaPace["status"], "unknown"> {
  if (Math.abs(reservePercentPoints) <= PACE_ON_PACE_DEADBAND_PERCENT_POINTS) {
    return "on_pace";
  }
  return reservePercentPoints < 0 ? "ahead" : "behind";
}

function aggregatePaceStatus(counts: {
  ahead: number;
  behind: number;
  onPace: number;
  unknown: number;
}): EffectivePaceSummary["status"] {
  const known = counts.ahead + counts.behind + counts.onPace;
  if (known === 0) return "unknown";
  if (counts.ahead > 0 && counts.behind > 0) return "mixed";
  if (counts.ahead > 0) return "ahead";
  if (counts.behind > 0) return "behind";
  return "on_pace";
}

function resolvePercentUsed(
  window: QuotaWindow,
  percentRemaining: number | undefined,
): number | undefined {
  const explicit = finiteNumber(window.percentUsed);
  if (explicit !== undefined) return explicit;
  if (percentRemaining === undefined) return undefined;
  return 100 - percentRemaining;
}

function unknownPace(reason: QuotaPaceReason): QuotaPace {
  return { status: "unknown", reason };
}

function parseTimestamp(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : undefined;
}

type ResetsAtOutcome =
  | { kind: "missing" }
  | { kind: "malformed" }
  | { kind: "ok"; ms: number };

/**
 * Distinguishes a genuinely absent `resetsAt` (the cycle has not been
 * triggered yet) from a present-but-unparseable one (a real data defect that
 * claims a reset it cannot honor). Effective runway treats only the former
 * as non-bounding.
 */
function resolveResetsAtOutcome(value: string | undefined): ResetsAtOutcome {
  if (!value) return { kind: "missing" };
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? { kind: "ok", ms } : { kind: "malformed" };
}

function finiteNumber(value: number | undefined): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function isRepresentableDateMs(value: number): boolean {
  return Number.isFinite(value) && !Number.isNaN(new Date(value).getTime());
}

function roundPace(value: number): number {
  return Number(value.toFixed(4));
}
