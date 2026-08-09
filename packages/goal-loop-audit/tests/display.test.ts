// pi-goal-list-loop-audit — v0.9.0
// tests/display.test.ts
//
// Unit tests for the live-TUI display builders: status line + widget lines.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

import {
  buildStatusText,
  buildWidgetLines,
  fmtElapsed,
  fmtTokens,
  truncate,
} from "../extensions/goal-loop-display.ts";
import type { Goal, State } from "../extensions/goal-loop-core.ts";
import type { LoopState } from "../extensions/goal-loop-forever.ts";

const NOW = Date.parse("2026-07-21T12:00:00Z");

function goalOf(overrides: Partial<Goal> = {}): Goal {
  return {
    id: "20260721120000-abcdef",
    objective: "Create x.txt containing ok",
    status: "active",
    policy: "goal",
    autoContinue: true,
    usage: { tokensUsed: 12_400, tokensLimit: 1_000_000 },
    createdAt: "2026-07-21T11:57:00Z",
    updatedAt: "2026-07-21T11:57:00Z",
    ...overrides,
  };
}

// ---- formatters ----

test("fmtElapsed", () => {
  assert.equal(fmtElapsed(500), "0s");
  assert.equal(fmtElapsed(45_000), "45s");
  assert.equal(fmtElapsed(180_000), "3m 00s");
  assert.equal(fmtElapsed(3_900_000), "1h 05m");
});

test("fmtTokens", () => {
  assert.equal(fmtTokens(500), "500");
  assert.equal(fmtTokens(12_400), "12.4k");
  assert.equal(fmtTokens(1_000_000), "1000k");
});

test("truncate", () => {
  assert.equal(truncate("short", 10), "short");
  assert.equal(truncate("a much longer string", 8), "a much …");
});

// ---- buildStatusText ----

test("empty state → undefined (segment cleared)", () => {
  assert.equal(buildStatusText({ goal: null, list: [] }, null, NOW), undefined);
});

test("active goal shows pulse + elapsed", () => {
  const s = buildStatusText({ goal: goalOf(), list: [] }, null, NOW)!;
  assert.match(s, /glla: goal ●/);
  assert.match(s, /3m/);
});

test("active goal with tasks shows progress", () => {
  const g = goalOf({
    taskList: {
      version: 1,
      tasks: [
        { id: "1", title: "a", status: "complete" },
        { id: "2", title: "b", status: "pending" },
      ],
    },
  });
  assert.match(buildStatusText({ goal: g, list: [] }, null, NOW)!, /1\/2 tasks/);
});

test("widget truncation is width-aware (v0.22.2)", () => {
  const longObjective = "x".repeat(200);
  const g = goalOf({ objective: longObjective });
  // No width (tests/RPC): floor cap applies.
  const narrow = buildWidgetLines({ goal: g, list: [] }, null, NOW)![0]!;
  assert.equal(narrow.length, 2 + 64); // icon + space + 63 chars + ellipsis
  // Wide terminal: the head uses the room instead of cutting at 64.
  const wide = buildWidgetLines({ goal: g, list: [] }, null, NOW, undefined, 160)![0]!;
  assert.ok(wide.length > 100, `wide head should exceed 100 chars, got ${wide.length}`);
  assert.ok(wide.length <= 160, `wide head must not exceed the terminal width, got ${wide.length}`);
  // Narrow terminal: never below the floor.
  const tiny = buildWidgetLines({ goal: g, list: [] }, null, NOW, undefined, 50)![0]!;
  assert.equal(tiny.length, narrow.length);
});

test("list policy footer: queued count, no duplicated 'list'", () => {
  const s = buildStatusText(
    { goal: goalOf({ policy: "list" }), list: [{ id: "x", objective: "y", addedAt: "z" }] },
    null,
    NOW,
  )!;
  // v0.24.7: was "glla: list ● 3m 00s · list 1" — policy label and queue
  // counter both said "list".
  assert.match(s, /^glla: list /);
  assert.match(s, /· 1 queued$/);
  assert.ok(!/list .+ list /.test(s), `no duplicated 'list … list': ${s}`);
});

