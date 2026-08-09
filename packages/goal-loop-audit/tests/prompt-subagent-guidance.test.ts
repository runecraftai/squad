// pi-goal-list-loop-audit — v0.25.0
// tests/prompt-subagent-guidance.test.ts
//
// Eager-continuation contract item 4: all four agent-facing prompts lead
// with subagent guidance — the phrases the fan-out behavior depends on.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";

const PROMPTS = [
  "goal-loop-continuation.md",
  "goal-loop-draft.md",
  "goal-loop-forever.md",
  "goal-loop-forever-metricless.md",
];

function readPrompt(name: string): string {
  return fs.readFileSync(path.resolve("prompts", name), "utf-8");
}

for (const name of PROMPTS) {
  test(`${name}: contains subagent fan-out guidance (item 4)`, () => {
    const p = readPrompt(name);
    assert.match(p, /Agent/, `${name} mentions the Agent tool`);
    assert.ok(
      /Default to subagents|in parallel|parallel/i.test(p),
      `${name} says "Default to subagents" or "parallel"`,
    );
    assert.ok(
      /Eager continuation|just continue/i.test(p),
      `${name} says "Eager continuation" or "just continue"`,
    );
    assert.match(p, /Explore/, `${name} names the Explore agent`);
    assert.ok(/general-purpose|Plan/.test(p), `${name} names general-purpose or Plan`);
  });
}
