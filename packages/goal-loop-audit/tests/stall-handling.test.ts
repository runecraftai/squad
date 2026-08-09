// pi-goal-list-loop-audit — v0.26.1
// tests/stall-handling.test.ts
//
// Stall handling: send-path ledger instrumentation, refire-streak
// escalation, compaction hook, widget surface. Motivating incident:
// hegemon 2026-07-25/26 — 619 heartbeat_refires over 23.5h with zero
// loop turns; the send path was silent and the nudge counter (which
// counts TURNS) could never catch a zombie that runs none.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  DEFAULT_STALL_ESCALATION_REFIRES,
  shouldEscalateStall,
} from "../extensions/goal-loop-core.ts";
import { loadSettings, saveSettings } from "../extensions/goal-settings.ts";
import { buildStatusText, buildWidgetLines } from "../extensions/goal-loop-display.ts";

const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");

test("escalation gate: threshold semantics (0 = never, N = fire at streak N)", () => {
  assert.equal(shouldEscalateStall(5, 5), true);
  assert.equal(shouldEscalateStall(4, 5), false);
  assert.equal(shouldEscalateStall(6, 5), true);
  assert.equal(shouldEscalateStall(999, 0), false, "0 disables escalation (legacy spin)");
  assert.equal(DEFAULT_STALL_ESCALATION_REFIRES, 5);
});

