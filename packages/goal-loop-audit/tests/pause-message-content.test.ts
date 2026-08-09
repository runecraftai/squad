// pi-goal-list-loop-audit — v0.25.0
// tests/pause-message-content.test.ts
//
// Eager-continuation contract item 20 (Section E): the audit-cap pause
// message guides investigation instead of "summarize and ask".

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";

const src = fs.readFileSync(
  path.resolve("extensions", "loops", "goal.ts"),
  "utf-8",
);

// The pause text is the template literal returned from the audit-cap branch.
function pauseText(): string {
  const m = src.match(/text: `The auditor has now disapproved[\s\S]*?`,/);
  if (!m) throw new Error("pause text not found in goal.ts");
  return m[0];
}

test("audit-cap pause message guides INVESTIGATION (item 20)", () => {
  const t = pauseText();
  assert.match(t, /INVESTIGATE/i);
  assert.match(t, /audit history|auditHistory/i);
  assert.match(t, /YOUR ASSESSMENT/i);
  assert.ok(t.length > 200, `pause text is substantive (${t.length} chars)`);
});

test("pause message no longer leads with 'summarize and ask' (item 19)", () => {
  const t = pauseText();
  assert.ok(!/Summarize the repeated objections for the user and ask how to proceed/.test(t));
});
