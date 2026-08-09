/**
 * pi-goal-list-loop-audit — v0.1.0
 * extensions/goal-loop-backoff.ts
 *
 * Hard 5-minute ceiling on backoff. Anything beyond the ceiling pauses the
 * loop and notifies the user (TUI badge + optional push).
 *
 * Design: see docs/DESIGN.md, decision #3.
 */

export const BACKOFF_HARD_CAP_MS = 5 * 60 * 1000;
export const BACKOFF_IDLE_RETRY_MS = 50;     // when adding another iter to queue
export const BACKOFF_ERROR_BASE_MS = 5_000;  // first error retry
export const BACKOFF_ERROR_MAX_MS = 60_000;  // max error retry (separate from stuck cap)

/**
 * Return the backoff (ms) before scheduling the next iteration, based on
 * consecutive iterations that produced no meaningful progress.
 *
 * Caps at BACKOFF_HARD_CAP_MS (5 min). Beyond that, the orchestrator should
 * pause and notify the user.
 */
export function backoffMs(stuckCount: number, mode: "stuck" | "error" | "context" = "stuck"): number {
  if (mode === "error") {
    return Math.min(BACKOFF_ERROR_BASE_MS * 2 ** Math.max(0, stuckCount - 1), BACKOFF_ERROR_MAX_MS);
  }
  if (mode === "context") {
    return Math.min(30_000 * Math.max(1, stuckCount), BACKOFF_HARD_CAP_MS);
  }
  // "stuck" — the main case the user complained about.
  const schedule = [0, 30_000, 60_000, 120_000, 240_000, BACKOFF_HARD_CAP_MS];
  const idx = Math.max(0, Math.min(schedule.length - 1, stuckCount));
  return schedule[idx] ?? BACKOFF_HARD_CAP_MS;
}

/**
 * Determine whether the orchestrator should pause (vs. reschedule).
 *
 * Pause conditions:
 *   - stuck for >= 5 minutes
 *   - any single iteration has been silent (no tool call) for > N seconds
 */
export function shouldPauseAfterBackoff(stuckElapsedMs: number, idleIterCount: number): boolean {
  if (stuckElapsedMs >= BACKOFF_HARD_CAP_MS) return true;
  if (idleIterCount >= 3) return true;
  return false;
}

/**
 * Human-readable label, e.g. "5m", "30s", "1m".
 */
export function humanMs(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
  return `${Math.round(ms / 60_000)}m`;
}

// =================================================================
// Heartbeat self-watchdog (v0.5.0)
//
// Replaces the external pi-compaction-continue plugin FOR OUR LOOPS. A goal
// loop that dies silently (compaction-eaten turn, dropped message, stale ctx)
// is a hole in this plugin, not something to outsource. One precise check
// covers every stall cause: supervising + idle + nothing scheduled + quiet
// for too long → re-fire the continuation ourselves.
// =================================================================

export const HEARTBEAT_INTERVAL_MS = 15_000;
export const HEARTBEAT_STALL_MS = 60_000;
export const HEARTBEAT_MAX_NUDGES = 3;
/** v0.23.2: default wall-clock wedge threshold — a busy session with no
 * activity for this long is almost always a hung unbounded command
 * (test suite / dev server) holding the whole goal hostage. The
 * turn-based watchdogs are blind to it (it's ONE long turn); only the
 * wall clock sees it. 0 in settings = off.
 * v0.23.3: 45 → 30. The alert is notification-only, so a false positive
 * costs one notification while a false negative costs hours — that
 * asymmetry argues tight. (pi-goal-x, the cautionary tale, had NO wall
 * clock at all: a wedged session was silent forever.) */
export const WEDGE_ALERT_DEFAULT_MINUTES = 30;
/** v0.23.3: hard cap on one measure command. An unbounded measure is the
 * same wedge shape as an unbounded test suite — it freezes the loop tick
 * forever. Timeout → measure failure (null) → stall path → plateau stop,
 * never a silent hang. Matches pi-loop-mode's --check-timeout default. */
