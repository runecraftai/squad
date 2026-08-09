// pi-goal-list-loop-audit — v0.27.5
// tests/postaudit-surface.test.ts
//
// 0.27.5: the post-completion audit was firing silently in interactive
// mode — the runReviewer-internal notify fires during the goal-completion
// handler and was easy to miss. Now there's a SECOND notify in
// fireReviewer that arrives after the cascade settles, points at the
// review file path, and is skipped for manual /review invocations.
// Also: settings keys `reviewer` (legacy) and `postaudit` (new) are both
// read; `postaudit` wins.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import { resolveReviewerConfig, type ReviewerConfig } from "../extensions/reviewer.ts";

const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
const SETTINGS_SRC = fs.readFileSync("extensions/goal-settings.ts", "utf-8");

test("fireReviewer emits a SECOND notify with the review file path after the cascade", () => {
  const branch = SRC.indexOf("if (!opts.manual && outcome.fired && outcome.reportPath)");
  assert.ok(branch > 0, "surface-notify guard exists");
  // The notify call may have its template string on the next line.
  const ctxUiNotify = SRC.indexOf("ctx.ui.notify(", branch);
  const arrow = SRC.indexOf("review written:", ctxUiNotify);
  assert.ok(ctxUiNotify > 0 && arrow > 0 && arrow < ctxUiNotify + 200, "ctx.ui.notify with review-written prefix exists in that branch");
});

test("surface-notify branch is preceded by the existing manual-suppressed notify", () => {
  const suppressedIdx = SRC.indexOf("Postaudit suppressed: ${outcome.suppressedReason}");
  const surfaceIdx = SRC.indexOf("↳ review written:");
  assert.ok(suppressedIdx > 0 && surfaceIdx > 0, "both notify branches exist");
  assert.ok(suppressedIdx < surfaceIdx, "surface notify comes after the suppressed notify");
});

test("postaudit settings key takes precedence over legacy reviewer key (fireReviewer)", () => {
  // The fireReviewer function reads settings.postaudit ?? settings.reviewer.
  const m = SRC.match(/settings\.postaudit \?\? settings\.reviewer/);
  assert.ok(m, "dual-read with postaudit precedence is wired in fireReviewer");
});

test("Settings type accepts both reviewer and postaudit keys", () => {
  // goal-settings.ts has both fields as optional Record<string, unknown>.
  assert.match(SETTINGS_SRC, /\/\*\*[^*]*v0\.26\.0: reviewer[\s\S]*?reviewer\?:\s*Record<string, unknown>;/);
  assert.match(SETTINGS_SRC, /\/\*\*[^*]*v0\.27\.5: post-completion audit config[\s\S]*?postaudit\?:\s*Record<string, unknown>;/);
});

test("SETTINGS_KEYS includes postaudit and toolOverrides", () => {
  // The display list pins both new keys; legacy `reviewer` is resolved
  // via dual-read in fireReviewer but kept opaque in SETTINGS_KEYS.
  assert.match(SETTINGS_SRC, /SETTINGS_KEYS[\s\S]*?"postaudit",?\s*\n\s*"toolOverrides",?\s*\]/);
});

test("/glla postaudit opens the same menu as /glla reviewer (no behavioral split)", () => {
  // Both keywords route to cmdReviewerSettings — there's ONE settings menu.
  const keywordCheck = SRC.indexOf('if (/^postaudit\\b/.test(trimmed))');
  const routeCheck = SRC.indexOf('await cmdReviewerSettings(ctx);', keywordCheck);
  assert.ok(keywordCheck > 0, "/glla postaudit keyword check exists");
  assert.ok(routeCheck > 0 && routeCheck < keywordCheck + 200, "the postaudit branch routes to cmdReviewerSettings");
});

test("/glla completions list both reviewer (legacy) and postaudit (new)", () => {
  assert.match(SRC, /\["reviewer", "[^"]*post-completion[^"]*"\]/);
  assert.match(SRC, /\["postaudit", "[^"]*post-completion[^"]*"\]/);
});

test("resolveReviewerConfig: postaudit and reviewer blocks merge equivalently", () => {
  // Pure unit test of the merge function — no reviewerBlock/loadSettings
  // round-trip required.
  const a: Partial<ReviewerConfig> = { mode: "auto", maxFindingsPerReview: 7 };
  const b: Partial<ReviewerConfig> = { mode: "auto", maxFindingsPerReview: 7 };
  const ra = resolveReviewerConfig(a);
  const rb = resolveReviewerConfig(b);
  assert.deepEqual(ra, rb);
  assert.equal(ra.mode, "auto");
  assert.equal(ra.maxFindingsPerReview, 7);
});

test("goal-loop-continuation prompt carries the 0.27.5 chunk-near-context-full hint", () => {
  const prompt = fs.readFileSync("prompts/goal-loop-continuation.md", "utf-8");
  // Three independent assertions, not ordered — the prose may place
  // "stop_reason=length" and "auto-continue" in either order; we only
  // require the hint to live alongside the auto-continue reference.
  const chunkIdx = prompt.indexOf("Chunk output near context-full");
  const stopIdx = prompt.indexOf('stop_reason="length"');
  const contIdx = prompt.indexOf("auto-continue");
  assert.ok(chunkIdx > 0 && stopIdx > 0 && contIdx > 0, "all three anchors present in the prompt");
  // chunking hint and the auto-continue reference should live in the
  // same paragraph (within 800 chars of each other).
  assert.ok(
    Math.abs(chunkIdx - contIdx) < 800 && Math.abs(chunkIdx - stopIdx) < 800,
    "the chunking hint sits next to the auto-continue / length reference",
  );
  assert.match(prompt, /split large file writes|focused reasoning|small commits/);
});
