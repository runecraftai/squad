// pi-goal-list-loop-audit — v0.26.5
// tests/pending-latch.test.ts
//
// Pending-latch watchdog. Field-observed 2026-07-26 (this repo's own
// chat/pi session): a continuation sent at compaction+0s was ACCEPTED
// (goal_continuation_sent ledgered) but the turn trigger was dropped;
// pi's pending-message flag stayed set for 22 minutes. sessionIdle
// (isIdle && !hasPendingMessages) never went true → no refire, no stall
// escalation, no wedge alert (22m < 30m and the framing would be wrong)
// → total silence until a manual nudge. The watchdog owns that shape.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

import {
  PENDING_LATCH_STUCK_MS,
  shouldFirePendingLatchWatchdog,
} from "../extensions/goal-loop-backoff.ts";
import { classifyFindingText, extractFindings } from "../extensions/reviewer.ts";

const SRC_GOAL = fs.readFileSync("extensions/loops/goal.ts", "utf-8");

const BASE = {
  supervising: true,
  idle: true,
  pending: true,
  timerPending: false,
  silentMs: PENDING_LATCH_STUCK_MS,
  thresholdMs: PENDING_LATCH_STUCK_MS,
};

test("watchdog fires on the field-observed shape: supervising + idle + pending + no timers + silent >= threshold", () => {
  assert.equal(shouldFirePendingLatchWatchdog(BASE), true);
  assert.equal(shouldFirePendingLatchWatchdog({ ...BASE, silentMs: PENDING_LATCH_STUCK_MS + 1 }), true);
});

test("watchdog does NOT fire when any guard fails", () => {
  assert.equal(shouldFirePendingLatchWatchdog({ ...BASE, supervising: false }), false, "not supervising");
  assert.equal(shouldFirePendingLatchWatchdog({ ...BASE, idle: false }), false, "genuinely busy = wedge alert's job");
  assert.equal(shouldFirePendingLatchWatchdog({ ...BASE, pending: false }), false, "no pending = plain idle stall = refire path");
  assert.equal(shouldFirePendingLatchWatchdog({ ...BASE, timerPending: true }), false, "a timer is already scheduled");
  assert.equal(shouldFirePendingLatchWatchdog({ ...BASE, silentMs: PENDING_LATCH_STUCK_MS - 1 }), false, "under threshold");
  assert.equal(shouldFirePendingLatchWatchdog({ ...BASE, thresholdMs: 0 }), false, "0 disables");
});

test("threshold is 3 minutes (post-compaction settle is 2s; legit queue latency is seconds)", () => {
  assert.equal(PENDING_LATCH_STUCK_MS, 3 * 60_000);
});

test("heartbeat wiring: idle/pending split, watchdog branch, ledger event, wedge uses !idle, shared escalation", () => {
  assert.match(SRC_GOAL, /idle = ctx\.isIdle\(\);\s*\n\s*pending = ctx\.hasPendingMessages\(\);/);
  assert.match(SRC_GOAL, /shouldFirePendingLatchWatchdog\(\{/);
  assert.match(SRC_GOAL, /appendLedger\(ctx\.cwd, "pending_latch_stuck", \{ consecutiveStalls, silentMs: latchSilentMs \}\)/);
  assert.match(SRC_GOAL, /sessionBusy: !idle,/, "wedge alert must not fire on latch-pending (it is not a hung command)");
  assert.match(SRC_GOAL, /function escalateStallNow\(ctx: ExtensionContext, threshold: number\): boolean/);
  // Both stall paths share the escalation helper:
  const calls = SRC_GOAL.match(/if \(escalateStallNow\(ctx, stallEscalation\)\) return;/g) ?? [];
  assert.equal(calls.length, 2, "refire path + latch path both escalate through the helper");
  // The latch path NEVER re-sends (hegemon lesson: 619 sends, 0 turns):
  const latchBlock = SRC_GOAL.slice(SRC_GOAL.indexOf("shouldFirePendingLatchWatchdog({"), SRC_GOAL.indexOf("const wedgeMinutes"));
  assert.ok(!latchBlock.includes("scheduleContinuation") && !latchBlock.includes("scheduleLoopTick"), "latch path must not re-send");
});

test("the exact 'ℹ todo 0' junk line (enqueued as a /list item by the 0.26.2 reviewer) never classifies", () => {
  assert.equal(classifyFindingText("ℹ todo 0"), undefined);
  assert.equal(classifyFindingText("- ℹ todo 0"), undefined);
  assert.equal(classifyFindingText("ℹ tests 395"), undefined);
  assert.equal(classifyFindingText("ℹ pass 394"), undefined);
  const findings = extractFindings([{ name: "audit", text: "## Bug-class\n\n- ℹ todo 0\n- ℹ skipped 1" }], 10);
  assert.deepEqual(findings, []);
});