test("send paths are ledgered: sent AND failed, loop and goal", () => {
  for (const ev of ["loop_turn_sent", "loop_turn_send_failed", "goal_continuation_sent", "goal_continuation_send_failed"]) {
    assert.ok(SRC.includes(`"${ev}"`), `missing ledger event ${ev}`);
  }
  // The failure branch must capture the error message (was: silent catch).
  assert.match(SRC, /loop_turn_send_failed", \{ error: err instanceof Error/);
});

test("refire streak: incremented on refire, ledgered, reset only on REAL activity", () => {
  assert.match(SRC, /consecutiveStalls\+\+;\n\s*appendLedger\(ctx\.cwd, "heartbeat_refire", \{ nudgesSoFar: heartbeatNudges, consecutiveStalls \}\)/);
  // agent_end and tool_call are real activity:
  assert.match(SRC, /if \(isForeignCtx\(ctx\)\) return;\n\s*noteActivity\(true\);/);
  assert.match(SRC, /toolCallsThisTurn\+\+;\n\s*noteActivity\(true\);/);
  // the heartbeat refire itself must NOT reset the streak:
  const def = SRC.match(/function noteActivity\(real = false\): void \{[\s\S]*?\}/)![0];
  assert.match(def, /if \(real\) consecutiveStalls = 0;/);
});

test("escalation: streak at threshold stops the loop / pauses the goal, loudly", () => {
  // v0.26.5: the escalation block is shared via escalateStallNow(ctx, threshold):
  assert.match(SRC, /function escalateStallNow\(ctx: ExtensionContext, threshold: number\): boolean/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "stall_escalated", \{ threshold, kind:/);
  assert.match(SRC, /stalled: \$\{threshold\} continuation refires landed no turn/);
  assert.match(SRC, /notifyExternal\(ctx, "Loop stopped: stalled \(continuation not landing\)\."\)/);
  assert.match(SRC, /notifyExternal\(ctx, `\$\{goalNoun\(\)\} paused: stalled \(continuation not landing\)\."?`?\)/);
  // the escalation return happens BEFORE the schedule (no more refires):
  const escIdx = SRC.indexOf('"stall_escalated"');
  const refireScheduleIdx = SRC.indexOf('re-firing continuation (stall');
  assert.ok(escIdx < refireScheduleIdx, "escalation precedes the refire schedule");
});

test("session_compact hook: re-arms the chain when idle with no timer pending", () => {
  assert.match(SRC, /pi\.on\("session_compact", async \(_event: any, ctx: ExtensionContext\) => \{/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "session_compact", \{\}\)/);
  assert.match(SRC, /appendLedger\(c\.cwd, "compaction_refire", \{\}\)/);
  // only when nothing is scheduled and the session is idle:
  assert.match(SRC, /c\.isIdle\(\) && !c\.hasPendingMessages\(\) && continuationTimer === null && loopTimer === null && isSupervising\(\)/);
});

test("widget + status surface the streak only while nonzero", () => {
  const loop = {
    active: true, target: "reconcile the spec", measureCmd: "", iteration: 0,
    maxIterations: 0, stallCount: 0, plateauWindow: 5, startedAt: new Date(Date.now() - 3600_000).toISOString(),
    history: [],
  };
  const state: any = { loop, goal: undefined, list: [] };
  const quiet = buildWidgetLines(state, null, Date.now(), undefined, undefined, { stalls: 0 })!;
  const stalled = buildWidgetLines(state, null, Date.now(), undefined, undefined, { stalls: 3 })!;
  assert.ok(!quiet.some((l) => l.includes("stalls:")), "no stalls note at 0");
  assert.ok(stalled.some((l) => l.includes("stalls:3")), "stalls note at 3");
  const statusQuiet = buildStatusText(state, null, Date.now(), undefined, { stalls: 0 })!;
  const statusStalled = buildStatusText(state, null, Date.now(), undefined, { stalls: 7 })!;
  assert.ok(!statusQuiet.includes("stalls:"));
  assert.ok(statusStalled.includes("stalls:7"));
});

test("settings: stallEscalationRefires round-trips through save/load", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-stall-"));
  saveSettings("project", dir, { stallEscalationRefires: 3 });
  assert.equal(loadSettings(dir).stallEscalationRefires, 3);
  saveSettings("project", dir, { stallEscalationRefires: 0 });
  assert.equal(loadSettings(dir).stallEscalationRefires, 0, "0 persists (never-escalate opt-out)");
});

test("/glla surface: stallescalation completion + key=value parser branch", () => {
  assert.match(SRC, /\["stallescalation=", "N: heartbeat refires without a turn/);
  assert.match(SRC, /key === "stallescalation" \|\| key === "stallescalationrefires"/);
});

// =================================================================
// v0.28.4 — P1–P3 (audit Stream 5): nudge before the brake; unclosed-status
// block in every continuation; post-restore grace.
// =================================================================

const PROMPT = fs.readFileSync("prompts/goal-loop-continuation.md", "utf-8");

test("P1: graduated stall escalation entry before the brake (sender + wiring)", () => {
  assert.match(SRC, /function sendStallEscalation\(ctx: ExtensionContext, nudges: number\): void/);
  assert.match(SRC, /\[STALL WARNING \$\{nudges\}\/\$\{HEARTBEAT_MAX_NUDGES\}\] The last turn produced no tool calls\./);
  assert.match(SRC, /If the goal is DONE, call complete_goal NOW — prose closes nothing/);
  assert.match(SRC, /If you are BLOCKED, call pause_goal with the blocker and a suggested action\./);
  assert.match(SRC, /ONE more unproductive turn pauses the goal\./);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "stall_escalation_nudge", \{ nudges, remaining \}\)/);
  // wired at nudge>=1 for active goals only (loops keep runLoopTick), and the
  // send path is stale-aware like every other autonomous send:
  assert.match(SRC, /if \(heartbeatNudges >= 1 && state\.goal && state\.goal\.status === "active" && !isLoopActive\(\)\)/);
  assert.match(SRC, /goStaleTerminal\(ctx, "sendStallEscalation"\)/);
});

test("P2: every continuation carries the unclosed-status block", () => {
  assert.match(PROMPT, /## State\n\n\*\*State: ACTIVE — not yet auditor-approved\.\*\*/);
  assert.match(PROMPT, /Prose closes nothing/);
  assert.match(PROMPT, /A done-but-unclosed goal is a bug, not a resting state\./);
  // and the STALLS section names the graduated warning:
  assert.match(PROMPT, /\[STALL WARNING n\/3\]/);
});

test("P3: post-restore grace — armed on restore resume, skips accounting, ledgered", () => {
  assert.match(SRC, /let postRestoreGraceTurns = 0;/);
  assert.match(SRC, /postRestoreGraceTurns = 2;\n        scheduleContinuation\(ctx, true\);/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "post_restore_grace", \{ remaining: postRestoreGraceTurns \}\)/);
  // grace check sits BEFORE the accounting call:
  const graceIdx = SRC.indexOf("if (postRestoreGraceTurns > 0) {");
  const acctIdx = SRC.indexOf("heartbeatNudges = accountTurnForNudgesRich(");
  assert.ok(graceIdx > 0 && graceIdx < acctIdx, "grace precedes nudge accounting");
});

test("v0.28.24: session_compact resets the send-rearm storm streaks + opens the post-compaction grace", () => {
  // π-web nearly escalated a "send-retry storm" pause during a legitimate
  // 3.5-minute compaction; junk-runner burned all 5 stall refires in the 5
  // minutes right after a 196k-token compact. Both are fixed at the hook:
  const hookIdx = SRC.indexOf('pi.on("session_compact"');
  const resetIdx = SRC.indexOf("continuationRearmStreak = 0; continuationRearmSince = 0;\n    loopRearmStreak = 0; loopRearmSince = 0;\n    compactionGraceUntil = Date.now() + COMPACTION_GRACE_MS;");
  assert.ok(hookIdx > 0 && resetIdx > hookIdx, "streak reset + grace arm inside the session_compact hook");
  assert.match(SRC, /const COMPACTION_GRACE_MS = 3 \* 60_000;/);
  // the grace check gates the heartbeat's stall/refire machinery:
  assert.match(SRC, /if \(Date\.now\(\) < compactionGraceUntil\) return;/);
  const graceGate = SRC.indexOf("if (Date.now() < compactionGraceUntil) return;");
  const refire = SRC.indexOf('appendLedger(ctx.cwd, "heartbeat_refire"');
  assert.ok(graceGate > 0 && graceGate < refire, "grace gate precedes the refire path");
});
