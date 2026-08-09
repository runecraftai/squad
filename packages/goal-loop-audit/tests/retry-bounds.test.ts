// pi-goal-list-loop-audit — v0.28.5
// tests/retry-bounds.test.ts
//
// Pins the v0.28.5 silent-retry-loop bounds (audit findings E2, E3, E8 —
// audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md Stream 2):
//   E2  auditor infra errors retried FOREVER (the 39-error incident): each
//       infra failure rescheduled a continuation unconditionally. Now a
//       persisted auditInfraStreak pauses the goal loudly at 3.
//   E3  the 50ms BACKOFF_IDLE_RETRY re-arm loop spun for HOURS with zero
//       ledger events while idle watchdogs stayed suppressed. Now counted,
//       ledgered (start + every 30s), escalated loudly past 5 minutes.
//   E8  the consecutive-errors brake paused with the literal reason
//       "5 consecutive errors: error" (stopReason, not the provider error),
//       counted USER ABORTS as errors, and had no recovery — the 10:07
//       incident lost 1.5h of the audit goal to a 60s provider flake.
//       Now: real error text in the reason, aborts braked separately with
//       no auto-resume (user intent), errors get ONE capped 60s auto-resume.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
const CORE = fs.readFileSync("extensions/goal-loop-core.ts", "utf-8");
const QUOTA = fs.readFileSync("extensions/quota-retry.ts", "utf-8");
const SCHEMA = fs.readFileSync("schemas/goal.schema.json", "utf-8");

test("E2: persisted auditInfraStreak field (type + schema)", () => {
  assert.match(CORE, /auditInfraStreak\?: number;/);
  assert.match(SCHEMA, /"auditInfraStreak": \{ "type": "number" \}/);
});

