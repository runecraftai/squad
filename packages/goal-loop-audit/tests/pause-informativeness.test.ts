// pi-goal-list-loop-audit — v0.27.1
// tests/pause-informativeness.test.ts
//
// "We are pretty uninformative when the execution pauses." A decision-pause
// (pause_goal with reason + suggested action) reached the user truncated at
// ~60 chars — the actual choice was unreadable. Now: the widget WRAPS the
// reason/action over up to 3 lines each, a "saved — … · resumes exactly
// here" line answers "did I lose the work?", and the pause-time
// notification carries the FULL reason + action.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import { wrap, buildWidgetLines } from "../extensions/goal-loop-display.ts";
import type { Goal, State } from "../extensions/goal-loop-core.ts";

function pausedGoal(over: Partial<Goal> = {}): Goal {
  return {
    id: "g1", objective: "fix the thing", policy: "goal", status: "paused",
    createdAt: new Date(Date.now() - 60_000).toISOString(),
    pauseReason: "Paused to surface a dedup issue: when list_add was called with the 15 audit findings, items 1-2 (worldAimY + BOOST_*) were ALREADY on the list from a prior list_add call that triggered this audit",
    pauseSuggestedAction: "Choose: (a) keep both and mark them as the same work; (b) regenerate the list fresh",
    ...over,
  } as Goal;
}
const stateOf = (g: Goal): State => ({ goal: g }) as State;

test("wrap: short text stays one line; long text wraps at width; cap ellipsizes", () => {
  assert.deepEqual(wrap("hello world", 60, 3), ["hello world"]);
  const w = wrap("one two three four five six seven eight nine ten", 15, 3);
  assert.ok(w.every((l) => l.length <= 15), JSON.stringify(w));
  assert.ok(w.length > 1);
  const capped = wrap("word ".repeat(200), 20, 3);
  assert.equal(capped.length, 3);
  assert.ok(capped[2]!.endsWith("…"), "truncation marker on the last line");
  // over-long single word is hard-split
  assert.deepEqual(wrap("x".repeat(45), 20, 3), ["x".repeat(20), "x".repeat(20), "xxxxx"]);
});

test("paused card wraps the reason over multiple lines instead of truncating at 60", () => {
  const lines = buildWidgetLines(stateOf(pausedGoal()), null, Date.now(), undefined, 100)!;
  const reasonLines = lines.filter((l) => l.includes("dedup") || l.includes("ALREADY on the list") || l.includes("triggered this audit"));
  assert.ok(reasonLines.length >= 2, `reason wrapped over >= 2 lines: ${JSON.stringify(lines)}`);
  assert.ok(lines.every((l) => !l.endsWith("…") || l.includes("triggered this audit") === false), "reason not truncated at 60");
});

test("paused card answers 'did I lose the work?' with a saved line", () => {
  const g = pausedGoal({ usage: { tokensUsed: 41200, tokensLimit: 0 }, auditHistory: [{ approved: true }, { approved: false }, { approved: true }] as any });
  const lines = buildWidgetLines(stateOf(g), null, Date.now(), undefined, 100)!;
  assert.ok(lines.some((l) => l.includes("saved — 41.2k tok spent · 3 audits · resumes exactly here")), JSON.stringify(lines));
  // nothing spent yet → "awaiting first turn" (literal contract text)
  const bare = buildWidgetLines(stateOf(pausedGoal()), null, Date.now(), undefined, 100)!;
  assert.ok(bare.some((l) => l.includes("awaiting first turn — resumes exactly here")), JSON.stringify(bare));
});

test("paused card wraps the suggested action and closes the branch on its last line", () => {
  const lines = buildWidgetLines(stateOf(pausedGoal()), null, Date.now(), undefined, 100)!;
  assert.ok(lines.some((l) => l.startsWith("└─") && l.includes("regenerate the list fresh")), JSON.stringify(lines));
});

test("pause_goal tool notification carries the FULL reason AND suggested action", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.match(src, /ctx\.ui\.notify\(`\$\{goalNoun\(\)\} paused: \$\{p\.reason\}\$\{p\.suggestedAction \? `\\n\\n→ \$\{p\.suggestedAction\}`/);
  // external push carries both too (bounded)
  assert.match(src, /notifyExternal\(ctx, `\$\{goalNoun\(\)\} paused: \$\{\(p\.suggestedAction/);
});

const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");

test("pause_goal tool: structured kind/options/recommended/resumeAt persist to the goal (v0.28.22)", () => {
  // Source pin — the behavioral harness's runTool writes through the
  // registration ctx, not the test ctx, so a full e2e persistence assert
  // is order-fragile. The rendering half is pinned in display.test.ts.
  assert.match(SRC, /pauseKind: p\.kind,/);
  assert.match(SRC, /pauseOptions: p\.kind === "decision" && p\.options && p\.options\.length > 0 \? p\.options : undefined,/);
  assert.match(SRC, /pauseRecommended: p\.kind === "decision" && p\.recommended && p\.recommended >= 1 \? Math\.floor\(p\.recommended\) : undefined,/);
  assert.match(SRC, /pauseResumeAt: p\.kind === "wait" && p\.resumeAt \? p\.resumeAt : undefined,/);
  // Resume clears the new fields alongside the old ones.
  assert.match(SRC, /pauseKind: undefined, pauseOptions: undefined, pauseRecommended: undefined, pauseResumeAt: undefined/);
  // The extension's own pauses are classified at the source.
  const pairs: Array<[string, string]> = [
    ["pauseReason: `send-retry storm", "error"],
    ["pauseReason: `stalled: ${threshold} continuation refires", "error"],
    ["pauseReason: `auditor verdict: IMPOSSIBLE —", "decision"],
    ["pauseReason: `auditor quota:", "wait"],
    ["pauseReason: `auditor infrastructure failed", "error"],
    ["pauseReason: `auditor disapproved ${trailingDisapprovals}× consecutively", "decision"],
    ["pauseReason: `token limit exceeded", "error"],
    ["pauseReason: \"5 consecutive aborts", "blocked"],
    ["pauseReason: \"restored on session load", "blocked"],
  ];
  for (const [anchor, kind] of pairs) {
    const esc = anchor.replace(/[.*+?^$()[\]\\|]/g, "\\$&");
    assert.match(SRC, new RegExp(`pauseKind: "${kind}",[\\s\\S]{0,500}?${esc}`), `${anchor} → pauseKind ${kind}`);
  }
});

test("pause_goal description: teaches the real command surface + no-id vocabulary (v0.28.24)", () => {
  const m = SRC.match(/name: "pause_goal",[\s\S]{0,1400}?parameters:/);
  assert.ok(m, "pause_goal registration found");
  const desc = m![0];
  assert.match(desc, /\/list remove N/, "enumerates the real /list command");
  assert.match(desc, /NO \/goal drop|no \/goal drop/i, "kills the hallucinated command");
  assert.match(desc, /no command takes a goal id|NO command takes a goal id/i);
  assert.match(desc, /never show goal ids/i);
});

test("v0.28.30: pause/abort notifies name the policy (List item vs Goal) via goalNoun", () => {
  // User note: "we seem to call everything goal". A list item is not a goal.
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.match(src, /const goalNoun = \(\): string => \(state\.goal\?\.policy === "list" \? "List item" : "Goal"\);/);
  const occurrences = src.split("${goalNoun()}").length - 1;
  assert.ok(occurrences >= 10, `goalNoun used across the notify surface (${occurrences} sites)`);
  assert.match(src, /`\$\{goalNoun\(\)\} aborted\./);
  assert.match(src, /`\$\{goalNoun\(\)\} appears wedged/);
});