export const MEASURE_TIMEOUT_MS = 10 * 60_000;
/** v0.23.3: auditor inactivity abort. The auditor legitimately runs the
 * project's own verification (test suites!), so the bound is on
 * INACTIVITY (no session events at all), not wall time. An auditor with
 * no events for this long is wedged — abort and report an error, never
 * disapprove, never hang the completion gate forever. */
export const AUDITOR_STALL_MS = 10 * 60_000;

/** v0.26.5: pending-latch watchdog threshold. Field-observed failure: a
 * continuation sent right at compaction was ACCEPTED by pi (sendMessage
 * returned) but the turn trigger was dropped — pi's pending-message flag
 * then stayed set forever. sessionIdle (= isIdle && !hasPendingMessages)
 * never went true, so the heartbeat refire path AND the stall escalation
 * were both suppressed: 22 minutes of total silence until a manual nudge.
 * The wedge alert was blind too (22m < 30m threshold, and its "hung
 * command" framing would be wrong anyway). This watchdog owns that
 * shape: idle + pending + silent >= threshold = the latch is stuck. */
export const PENDING_LATCH_STUCK_MS = 3 * 60_000;

export interface PendingLatchInput {
  /** A goal is active (autoContinue) or a loop is running. */
  supervising: boolean;
  /** ctx.isIdle() — the session is NOT mid-turn. */
  idle: boolean;
  /** ctx.hasPendingMessages() — pi believes a message is still queued. */
  pending: boolean;
  /** A continuation or loop timer is already scheduled. */
  timerPending: boolean;
  /** Milliseconds since the last observed agent activity. */
  silentMs: number;
  /** Threshold in ms; 0 disables the watchdog. */
  thresholdMs: number;
}

/** Should the pending-latch watchdog count a stall right now? It never
 * re-sends: the message is ALREADY queued pi-side, and the hegemon
 * zombie proved re-sends don't unstick a dropped trigger (619 sends,
 * zero turns). Count + notify + escalate to a loud stop instead. */
export function shouldFirePendingLatchWatchdog(input: PendingLatchInput): boolean {
  if (!input.supervising) return false;
  if (!input.idle || !input.pending) return false;
  if (input.timerPending) return false;
  if (input.thresholdMs <= 0) return false;
  return input.silentMs >= input.thresholdMs;
}

export interface WedgeInput {
  /** A goal is active (autoContinue) or a loop is running. */
  supervising: boolean;
  /** Session is BUSY (mid-turn). An idle quiet session is the
   *  heartbeat's job, not the wedge alert's. */
  sessionBusy: boolean;
  /** Milliseconds since the last observed agent activity. */
  silentMs: number;
  /** Milliseconds since the last wedge alert fired (throttle). */
  msSinceLastAlert: number;
  /** Threshold in ms; 0 disables the alert entirely. */
  thresholdMs: number;
}

/** Should the wedge alert fire right now? Alerts at most once per
 *  threshold interval while the wedge persists; any activity re-arms. */
export function shouldWedgeAlert(input: WedgeInput): boolean {
  if (!input.supervising) return false;
  if (!input.sessionBusy) return false;
  if (input.thresholdMs <= 0) return false;
  if (input.silentMs < input.thresholdMs) return false;
  return input.msSinceLastAlert >= input.thresholdMs;
}

export interface HeartbeatInput {
  /** A goal is active (autoContinue) or a loop is running. */
  supervising: boolean;
  /** ctx.isIdle() && !ctx.hasPendingMessages() */
  sessionIdle: boolean;
  /** A continuation or loop timer is already scheduled. */
  timerPending: boolean;
  /** Milliseconds since the last observed agent activity. */
  msSinceActivity: number;
  stallMs?: number;
  /** v0.28.25: consecutive stall refires so far — spaces refires exponentially. */
  consecutiveStalls?: number;
}

