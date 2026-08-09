// pi-goal-list-loop-audit — v0.26.9
// tests/autoresume-default.test.ts
//
// "Don't auto-start on session LOAD; continue forever DURING the session
// unless big stuck." The restore gate is a tri-state: on = always
// auto-resume (unattended rigs), off = never, default (undefined) = hold
// when a human loads a session, auto-resume on in-session machinery
// (reload/fork). Mid-session continuation is not gated at all.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");

test("/glla autoresume=off persists explicit false (tri-state, not undefined)", () => {
  assert.match(SRC, /patch\.autoResume = false; \/\/ v0\.26\.8: explicit off must persist/);
  assert.doesNotMatch(SRC, /patch\.autoResume = undefined;/);
});

test("status display shows the tri-state honestly", () => {
  assert.match(SRC, /autoResume=\$\{effective\.autoResume === true \? "on" : effective\.autoResume === false \? "off" : "default \(hold on load\)"\}/);
});

test("hold-on-load text offers the explicit resume + the on opt-in", () => {
  assert.match(SRC, /restored on session load — held for explicit resume/);
  assert.match(SRC, /\/glla autoresume=on to auto-resume/);
});
