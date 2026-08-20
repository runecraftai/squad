import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// --- Canonicalization helper ---

/** Recursively sort object keys and produce a stable JSON string. */
function canonicalizeInput(input: unknown): string {
  if (input === null || input === undefined) return JSON.stringify(input);
  if (typeof input !== "object") return JSON.stringify(input);
  if (Array.isArray(input)) {
    const items = input.map((item) => canonicalizeInput(item));
    return `[${items.join(",")}]`;
  }
  const sorted = Object.keys(input as Record<string, unknown>).sort();
  const pairs = sorted.map(
    (key) => `"${key}":${canonicalizeInput((input as Record<string, unknown>)[key])}`,
  );
  return `{${pairs.join(",")}}`;
}

// --- Guardrail A: Repeated identical tool calls ---

interface RepeatedCallState {
  streakCount: number;
  streakKey: string | null;
  alreadyWarnedAt5: boolean;
  alreadyBlockedAt10: boolean;
}

function createRepeatedCallGuardrail() {
  const state: RepeatedCallState = {
    streakCount: 0,
    streakKey: null,
    alreadyWarnedAt5: false,
    alreadyBlockedAt10: false,
  };

  return {
    check(
      toolName: string,
      input: unknown,
      hasUI: boolean,
      notify: (msg: string, type: string) => void,
    ): { block?: boolean; reason?: string } {
      const key = `${toolName}:${canonicalizeInput(input)}`;

      // Different call breaks the streak.
      if (state.streakKey !== key) {
        state.streakCount = 1;
        state.streakKey = key;
        state.alreadyWarnedAt5 = false;
        state.alreadyBlockedAt10 = false;
        return {};
      }

      // Same call continues the streak.
      state.streakCount += 1;
      const count = state.streakCount;

      // Streak 1-4: no action.
      if (count < 5) return {};

      // Streak 5-9: one-time visible warning.
      if (count >= 5 && count < 10) {
        if (!state.alreadyWarnedAt5) {
          state.alreadyWarnedAt5 = true;
          const msg =
            `Repeated identical tool call detected: ${toolName} ` +
            `(streak: ${count}). Consider changing approach or ` +
            `verifying the target is responding.`;
          if (hasUI) {
            notify(msg, "warning");
          } else {
            console.warn(`[sq-loop-context-guardrail] ${msg}`);
          }
        }
        return {};
      }

      // Streak 10+: block every call.
      state.alreadyBlockedAt10 = true;
      return {
        block: true,
        reason:
          `Blocked: ${count} consecutive identical calls to ${toolName}. ` +
          `The tool is likely stuck in a loop. Change approach or ` +
          `check real target liveness before retrying.`,
      };
    },
  };
}

// --- Guardrail B: Context budget (percentage-based) ---

type Zone = "low" | "attention" | "dumb";

interface ContextBudgetState {
  lastZone: Zone | null;
  alreadyNoticedAttention: boolean;
  compactionAttempted: boolean;
}

function createContextBudgetGuardrail() {
  const state: ContextBudgetState = {
    lastZone: null,
    alreadyNoticedAttention: false,
    compactionAttempted: false,
  };

  return {
    check(
      ctx: {
        getContextUsage: () => { tokens: number; percent: number } | undefined | null;
        hasUI: boolean;
        ui: { notify: (msg: string, type: string) => void };
        compact: (opts?: { customInstructions?: string; onComplete?: () => void; onError?: (err: unknown) => void }) => void;
      },
    ): { block?: boolean; reason?: string } {
      const usage = ctx.getContextUsage();

      // Unknown context - skip entirely.
      if (!usage || usage.tokens == null || usage.percent == null) return {};

      const percent = usage.percent;

      // Determine the current zone.
      let zone: Zone;
      if (percent >= 60) {
        zone = "dumb";
      } else if (percent >= 40) {
        zone = "attention";
      } else {
        zone = "low";
      }

      // Transitioning back to low resets attention/compaction flags.
      if (zone === "low" && state.lastZone !== "low" && state.lastZone !== null) {
        state.alreadyNoticedAttention = false;
        state.compactionAttempted = false;
      }

      state.lastZone = zone;

      // Low zone: no action.
      if (zone === "low") return {};

      // Attention zone (40-59%): one-time notice on crossing in.
      if (zone === "attention") {
        if (!state.alreadyNoticedAttention) {
          state.alreadyNoticedAttention = true;
          const msg =
            `Context usage at ${Math.round(percent)}%. ` +
            `Consider wrapping up soon or running /compact.`;
          if (ctx.hasUI) {
            ctx.ui.notify(msg, "warning");
          } else {
            console.warn(`[sq-loop-context-guardrail] ${msg}`);
          }
        }
        return {};
      }

      // Dumb zone (>= 60%): block and optionally trigger compaction.
      if (!state.compactionAttempted) {
        state.compactionAttempted = true;
        try {
          ctx.compact({
            onError: () => {},
          });
        } catch {
          // Compaction trigger failure is non-fatal.
        }
      }

      return {
        block: true,
        reason:
          `Context usage at ${Math.round(percent)}%. ` +
          `Tool calls are blocked at this context level. ` +
          `Run /compact or report to your commander.`,
      };
    },
  };
}

// --- Extension entry point ---

export default function (pi: ExtensionAPI) {
  const repeatedCall = createRepeatedCallGuardrail();
  const contextBudget = createContextBudgetGuardrail();

  pi.on("tool_call", async (event, ctx) => {
    try {
      if (event.type !== "tool_call") return {};

      const toolName = String(event.toolName ?? "");
      const input = event.input;
      const hasUI = Boolean(ctx?.hasUI);
      const notify = (msg: string, type: string) => {
        if (ctx?.ui?.notify) ctx.ui.notify(msg, type);
      };

      // Evaluate both guardrails independently.
      const repeatedResult = repeatedCall.check(toolName, input, hasUI, notify);
      const budgetResult = contextBudget.check({
        getContextUsage: () => (ctx as any)?.getContextUsage?.(),
        hasUI,
        ui: { notify },
        compact: (opts) => {
          try {
            (ctx as any)?.compact?.(opts);
          } catch {
            // Non-fatal.
          }
        },
      });

      // Either guardrail can block.
      if (repeatedResult.block) return { block: true, reason: repeatedResult.reason };
      if (budgetResult.block) return { block: true, reason: budgetResult.reason };

      return {};
    } catch (err) {
      // Fail-open: internal errors never block tool calls.
      console.warn(`[sq-loop-context-guardrail] internal error: ${err}`);
      return {};
    }
  });
}
