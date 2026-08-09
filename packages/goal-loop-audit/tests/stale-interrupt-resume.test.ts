// pi-goal-list-loop-audit — v0.28.1
// tests/stale-interrupt-resume.test.ts
//
// Pins the v0.28.1 stale-interruption rework (audit findings S1–S4, E6, T1 —
// audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md Stream 1):
//   S1  resume-in-stale-session zombie: cmdResume persisted status="active"
//       and claimed "Resumed goal", then the stale send failure re-paused
//       (or worse, left an active-in-ledger/dead-in-process zombie).
//   S2  stale-paused goals never auto-resumed: goStaleTerminal persisted
//       status="paused" while the session_start restore gate only
//       auto-resumes ACTIVE goals → manual /goal resume forever.
//   S3  no staleness probe at command entry: "created — starting now" and
//       "Resumed goal" were lies in doomed processes.
//   E6  the drafting-seed send failed SILENTLY (/goal + Enter → nothing).
//   T1  a stale Confirm dialog was reported as "Draft rejected by the user".
// Fix shape: goals STAY ACTIVE with an interruptedAt/interruptedReason
// marker (sendContinuation's extensionApiStale guard stops sends in the
// doomed process; the next fresh session auto-resumes and clears the
// marker); entry probes via the side-effect-free getSessionName() →
// pi assertActive() throw; honest messaging everywhere.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
const CORE = fs.readFileSync("extensions/goal-loop-core.ts", "utf-8");
const DISPLAY = fs.readFileSync("extensions/goal-loop-display.ts", "utf-8");
const SCHEMA = fs.readFileSync("schemas/goal.schema.json", "utf-8");

test("Goal type + schema carry the interrupt marker fields", () => {
  assert.match(CORE, /interruptedAt\?: string;/);
  assert.match(CORE, /interruptedReason\?: string;/);
  assert.match(SCHEMA, /"interruptedAt": \{ "type": "string" \}/);
  assert.match(SCHEMA, /"interruptedReason": \{ "type": "string" \}/);
});

test("S3 probe: side-effect-free getSessionName() probe caches the positive", () => {
  assert.match(SRC, /function probeExtensionApiStale\(\): boolean/);
  assert.match(SRC, /extensionApi\.getSessionName\(\);/);
  assert.match(SRC, /if \(isStaleApiError\(err\)\) extensionApiStale = true;/);
});

test("S3 warn helper: honest 'state is safe' messaging + ledger", () => {
  assert.match(SRC, /function warnIfStaleAtEntry\(ctx: ExtensionContext, what: string\): boolean/);
  assert.match(SRC, /State is safe in \.pi-glla\/ — restart pi and the active goal auto-resumes\./);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "extension_api_stale", \{ where: `entry probe \(\$\{what\}\)` \}\)/);
});

test("S3: probes wired at cmdSet / cmdResume / cmdList / propose_goal_draft entry", () => {
  assert.match(SRC, /const staleEntry = warnIfStaleAtEntry\(ctx, "\/goal"\);/, "cmdSet creation entry");
  assert.match(SRC, /const staleEntry = warnIfStaleAtEntry\(ctx, "\/goal resume"\);/, "cmdResume entry");
  assert.match(SRC, /warnIfStaleAtEntry\(ctx, "\/list"\);/, "cmdList entry");
  assert.match(SRC, /warnIfStaleAtEntry\(liveCtx, "goal drafting"\);/, "propose_goal_draft entry");
});

