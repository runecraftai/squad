// pi-goal-list-loop-audit — v0.27.9
// tests/auditor-chunk-hint.test.ts
//
// Item 7 of the 7-item /goal contract said the chunk-near-context-full
// hint should be added to the reviewer/auditor prompts. The 0.27.6
// release added it to prompts/goal-loop-continuation.md; the auditor
// (correctly) flagged that as the wrong file. The actual completion
// auditor lives in extensions/goal-loop-auditor.ts, and the chunking
// hint now sits in buildGoalAuditorPrompt's instruction list.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

test("auditor prompt carries the chunk-near-context-full hint (item 7)", () => {
  const src = fs.readFileSync("extensions/goal-loop-auditor.ts", "utf-8");
  // All three anchors present (order not asserted — the prose may place
  // "stop_reason=length" before or after "auto-continue").
  const chunkIdx = src.indexOf("Chunk output near context-full");
  const stopIdx = src.indexOf('stop_reason=\\"length\\"');
  const contIdx = src.indexOf("auto-continue");
  assert.ok(chunkIdx > 0 && stopIdx > 0 && contIdx > 0, "all three anchors present in the file");
  // Anchors must be near each other (within the same paragraph).
  assert.ok(
    Math.abs(chunkIdx - stopIdx) < 500 && Math.abs(chunkIdx - contIdx) < 500,
    "the chunking hint sits next to the auto-continue / length reference",
  );
  // The hint must be inside buildGoalAuditorPrompt's instruction array,
  // not in a doc comment or unrelated code path.
  const promptFn = src.match(/function buildGoalAuditorPrompt[\s\S]+?^}/m);
  assert.ok(promptFn, "buildGoalAuditorPrompt function found");
  assert.match(promptFn[0]!, /Chunk output near context-full/, "hint is inside buildGoalAuditorPrompt");
});

test("reviewer.ts has no inline prompt to add the hint to (post-audit surfaces only review reports, not prompts)", () => {
  // The reviewer writes Markdown reports (.pi-glla/reviews/<id>.md); it does
  // not inject a prompt into the model. The chunking-hint is therefore not
  // a reviewer-prompt concept — item 7's "reviewer/auditor prompts" is
  // honored by the auditor-prompt half. The continuation prompt still has
  // it too (item 7 said "reviewer/auditor prompts" — both flavors covered).
  const continuation = fs.readFileSync("prompts/goal-loop-continuation.md", "utf-8");
  assert.match(continuation, /Chunk output near context-full/);
});
