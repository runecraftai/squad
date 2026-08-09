// pi-goal-list-loop-audit — v0.25.0
// tests/auditor-shift-acceptance.test.ts
//
// Eager-continuation contract item 16 (Section D): the auditor prompt
// teaches objective-shift acceptance.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";

const src = fs.readFileSync(
  path.resolve("extensions", "goal-loop-auditor.ts"),
  "utf-8",
);

test("auditor prompt contains shift-acceptance language (item 16)", () => {
  assert.match(src, /shift/i);
  assert.match(src, /independently verified/i);
  assert.match(src, /Do NOT rigidly/i);
});

test("shift acceptance requires explicit executor statement + justification", () => {
  assert.match(src, /explicitly states that the work has shifted/i);
  assert.match(src, /justified/i);
});
