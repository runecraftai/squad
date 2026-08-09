// pi-goal-list-loop-audit — v0.25.0
// tests/prompt-disagreement-guidance.test.ts
//
// Eager-continuation contract item 18 (Section E): the continuation prompt
// teaches investigate-before-asking when the auditor disapproves.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";

const prompt = fs.readFileSync(
  path.resolve("prompts", "goal-loop-continuation.md"),
  "utf-8",
);

test("continuation prompt has the WHEN THE AUDITOR DISAPPROVES section (item 18)", () => {
  assert.match(prompt, /WHEN THE AUDITOR DISAPPROVES/);
  assert.match(prompt, /investigate/i);
  assert.ok(
    /form a clear opinion|present the user/i.test(prompt),
    "prompt says form an opinion / present to the user",
  );
  assert.match(prompt, /YOUR ASSESSMENT/i);
});

test("disagreement guidance names the audit history as the source", () => {
  assert.match(prompt, /auditHistory|audit history/i);
});
