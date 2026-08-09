// pi-goal-list-loop-audit — v0.25.0
// tests/pause-auto-commit.test.ts
//
// Eager-continuation contract item 31 (Section H): the auto-committer
// sentinel — the agent writes .pi-glla/.pause-auto-commit when it detects
// the daemon rewriting its commits; the daemon's filter checks for it.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  pauseAutoCommit,
  resumeAutoCommit,
  isAutoCommitPaused,
  PAUSE_AUTO_COMMIT_SENTINEL,
} from "../extensions/goal-loop-core.ts";

test("pauseAutoCommit writes the sentinel; isAutoCommitPaused sees it (item 31)", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-pac-"));
  assert.equal(isAutoCommitPaused(dir), false);
  const file = pauseAutoCommit(dir, "filter-branch rewrote my commits twice");
  assert.equal(path.basename(file), PAUSE_AUTO_COMMIT_SENTINEL);
  assert.equal(isAutoCommitPaused(dir), true);
  const content = fs.readFileSync(file, "utf-8");
  assert.match(content, /pausedAt: /);
  assert.match(content, /reason: filter-branch rewrote my commits twice/);
});

test("resumeAutoCommit removes the sentinel (item 31)", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-pac-"));
  pauseAutoCommit(dir, "test");
  assert.equal(resumeAutoCommit(dir), true);
  assert.equal(isAutoCommitPaused(dir), false);
  // Removing twice is a no-op, not an error.
  assert.equal(resumeAutoCommit(dir), false);
});
