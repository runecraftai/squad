// pi-goal-list-loop-audit — v0.25.0
// extensions/quota-retry.ts
//
// Quota-aware retry (eager-continuation contract, Section C). Before this
// module, an auditor that failed with a 429 / quota error re-fired the
// continuation loop FOREVER (the error branch just rescheduled), burning
// tokens against a quota window that only resets in an hour. Now a quota
// error pauses the goal with a scheduled one-shot retry at the upstream's
// own Retry-After hint (default 60m, configurable via quotaRetryMinutes).

import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export interface QuotaError {
  raw: string;
  /** Seconds until retry, from the upstream hint or the default. */
  retryAfterSec: number;
  /** True when retryAfterSec came from the upstream (Retry-After /
   * "retry in Ns"), false when the default was used. */
  fromUpstream: boolean;
}

/** Match 429, "quota", "rate limit", "temporarily rate-limited upstream",
 * credit exhaustion — the shapes we have caught in the wild (OpenRouter,
 * MiniMax, Anthropic). */
export function isQuotaError(error: string | undefined): boolean {
  if (!error) return false;
  return /429|quota|rate.?limit|temporarily|credits?|key limit exceeded|insufficient.?balance|too many requests/i.test(error);
}

/** Parse the retry window out of an error string. Understands:
 *  - `Retry-After: 5` (header echoed into the error text)
 *  - `retry after 30 seconds` / `retry in 2m` prose
 *  - default 3600s when no hint (contract item 11). */
export function parseQuotaError(error: string, defaultRetryAfterSec = 3600): QuotaError {
  let m = error.match(/retry-after:\s*(\d+)/i);
  if (m) {
    const sec = Number(m[1]);
    if (Number.isFinite(sec) && sec >= 0) return { raw: error, retryAfterSec: sec, fromUpstream: true };
  }
  m = error.match(/retry (?:after|in)\s+(\d+)\s*(s|sec|seconds|m|min|minutes|h|hours?)/i);
  if (m) {
    const n = Number(m[1]);
    const unit = m[2]!.toLowerCase();
    const mult = unit.startsWith("h") ? 3600 : unit.startsWith("m") ? 60 : 1;
    if (Number.isFinite(n) && n >= 0) return { raw: error, retryAfterSec: n * mult, fromUpstream: true };
  }
  return { raw: error, retryAfterSec: defaultRetryAfterSec, fromUpstream: false };
}

let quotaRetryTimer: NodeJS.Timeout | null = null;

/** Test hook — is a quota retry currently scheduled? */
export function isQuotaRetryPending(): boolean {
  return quotaRetryTimer !== null;
}

/** Cancel any pending quota retry (e.g. the user resumed manually). */
export function cancelQuotaRetry(): void {
  if (quotaRetryTimer) {
    clearTimeout(quotaRetryTimer);
    quotaRetryTimer = null;
  }
}

/** Schedule a one-shot auto-resume after the quota window. The fire
 * callback re-checks the goal is STILL paused for the quota reason before
 * resuming (contract item 10/12 — a user /goal pause during the window
 * must not be stomped). v0.28.5: `label` generalizes the notify so the
 * 5-consecutive-errors brake can reuse the same capped one-shot machinery. */
export function scheduleQuotaRetry(
  ctx: ExtensionContext,
  retryAfterSec: number,
  reason: string,
  fire: () => void,
  label = "Auditor quota exhausted — auto-retry",
): void {
  cancelQuotaRetry();
  const ms = Math.max(1_000, retryAfterSec * 1_000);
  quotaRetryTimer = setTimeout(() => {
    quotaRetryTimer = null;
    try {
      fire();
    } catch {
      /* session may be gone; session_start will re-evaluate */
    }
  }, ms);
  quotaRetryTimer.unref?.();
  ctx.ui.notify(
    `${label} in ${Math.round(retryAfterSec / 60)}m (${reason.slice(0, 80)}). /goal resume retries now.`,
    "info",
  );
}

/** v0.25.6: detect a SUBAGENT quota failure in a tool_result — the
 * pi-subagents#175 shape (Explore's upstream haiku pin 403s on shared
 * keys). Tool must be an Agent spawn and the payload a quota error. */
export function isSubagentQuotaResult(toolName: string, isError: boolean, payload: unknown): boolean {
  if (!isError) return false;
  if (toolName !== "Agent" && toolName !== "agent") return false;
  const text = typeof payload === "string" ? payload : JSON.stringify(payload ?? "");
  return isQuotaError(text);
}
