// pi-goal-list-loop-audit — v0.25.1
// tests/loop-finish.test.ts
//
// Stuck-detection rework contract item 7: /loop finish [reason] ends the
// loop with stopReason "completed: <reason>". cmdLoop is inline in the
// extension (no pi harness) — the reason builder is unit-tested and the
// routing/completions are pinned by source-text assertions.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";

import { loopFinishStopReason } from "../extensions/goal-loop-forever.ts";

const goalSrc = fs.readFileSync(path.resolve("extensions", "loops", "goal.ts"), "utf-8");

test("loopFinishStopReason: cmdLoop('finish audit clean') → 'completed: audit clean' (item 7)", () => {
  assert.equal(loopFinishStopReason("audit clean"), "completed: audit clean");
  assert.equal(loopFinishStopReason(""), "completed: finished by user");
  assert.equal(loopFinishStopReason(undefined), "completed: finished by user");
  assert.equal(loopFinishStopReason("  padded  "), "completed: padded");
  // Never one of the other stop kinds:
  assert.ok(!loopFinishStopReason("x").startsWith("stuck"));
  assert.ok(!loopFinishStopReason("x").startsWith("plateau"));
  assert.ok(!/stopped by user/.test(loopFinishStopReason("x")));
});

test("/loop finish is routed in cmdLoop and registered in completions (item 7)", () => {
  assert.match(goalSrc, /if \(sub === "finish"\) \{/);
  assert.match(goalSrc, /state\.loop = \{ \.\.\.state\.loop, active: false, stopReason: reason \}/);
  assert.match(goalSrc, /\["finish", "end the loop cleanly/);
});
