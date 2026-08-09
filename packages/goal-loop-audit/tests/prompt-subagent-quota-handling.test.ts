// pi-goal-list-loop-audit — v0.25.0
// tests/prompt-subagent-quota-handling.test.ts
//
// Eager-continuation contract item 38 (Section J): the continuation prompt
// teaches quota-error recognition for subagent failures.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";

const prompt = fs.readFileSync(
  path.resolve("prompts", "goal-loop-continuation.md"),
  "utf-8",
);

test("continuation prompt mentions key limit / quota pattern (item 38)", () => {
  assert.match(prompt, /Key limit exceeded|429|rate.?limit/i);
  assert.match(prompt, /subagent|spawn/i);
  assert.match(prompt, /inherit.?parent|switch.?model/i);
});

test("continuation prompt warns against re-spawning the failed type", () => {
  assert.match(prompt, /WHEN SUBAGENTS HIT QUOTA ERRORS/);
  assert.match(prompt, /Do NOT spawn more subagents/i);
});