test("goal policy footer says 'N queued' (v0.28.11 U10 — was the cryptic 'list N')", () => {
  const s = buildStatusText(
    { goal: goalOf(), list: [{ id: "x", objective: "y", addedAt: "z" }] },
    null,
    NOW,
  )!;
  assert.match(s, /^glla: goal /);
  assert.match(s, /· 1 queued$/);
});

test("widget names a list item as such and points at /list, not /goal", () => {
  const lines = buildWidgetLines(
    {
      goal: goalOf({ policy: "list", usage: undefined }),
      list: [
        { id: "a", objective: "one", addedAt: "z" },
        { id: "b", objective: "two", addedAt: "z" },
      ],
    },
    null,
    NOW,
  )!;
  assert.match(lines[1]!, /^├─ list item · active /);
  assert.equal(lines[lines.length - 1], "└─ 2 queued · /list · /glla");
  assert.ok(!lines.some(l => l.includes("/goal status")), "list item must not hint /goal status");
});

test("widget list item, last in queue: no '0 queued'", () => {
  const lines = buildWidgetLines(
    { goal: goalOf({ policy: "list", usage: undefined }), list: [] },
    null,
    NOW,
  )!;
  assert.equal(lines[lines.length - 1], "└─ /list · /glla");
});

test("widget goal policy keeps /goal status hint + list N prefix", () => {
  const lines = buildWidgetLines(
    {
      goal: goalOf({ usage: undefined }),
      list: [{ id: "a", objective: "one", addedAt: "z" }],
    },
    null,
    NOW,
  )!;
  assert.match(lines[1]!, /^├─ goal · active /);
  assert.equal(lines[lines.length - 1], "└─ 1 queued · /goal status · /glla");
});

test("paused shows the reason", () => {
  const g = goalOf({ status: "paused", pauseReason: "auditor disapproved: missing tests" });
  assert.match(buildStatusText({ goal: g, list: [] }, null, NOW)!, /paused ⏸ auditor disapproved/);
});

test("auditing shows the auditor's current tool", () => {
  const g = goalOf({ status: "auditing" });
  const s = buildStatusText({ goal: g, list: [] }, { currentTool: "read" }, NOW)!;
  assert.match(s, /auditing…/);
  assert.match(s, /read/);
});

test("complete goal clears the segment", () => {
  assert.equal(buildStatusText({ goal: goalOf({ status: "complete" }), list: [] }, null, NOW), undefined);
});

test("active loop shows iteration + best + stall", () => {
  const loop: LoopState = {
    target: "reduce TODOs",
    measureCmd: "grep -c TODO x",
    direction: "min",
    iteration: 12,
    maxIterations: 50,
    plateauWindow: 5,
    stallCount: 2,
    bestValue: 41,
    lastValue: 43,
    active: true,
    history: [],
    startedAt: "2026-07-21T11:00:00Z",
  };
  const s = buildStatusText({ goal: null, list: [], loop }, null, NOW)!;
  assert.match(s, /loop ↓ iter 12\/50/);
  assert.match(s, /best 41/);
  assert.match(s, /stall 2\/5/);
});

// ---- buildWidgetLines ----

test("widget: nothing supervised → undefined", () => {
  assert.equal(buildWidgetLines({ goal: null, list: [] }, null, NOW), undefined);
});

test("widget: goal lines include objective, status, tokens, footer", () => {
  const lines = buildWidgetLines({ goal: goalOf(), list: [] }, null, NOW)!;
  assert.match(lines[0]!, /● Create x.txt containing ok/);
  assert.ok(lines.some((l) => l.includes("12.4k/1000k tok")));
  assert.ok(lines.some((l) => l.includes("/goal status")));
});

test("widget: paused goal shows reason + suggestion", () => {
  const g = goalOf({
    status: "paused",
    pauseReason: "no tests found",
    pauseSuggestedAction: "add tests dir",
  });
  const lines = buildWidgetLines({ goal: g, list: [] }, null, NOW)!;
  assert.ok(lines.some((l) => l.includes("no tests found")));
  assert.ok(lines.some((l) => l.includes("add tests dir")));
});

test("widget: auditing shows auditor progress", () => {
  const g = goalOf({ status: "auditing" });
  const lines = buildWidgetLines({ goal: g, list: [] }, { label: "verifying contract", currentTool: "grep", elapsedMs: 42_000 }, NOW)!;
  assert.ok(lines.some((l) => l.includes("verifying contract")));
  assert.ok(lines.some((l) => l.includes("grep")));
  assert.ok(lines.some((l) => l.includes("42s")));
});