/** Should the heartbeat re-fire the continuation right now? */
export function shouldHeartbeatRefire(input: HeartbeatInput): boolean {
  if (!input.supervising) return false;
  if (!input.sessionIdle) return false;
  if (input.timerPending) return false;
  // v0.28.25: exponential spacing between stall refires — 1m, 2m, 4m, 8m
  // (cap 8×). Field-observed in junk-runner: the flat 60s gate burned all
  // 5 refires in ~4 minutes into a just-compacted session, pausing a
  // resumable goal instead of giving the provider/queue time to recover.
  // noteActivity() runs at each refire, so msSinceActivity measures the
  // silence SINCE the last refire — scaling the threshold scales the gap.
  const stallMs = input.stallMs ?? HEARTBEAT_STALL_MS;
  const scale = 2 ** Math.min(input.consecutiveStalls ?? 0, 3);
  return input.msSinceActivity >= stallMs * scale;
}

/**
 * Judge a finished turn for nudge accounting. A supervising turn with zero
 * tool calls produced no real progress — that is a nudge. Anything with a
 * tool call resets the counter. Returns the new consecutive-nudge count.
 */
export function accountTurnForNudges(toolCalls: number, currentNudges: number): number {
  return toolCalls > 0 ? 0 : currentNudges + 1;
}

/**
 * v0.27.3: the pure nudge detector and richer accounting. A supervising turn
 * is a nudge (no real progress) iff it has NO tool calls AND its text is
 * either short (< DEFAULT_STALL_SHORT_WORDS words) OR highly similar to
 * the prior assistant turn (3-gram Jaccard > DEFAULT_STALL_SIM_THRESHOLD).
 * Substantive analytical replies (≥ 15 words, novel) reset the counter
 * even with no tool calls — the polis-session incident ("3 consecutive
 * turns with no tool calls" tripped the brake on real investigation work,
 * screenshot 2026-07-27) showed the simple tool-only check is too coarse.
 *
 * Word-count rather than char-count: "Working…" (1 word) is a nudge;
 * "state-pump-dom.ts has zero references to hud." (8 words, one sentence)
 * is not. A paragraph with at least one real sentence is > 15 words.
 *
 * Pure: no side effects, no state. Safe to unit-test with crafted inputs.
 */
export const DEFAULT_STALL_SHORT_WORDS = 15;
export const DEFAULT_STALL_SIM_THRESHOLD = 0.6;

export function trigramSimilarity(a: string, b: string): number {
  if (!a && !b) return 1;
  if (!a || !b) return 0;
  const grams = (s: string) => {
    const g = new Map<string, number>();
    const t = s.toLowerCase();
    for (let i = 0; i <= t.length - 3; i++) {
      const k = t.slice(i, i + 3);
      g.set(k, (g.get(k) ?? 0) + 1);
    }
    return g;
  };
  const ga = grams(a);
  const gb = grams(b);
  let inter = 0;
  let uni = 0;
  const keys = new Set([...ga.keys(), ...gb.keys()]);
  for (const k of keys) {
    const va = ga.get(k) ?? 0;
    const vb = gb.get(k) ?? 0;
    inter += Math.min(va, vb);
    uni += Math.max(va, vb);
  }
  return uni === 0 ? 0 : inter / uni;
}

export function isNudgeTurn(opts: {
  toolCalls: number;
  text: string;
  priorText: string;
  shortWords?: number;
  simThreshold?: number;
}): boolean {
  if (opts.toolCalls > 0) return false;
  const shortThr = opts.shortWords ?? DEFAULT_STALL_SHORT_WORDS;
  const simThr = opts.simThreshold ?? DEFAULT_STALL_SIM_THRESHOLD;
  const wordCount = (opts.text.trim().match(/\S+/g) ?? []).length;
  if (wordCount < shortThr) return true;
  if (!opts.priorText) return false; // first turn in a streak — no similarity to compare to
  return trigramSimilarity(opts.text, opts.priorText) > simThr;
}

export function accountTurnForNudgesRich(
  opts: {
    toolCalls: number;
    text: string;
    priorText: string;
    shortWords?: number;
    simThreshold?: number;
  },
  currentNudges: number,
): number {
  return isNudgeTurn(opts) ? currentNudges + 1 : 0;
}
