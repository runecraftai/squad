// pi-goal-list-loop-audit — v0.27.2
// extensions/length-continue.ts
//
// Folded-in auto-continue for output-token truncation (was the standalone
// pi-length-continue 0.1.0, now deprecated). When ONE assistant response
// exceeds the model's provider-side per-response output cap, pi ends the
// turn with stopReason "length" and idles — a dead stop on unattended rigs.
// The tracker decides when to re-trigger; goal.ts's agent_end handler wires
// it BEFORE all turn bookkeeping: a truncated turn is not a completed turn
// (no telemetry), not a stall (no no-tool nudge), and must not run the
// loop measure or the normal goal continuation on half a response.
//
// Guards (same as the standalone):
//   - consecutive cap: after MAX back-to-back truncations, give up (once)
//     instead of burning quota in a truncation ping-pong. Any normally
//     finished turn resets the counter.
//   - the caller skips when messages are already pending (a queued message
//     triggers a turn anyway) and routes stale-handle errors to
//     goStaleTerminal (pi#7154).

export const LENGTH_CONTINUE_MAX = 3;

export const LENGTH_CONTINUE_TEXT = [
  "Your previous response was cut off at the model's per-response output token limit.",
  "Continue EXACTLY where you stopped — finish the current artifact, then keep going.",
  "Keep each individual response shorter from here: split large file writes into multiple smaller write/edit calls across turns instead of one giant response.",
].join(" ");

export interface LengthContinueTick {
  /** Send the continue message this round. */
  fire: boolean;
  /** The cap was just exceeded — notify the give-up exactly once. */
  giveUpNow: boolean;
  /** Current consecutive truncation streak (after this tick). */
  consecutive: number;
}

export function makeLengthContinueTracker(max: number = LENGTH_CONTINUE_MAX) {
  let consecutive = 0;
  let gaveUp = false;
  return {
    tick(stopped: boolean): LengthContinueTick {
      if (!stopped) {
        consecutive = 0;
        gaveUp = false;
        return { fire: false, giveUpNow: false, consecutive: 0 };
      }
      consecutive++;
      if (consecutive > max) {
        const giveUpNow = !gaveUp;
        gaveUp = true;
        return { fire: false, giveUpNow, consecutive };
      }
      return { fire: true, giveUpNow: false, consecutive };
    },
    get consecutive(): number {
      return consecutive;
    },
  };
}

// Session-level singleton — one tracker per extension runtime. The factory
// calls resetLengthContinue() so an extension reload starts clean.
let tracker = makeLengthContinueTracker();

export function tickLengthContinue(stopped: boolean): LengthContinueTick {
  return tracker.tick(stopped);
}

export function resetLengthContinue(): void {
  tracker = makeLengthContinueTracker();
}