test("widget: loop lines include measure + metric state", () => {
  const loop: LoopState = {
    target: "reduce TODOs",
    measureCmd: "grep -c TODO src.txt | head -1",
    direction: "min",
    iteration: 3,
    maxIterations: 12,
    plateauWindow: 3,
    stallCount: 1,
    bestValue: 2,
    lastValue: 3,
    active: true,
    history: [],
    startedAt: "2026-07-21T11:00:00Z",
    branchName: "pi-glla-loop/20260721-reduce-todos",
  };
  const lines = buildWidgetLines({ goal: null, list: [], loop }, null, NOW)!;
  assert.ok(lines.some((l) => l.includes("reduce TODOs")));
  assert.ok(lines.some((l) => l.includes("iter 3/12")));
  assert.ok(lines.some((l) => l.includes("best 2")));
  assert.ok(lines.some((l) => l.includes("pi-glla-loop/20260721-reduce-todos")));
});

// ---- v0.28.17: held loops are always visible ----

function heldLoopOf(overrides: Partial<LoopState> = {}): LoopState {
  return {
    target: "improve search ranking",
    measureCmd: "bun test --score",
    direction: "max",
    iteration: 7,
    maxIterations: 0,
    plateauWindow: 5,
    stallCount: 0,
    bestValue: 88,
    lastValue: 85,
    active: false,
    stopReason: "held: restored in a fresh session",
    history: [],
    startedAt: "2026-07-21T10:00:00Z",
    ...overrides,
  };
}

test("held loop alone → status segment + widget card (before: BOTH vanished)", () => {
  const state = { goal: null, list: [], loop: heldLoopOf() };
  const s = buildStatusText(state, null, NOW)!;
  assert.match(s, /loop ⏸ held/);
  assert.match(s, /iter 7/);
  assert.match(s, /\/loop to resume/);
  const w = buildWidgetLines(state, null, NOW)!;
  assert.ok(w, "widget shows the held-loop card");
  assert.match(w[0]!, /improve search ranking/);
  assert.match(w[1]!, /loop held · iter 7/);
  assert.match(w[2]!, /restore gate/);
});

test("held loop + paused goal → both visible (status suffix + widget trailing line)", () => {
  const state = { goal: goalOf({ status: "paused", pauseReason: "user paused" }), list: [], loop: heldLoopOf() };
  const s = buildStatusText(state, null, NOW)!;
  assert.match(s, /paused/);
  assert.match(s, /loop⏸held/, "held-loop suffix rides the paused-goal status");
  const w = buildWidgetLines(state, null, NOW)!;
  assert.match(w.join("\n"), /loop held · iter 7 — \/loop to resume/);
});

test("held loop + active goal → status suffix present", () => {
  const state = { goal: goalOf(), list: [], loop: heldLoopOf() };
  const s = buildStatusText(state, null, NOW)!;
  assert.match(s, /goal ●/);
  assert.match(s, /loop⏸held/);
});

test("held loop + completed goal → held loop still shows (goal state clears)", () => {
  const state = { goal: goalOf({ status: "complete" }), list: [], loop: heldLoopOf() };
  assert.match(buildStatusText(state, null, NOW)!, /loop ⏸ held/);
  assert.ok(buildWidgetLines(state, null, NOW)!.length >= 2);
});

test("active loop unchanged; stopped loop stays invisible", () => {
  const active = { goal: null, list: [], loop: heldLoopOf({ active: true, stopReason: undefined }) };
  const s = buildStatusText(active, null, NOW)!;
  assert.match(s, /loop ↑ iter 7/, "active loop renders exactly as before");
  assert.doesNotMatch(s, /held/);
  const stopped = { goal: null, list: [], loop: heldLoopOf({ stopReason: "stopped by user (/loop stop)" }) };
  assert.equal(buildStatusText(stopped, null, NOW), undefined, "a genuinely stopped loop stays invisible");
  assert.equal(buildWidgetLines(stopped, null, NOW), undefined);
});

// ---- v0.28.22: pause-kind rendering (decision / error / wait) ----