test("E2: 3 trailing auditor infra errors pause LOUDLY (no more retry-forever)", () => {
  assert.match(SRC, /const infraStreak = \(state\.goal\.auditInfraStreak \?\? 0\) \+ 1;/);
  assert.match(SRC, /if \(infraStreak >= 3\) \{/);
  assert.match(SRC, /auditor infrastructure failed \$\{infraStreak\}× in a row — the auditor model is likely broken/);
  assert.match(SRC, /The goal is PAUSED — the retry-forever loop stops here/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "goal_paused", \{ reason: `auditor infra streak \$\{infraStreak\}/);
  // below the threshold the streak persists across turns (survives restarts):
  assert.match(SRC, /auditInfraStreak: infraStreak,/);
  // a real auditor run clears it; reaching quota also clears it:
  assert.match(SRC, /if \(auditorRan && \(state\.goal\.auditInfraStreak \?\? 0\) > 0\) updateGoal\(\{ auditInfraStreak: undefined \}, ctx\);/);
  assert.match(SRC, /auditInfraStreak: undefined, \/\/ quota reached the auditor — infra streak broken/);
});

test("E3: send-retry re-arms counted, ledgered, escalated", () => {
  assert.match(SRC, /appendLedger\(ctx\.cwd, "send_rearm_start", \{ kind \}\)/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "send_rearm_storm", \{ kind, streak/);
  // wired into both send paths' re-arm sites:
  assert.match(SRC, /accountSendRearm\(ctx, "continuation"\);/);
  assert.match(SRC, /if \(ctx\) accountSendRearm\(ctx, "loop"\);/);
  // a landed send clears the storm:
  assert.match(SRC, /continuationRearmStreak = 0; continuationRearmSince = 0; \/\/ v0\.28\.5 \(E3\)/);
  assert.match(SRC, /loopRearmStreak = 0; loopRearmSince = 0; \/\/ v0\.28\.5 \(E3\)/);
});

test("v0.28.29: busy-retry cadence backs off (no more flat 50ms spins)", () => {
  assert.match(SRC, /function sendRearmDelayMs\(streak: number\): number/);
  assert.match(SRC, /if \(streak <= 4\) return 50;/);
  assert.match(SRC, /if \(streak <= 8\) return 250;/);
  assert.match(SRC, /if \(streak <= 12\) return 1_000;/);
  assert.match(SRC, /return 30_000;/);
  assert.match(SRC, /setTimeout\(\(\) => sendContinuation\(goalId\), sendRearmDelayMs\(continuationRearmStreak\)\)/);
  assert.match(SRC, /setTimeout\(\(\) => sendLoopTurn\(\), sendRearmDelayMs\(loopRearmStreak\)\)/);
});

test("v0.28.29: escalation is TIME-based and ACTIVITY-gated (busy ≠ wedged — the polis false positive)", () => {
  assert.match(SRC, /const SEND_REARM_ESCALATE_AFTER_MS = 15 \* 60_000;/);
  assert.match(SRC, /const SEND_REARM_ESCALATE_SILENT_MS = 5 \* 60_000;/);
  assert.match(SRC, /elapsed >= SEND_REARM_ESCALATE_AFTER_MS && Date\.now\(\) - lastActivityAt >= SEND_REARM_ESCALATE_SILENT_MS/);
  assert.match(SRC, /const SEND_REARM_LEDGER_MILESTONES_MS = \[2 \* 60_000, 5 \* 60_000, 10 \* 60_000\];/);
  assert.match(SRC, /"send_rearm_escalated", \{ kind, afterMinutes: mins, silentMinutes: silent \}/);
  assert.ok(!SRC.includes("SEND_REARM_ESCALATE_AT"), "count-based escalation constant gone");
  assert.ok(!SRC.includes("SEND_REARM_LEDGER_EVERY"), "count-based ledger constant gone");
});

test("E3: escalation is loud-terminal (goal pause / loop stop with restart guidance)", () => {
  assert.match(SRC, /function escalateSendRearmStorm\(ctx: ExtensionContext, kind: "continuation" \| "loop"\): void/);
  assert.match(SRC, /send-retry storm: \$\{mins\}m of re-arms with no session activity for \$\{silent\}m — the session never went idle for the continuation/);
  assert.match(SRC, /Restart pi, then \/goal resume\./);
  assert.match(SRC, /send-retry storm: \$\{mins\}m of re-arms with no session activity for \$\{silent\}m — the session is wedged\. Restart pi, then \/loop start again\./);
});

test("E8: the error brake carries the REAL error text, not stopReason", () => {
  assert.match(SRC, /const detail = text\.trim\(\) \? ` \(last: \$\{text\.trim\(\)/);
  assert.match(SRC, /const reason = `5 consecutive errors\$\{detail\}`;/);
  assert.ok(!SRC.includes('pauseReason: `5 consecutive errors: ${stopReason}`'), "old literal-'error' shape gone");
});

test("E8: user aborts braked SEPARATELY — honest message, no auto-resume", () => {
  assert.match(SRC, /let consecutiveAbortIterations = 0;/);
  assert.match(SRC, /\} else if \(stopReason === "aborted"\) \{/);
  assert.match(SRC, /pauseReason: "5 consecutive aborts \(user interrupted\)"/);
  // abort branch must NOT schedule an auto-resume (user intent):
  const abortBranch = SRC.slice(SRC.indexOf('} else if (stopReason === "aborted") {'), SRC.indexOf("} else {", SRC.indexOf('} else if (stopReason === "aborted") {')));
  assert.ok(!abortBranch.includes("scheduleQuotaRetry"), "no auto-resume for user aborts");
});

test("E8: provider-error brake gets ONE capped escalating auto-resume with reason re-check (v0.28.25)", () => {
  // v0.28.25: the cooldown escalates per consecutive brake — 60s, 2m, 4m,
  // 8m, 16m cap. First brake is still 60s (60_000 * 2^0).
  assert.match(SRC, /const cooldownMs = 60_000 \* 2 \*\* Math\.min\(errorBrakeStreak, 4\);/);
  assert.match(SRC, /errorBrakeStreak\+\+;/);
  assert.match(SRC, /scheduleQuotaRetry\(ctx, cooldownMs \/ 1000, reason, \(\) => \{/);
  assert.match(SRC, /errorBrakeStreak = 0; \/\/ v0\.28\.25/, "a healthy turn clears the brake cooldown");
  assert.match(SRC, /\(state\.goal\.pauseReason \?\? ""\)\.startsWith\("5 consecutive errors"\)/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "goal_resumed", \{ via: "error-brake-retry" \}\)/);
  // scheduleQuotaRetry generalized with a label param (quota default intact):
  assert.match(QUOTA, /label = "Auditor quota exhausted — auto-retry",/);
});

test("v0.28.25: inter-error retries ride an exponential ladder, not the immediate continuation", () => {
  // dracon-utilities: 5 concurrent-limit 403s retried back-to-back (delay 0
  // at agent_end — the session is idle), then the brake cycled for 1h 38m.
  assert.match(SRC, /const ERROR_RETRY_LADDER_MS = \[5_000, 15_000, 45_000, 90_000, 180_000\];/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "error_retry_backoff", \{ attempt: consecutiveErrorIterations, delayMs: retryDelayMs \}\);/);
  assert.match(SRC, /scheduleContinuation\(ctx, true, retryDelayMs\);/);
  // the ladder return sits inside the error branch, before the generic fall-through:
  const ladderIdx = SRC.indexOf("scheduleContinuation(ctx, true, retryDelayMs);");
  const abortBranch = SRC.indexOf('} else if (stopReason === "aborted") {');
  assert.ok(ladderIdx > 0 && abortBranch > ladderIdx, "ladder return precedes the aborted branch");
  // and scheduleContinuation honors an explicit delay:
  assert.match(SRC, /function scheduleContinuation\(ctx: ExtensionContext, force = false, delayMs\?: number\): void \{/);
  assert.match(SRC, /delay = delayMs \?\? \(ctx\.isIdle\(\)/);
});

test("v0.28.26: quota-blocked audits store the claim + the retry re-runs the AUDITOR directly (no agent turn)", () => {
  // π-games incident: quota-blocked complete_goal → resume re-engaged the
  // agent → the model hallucinated closure and repeated itself into a
  // continuation storm + 14 compactions in 35 minutes.
  // 1. the claim is persisted at the quota block:
  assert.match(SRC, /pendingCompletion: \{ completionSummary: p\.completionSummary, verificationSummary: p\.verificationSummary, at: nowIso\(\) \},/);
  // 2. the quota-retry callback prefers the direct-audit path:
  const cbIdx = SRC.indexOf('(state.goal.pauseReason ?? "").startsWith("auditor quota:")');
  const directIdx = SRC.indexOf("void retryStoredCompletionAudit(ctx);");
  assert.ok(cbIdx > 0 && directIdx > cbIdx, "direct-audit branch inside the quota callback");
  const legacyIdx = SRC.indexOf('appendLedger(ctx.cwd, "goal_resumed", { via: "quota-retry" });');
  assert.ok(legacyIdx > directIdx, "agent-resume is the FALLBACK (no stored claim), not the default");
  // 3. the retry function re-runs the auditor with the stored claim:
  assert.match(SRC, /async function retryStoredCompletionAudit\(ctx: ExtensionContext, origin: "quota-retry" \| "manual" = "quota-retry"\): Promise<void> \{/);
  assert.match(SRC, /completionSummary: claim\.completionSummary,/);
  assert.match(SRC, /verificationSummary: claim\.verificationSummary,/);
  // 4. approved → archive (cascade inside archiveCurrentGoal); claim cleared:
  assert.match(SRC, /archiveCurrentGoal\(liveCtx, "complete", `auditor \$\{result\.model\} approved \(\$\{origin\}\)`\)/);
  assert.match(SRC, /updateGoal\(\{ auditHistory: history, pendingCompletion: undefined \}, liveCtx\)/);
  // 5. quota-again → re-pause with the claim PRESERVED + another scheduled retry:
  assert.match(SRC, /auditor quota: retry in \$\{quota\.retryAfterSec\}s \(stored-claim retry\)/);
  // 6. any other verdict hands back to the agent:
  assert.match(SRC, /appendLedger\(liveCtx\.cwd, "quota_retry_audit_verdict", \{/);
});

test("v0.28.26: pendingCompletion typed + schematized", () => {
  const CORE = fs.readFileSync("extensions/goal-loop-core.ts", "utf-8");
  assert.match(CORE, /pendingCompletion\?: \{ completionSummary\?: string; verificationSummary\?: string; at: string \};/);
  const SCHEMA = fs.readFileSync("schemas/goal.schema.json", "utf-8");
  assert.match(SCHEMA, /"pendingCompletion": \{ "type": "object" \}/);
});