test("S3: stale creation marks the interrupt and tells the truth (no 'starting now' lie)", () => {
  assert.match(SRC, /updateGoal\(\{ interruptedAt: nowIso\(\), interruptedReason: "created in a stale session" \}, ctx\)/);
  assert.match(SRC, /safe in \.pi-glla\/, but this stale process can't send continuations\. Restart pi, then \/goal resume/);
});

test("S1: stale resume persists active+marker, skips the misleading notify and the doomed send", () => {
  assert.match(SRC, /interruptedReason: "resumed in a stale session"/);
  assert.match(SRC, /if \(staleEntry\) return;/);
});

test("S2: restore gate clears the marker on auto-resume and names the recovery", () => {
  assert.match(SRC, /const wasInterrupted = !!state\.goal\.interruptedAt;/);
  assert.match(SRC, /updateGoal\(\{ interruptedAt: undefined, interruptedReason: undefined \}, ctx\)/);
  assert.match(SRC, /auto-resumed after the stale-handle interrupt/);
});

test("S2 (v0.28.21): the 0.28.3 interrupt exemption is SUPERSEDED — only autoresume=on auto-resumes", () => {
  // Default flipped to hold-everything: interrupted goals hold like any
  // other; the marker is cleared only inside the autoresume=on path.
  assert.match(SRC, /if \(autoResume\) \{/);
  assert.doesNotMatch(SRC, /autoResume \|\| \(wasInterrupted && autoResumeSetting !== false\)/);
  assert.match(SRC, /const autoResumeSetting = resolveEffectiveAggressiveSettings\(loadSettings\(ctx\.cwd\)\)\.autoResume;/);
});

test("S1/S2: widget surfaces the interrupt on ACTIVE goals", () => {
  assert.match(DISPLAY, /if \(g\.interruptedAt\)/);
  assert.match(DISPLAY, /⚠ interrupted — stale handle · auto-resumes on pi restart/);
});

test("E6: drafting-seed send failure is loud and stale-aware (was silent)", () => {
  assert.match(SRC, /appendLedger\(ctx\.cwd, "extension_api_stale", \{ where: "startDrafting seed" \}\)/);
  assert.match(SRC, /can't start the drafting interview — this session's extension handle is stale/);
  assert.match(SRC, /couldn't start the drafting interview \(\$\{err instanceof Error \? err\.message : String\(err\)\}\) — try again\./);
});

test("T1: stale Confirm is NOT a rejection — both single and batch paths", () => {
  const honest = /This is NOT a rejection — do NOT refine or re-propose\. Tell the user to restart pi, then re-run the drafting flow\./;
  const matches = SRC.match(new RegExp(honest.source, "g")) ?? [];
  assert.equal(matches.length, 2, "single + batch confirm paths");
  assert.match(SRC, /appendLedger\(liveCtx\.cwd, "extension_api_stale", \{ where: "draft confirm" \}\)/);
  assert.match(SRC, /appendLedger\(liveCtx\.cwd, "extension_api_stale", \{ where: "batch confirm" \}\)/);
});

test("v0.28.27: stale handle silences ALL stall machinery — refiring into a dead process misleads, and the stall escalation would PAUSE an interrupted goal (killing restart auto-resume)", () => {
  // junk-runner field observation: compaction replaced the session mid-goal;
  // the footer promised "auto-resumes on pi restart" while the heartbeat
  // kept printing "re-firing continuation (stall 4/5)" into a process where
  // sends can never land — marching toward a stall-escalation pause that
  // would silently cancel that promise (paused restores load-held).
  const tick = SRC.indexOf("function heartbeatTick(): void {");
  const grace = SRC.indexOf("if (Date.now() < compactionGraceUntil) return;");
  const stale = SRC.indexOf("if (extensionApiStale) return;", grace); // line 213 has an earlier, unrelated terminal bail
  const watchdog = SRC.indexOf("pending-latch watchdog");
  assert.ok(tick > 0 && grace > tick && stale > grace, "stale bail inside heartbeatTick, after the grace gate");
  assert.ok(stale < SRC.indexOf("const fire = shouldHeartbeatRefire({"), "stale bail precedes the refire path");
  assert.ok(stale < watchdog, "stale bail precedes the latch watchdog too");
});

test("v0.28.27: /goal audit — manual auditor invocation with a synthesized claim, wired into the pendingCompletion machinery", () => {
  // Route: exact sub in the core router.
  const CORE = fs.readFileSync("extensions/goal-loop-core.ts", "utf-8");
  assert.match(CORE, /"decide", "audit"\]/);
  assert.match(CORE, /\| "audit" \| "tweak"/);
  // Dispatch: guards (no goal, audit in flight), seeds the synthesized
  // claim, ledgered, delegates to the shared engine with origin "manual".
  assert.match(SRC, /if \(route\.name === "audit"\) \{/);
  assert.match(SRC, /No active goal — \/goal audit needs a goal to verify\./);
  assert.match(SRC, /Manual audit requested by the user via \/goal audit \(no agent completion claim\)/);
  assert.match(SRC, /appendLedger\(ctx\.cwd, "manual_audit_requested", \{ goalId: state\.goal\.id \}\);/);
  assert.match(SRC, /void retryStoredCompletionAudit\(ctx, "manual"\);/);
  // Engine parametrized: origin flows into ledger + notifies + archive reason.
  assert.match(SRC, /origin: "quota-retry" \| "manual" = "quota-retry"/);
  assert.match(SRC, /via: origin === "manual" \? "manual-audit" : "quota-retry-direct-audit"/);
  assert.match(SRC, /approved \$\{origin === "manual" \? "on \/goal audit" : "on the quota retry"\}/.source.replace(" $", "\\$") ? /approved/ : /never/);
});
