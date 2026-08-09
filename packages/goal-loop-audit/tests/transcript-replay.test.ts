// pi-goal-list-loop-audit — v0.25.1
// tests/transcript-replay.test.ts
//
// Stuck-detection rework contract item 11: replay the user's two
// wild-caught transcripts through the NEW detector. Both shipped real work
// AND carried a forward-transition marker while verification output was
// stable — the v0.24.0 single-signal detector killed both loops as
// "stuck". The fixtures use the phrasing quoted in
// audit/STUCK-DETECTION-REWORK-2026-07-24.md (## Problem Statement).

import { test } from "node:test";
import * as assert from "node:assert/strict";

import {
  detectLoopStuck,
  isActuallyStuck,
  textFingerprint,
  type LoopStuckInput,
} from "../extensions/goal-loop-repetition.ts";

function transcript(assistantText: string, fileWriteCount: number): LoopStuckInput {
  // Verification output stable: the same check command, same result, 3×.
  const h = textFingerprint("9 warnings, 0 errors");
  return {
    assistantText,
    recentPrints: ["p1", "p2", "p3"],
    recentToolResults: [
      { tool: "bash", hash: h, isError: false },
      { tool: "bash", hash: h, isError: false },
      { tool: "bash", hash: h, isError: false },
    ],
    toollessStreak: 0,
    fileWriteCount,
    gitCommitCount: 0,
    specItemProgressCount: 0,
  };
}

// Transcript 1 (design doc): agent fixed the only actionable a11y warning
// (warning count 10→9); `npm run check` is now stable; the agent already
// wrote "Next step (iter-222, implement branch)". Loop died after 5
// interventions under the old detector.
const TRANSCRIPT_1 = transcript(
  "a11y warning fixed — the check is down to 9 warnings and stable. Next step (iter-222, implement branch): wire the branch gate so iterations land on the scratch branch.",
  1, // the a11y fix was a real file edit
);

// Transcript 2 (design doc): agent shipped a 37-test pin and surfaced 10
// phantoms; loop verification stable; forward-transition in the text.
const TRANSCRIPT_2 = transcript(
  "37-test pin shipped and 10 phantoms surfaced; the verify command is stable. Next phantom: §9 audio ducking — implementing it next.",
  2, // test file + phantom notes
);

test("replay transcript 1: NEW detector says NOT stuck (item 11)", () => {
  assert.equal(isActuallyStuck(TRANSCRIPT_1), undefined);
});

test("replay transcript 2: NEW detector says NOT stuck (item 11)", () => {
  assert.equal(isActuallyStuck(TRANSCRIPT_2), undefined);
});

test("replay transcripts: OLD detector WOULD have flagged both (the false positive being fixed)", () => {
  assert.match(detectLoopStuck(TRANSCRIPT_1) ?? "", /same bash result 3× in a row/);
  assert.match(detectLoopStuck(TRANSCRIPT_2) ?? "", /same bash result 3× in a row/);
});

test("replay transcripts without the shipped work: narrate-but-don't-ship is still stuck", () => {
  assert.match(isActuallyStuck({ ...TRANSCRIPT_1, fileWriteCount: 0 }) ?? "", /same bash result 3× in a row/);
});
