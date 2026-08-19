# Loop and context guardrails for Pi sessions

A project-local Pi extension that enforces two independent guardrails on every `tool_call` event.
It applies to any Pi session running inside this repo or its worktrees - primary Squad sessions and operator sessions alike.
The implementation lives in `.pi/extensions/sq-loop-context-guardrail.ts`.

## Guardrail A - Repeated identical tool calls

Tracks consecutive identical tool calls (same tool name and same canonicalized JSON input).
The streak counter does not reset on turn boundaries alone - only when a genuinely different call breaks the streak.

**Thresholds:**

| Streak | Action |
| ------ | ------ |
| 1-4 | No action. |
| 5 | One-time visible warning naming the tool and count. Does not repeat for calls 6-9. |
| 10+ | Blocked with a reason explaining the count and advising a different approach or target-liveness check. Blocks every call from 10 onward in the same streak. |

A different tool name or different canonicalized input resets the streak to 0 and clears the "already warned" flag.

## Guardrail B - Context budget (percentage-based)

Reads `ctx.getContextUsage()` on every `tool_call`.
The `percent` field is already normalized 0-100 relative to the model's context window - no hardcoded token ceiling.

**Zones:**

| Percent | Zone | Action |
| ------- | ---- | ------ |
| 0-39 | Smart | No action. Dropping back here resets attention and compaction flags. |
| 40-59 | Attention | One-time visible notice naming the percent and recommending `/compact` soon. Does not repeat while inside this zone. |
| 60-100 | Dumb | Blocked. The first entry into this zone auto-triggers `ctx.compact()` as a courtesy. Every subsequent call while still >= 60% keeps blocking (percent is re-read fresh each time). |

If `getContextUsage()` returns undefined or null (e.g. right after compaction), the guardrail skips entirely.

## Fail-open

Any internal error in the guardrail logic itself - such as `ctx.getContextUsage()` throwing - never crashes the session or blocks tool calls.
The call passes through and the error is logged.

## Scope

- Project-local extension in `.pi/extensions/` - auto-discovered by any Pi session in this repo or its worktrees.
- Does not touch `bin/sq-breaker-lib.sh` or `bin/sq-breaker.sh` (separate operator-facing circuit breaker).
- Both guardrails are independent state machines evaluated on every tool call.
- No new runtime dependencies.