test("decision pause: banner + numbered options + recommended flagged (widget + status)", () => {
  const g = goalOf({
    status: "paused",
    pauseKind: "decision",
    pauseReason: "The auditor disapproved completion — SUPERSEDED rows don't match the objective text.",
    pauseOptions: ["surgical Done when: clause", "deliver the missing polish (~2-3 hours)", "reword objective to accept SUPERSEDED"],
    pauseRecommended: 3,
    pauseSuggestedAction: "Pick one, then /goal resume.",
  });
  const state = { goal: g, list: [], loop: null };
  const w = buildWidgetLines(state as never)!;
  assert.ok(w.some((l) => l.includes("decision needed — your call unblocks this")), `decision banner: ${w.join("\n")}`);
  assert.ok(w.some((l) => l.includes("1. surgical Done when: clause")), "option 1 numbered");
  assert.ok(w.some((l) => l.includes("3. reword objective to accept SUPERSEDED ◂ recommended")), "recommended flagged");
  const s = buildStatusText(state as never)!;
  assert.ok(s.includes("decision needed"), `status: ${s}`);
  assert.ok(!s.includes("SUPERSEDED rows"), "status names the actionability, not the reason");
});

test("error pause: ACTION NEEDED banner, action line popped (widget + status)", () => {
  const g = goalOf({
    status: "paused",
    pauseKind: "error",
    pauseReason: "send-retry storm: 5m of 50ms re-arms — the session never went idle",
    pauseSuggestedAction: "Restart pi, then /goal resume.",
  });
  const state = { goal: g, list: [], loop: null };
  const w = buildWidgetLines(state as never)!;
  assert.ok(w.some((l) => l.includes("action needed — this won't fix itself")), `error banner: ${w.join("\n")}`);
  const s = buildStatusText(state as never)!;
  assert.ok(s.includes("action needed"), `status: ${s}`);
});

test("wait pause: quiet banner + resume countdown (widget + status)", () => {
  const g = goalOf({
    status: "paused",
    pauseKind: "wait",
    pauseReason: "auditor quota: rate limited",
    pauseResumeAt: new Date(Date.now() + 23 * 3600_000).toISOString(),
    pauseSuggestedAction: "Quota auto-retry — or /goal resume now",
  });
  const state = { goal: g, list: [], loop: null };
  const w = buildWidgetLines(state as never)!;
  assert.ok(w.some((l) => l.includes("waiting — nothing for you to do")), `wait banner: ${w.join("\n")}`);
  assert.ok(w.some((l) => /resumes .*\(in 23h/.test(l)), `countdown: ${w.join("\n")}`);
  const s = buildStatusText(state as never)!;
  assert.ok(s.includes("waiting") && s.includes("resumes"), `status: ${s}`);
});

test("legacy pause (no kind): flat card unchanged; error-regex still classifies the status line", () => {
  const g = goalOf({ status: "paused", pauseReason: "user paused for review", pauseSuggestedAction: "/goal resume" });
  const state = { goal: g, list: [], loop: null };
  const w = buildWidgetLines(state as never)!;
  assert.ok(!w.some((l) => l.includes("unblocks this") || l.includes("won't fix itself") || l.includes("nothing for you to do")), "no banner without a kind");
  const g2 = goalOf({ status: "paused", pauseReason: "token limit exceeded (10 > 5)" });
  const s2 = buildStatusText({ goal: g2, list: [], loop: null } as never)!;
  assert.ok(s2.includes("action needed"), `legacy error reason → action needed: ${s2}`);
});

test("v0.28.30: the widget card status line ALWAYS names the type (goal · / list item ·)", () => {
  // User note: "I don't always see the type — I'd need to scroll up to see
  // if goal/list/loop." Before, only list items were named on the card.
  const goalLines = buildWidgetLines({ goal: goalOf({}), list: [] }, null, NOW)!;
  assert.match(goalLines[1]!, /^├─ goal · active /);
  const listLines = buildWidgetLines({ goal: goalOf({ policy: "list" }), list: [] }, null, NOW)!;
  assert.match(listLines[1]!, /^├─ list item · active /);
  const SRC = fs.readFileSync("extensions/goal-loop-display.ts", "utf-8");
  assert.match(SRC, /const typeWord = isList \? "list item · " : "goal · ";/);
});
