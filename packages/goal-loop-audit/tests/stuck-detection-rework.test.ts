// pi-goal-list-loop-audit — v0.27.3
// tests/stuck-detection-rework.test.ts
//
// v0.27.3: smarter nudge detector. The tool-only check fired on real
// investigation work (polis-session screenshot, 2026-07-27: model read
// files via cd/ls/grep then produced multi-sentence analytical
// paragraphs — three consecutive no-tool-turns all tripped the brake).
// A turn is now a nudge ONLY when it has no tool calls AND its text is
// short (word count) OR highly similar to the prior assistant turn.
// Substantive novel analysis resets the counter even without a tool call.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import {
  DEFAULT_STALL_SHORT_WORDS,
  DEFAULT_STALL_SIM_THRESHOLD,
  accountTurnForNudgesRich,
  isNudgeTurn,
  trigramSimilarity,
} from "../extensions/goal-loop-backoff.ts";

test("trigramSimilarity: identity = 1, disjoint = 0, empties", () => {
  assert.equal(trigramSimilarity("hello world", "hello world"), 1);
  assert.equal(trigramSimilarity("abc", "xyz"), 0);
  assert.equal(trigramSimilarity("", ""), 1);
  assert.equal(trigramSimilarity("", "anything"), 0);
  assert.equal(trigramSimilarity("anything", ""), 0);
});

test("trigramSimilarity: similar but not identical", () => {
  const a = "the model is producing analytical content about polis state";
  const b = "the model is producing analytical content about polis game";
  const sim = trigramSimilarity(a, b);
  assert.ok(sim > 0.5 && sim < 1, `expected 0.5–1, got ${sim}`);
});

test("isNudgeTurn: tool use resets the brake even on empty text", () => {
  assert.equal(isNudgeTurn({ toolCalls: 1, text: "", priorText: "" }), false);
});

test("isNudgeTurn: short no-tool turn is always a nudge", () => {
  assert.equal(isNudgeTurn({ toolCalls: 0, text: "ok", priorText: "ok" }), true);
  assert.equal(isNudgeTurn({ toolCalls: 0, text: "", priorText: "" }), true);
  assert.equal(isNudgeTurn({ toolCalls: 0, text: "Working…", priorText: "" }), true);
});

test("isNudgeTurn: substantive paragraph (≥15 words, novel) is NOT a nudge (the polis incident)", () => {
  const novel = "state-pump-dom.ts has zero references to hud. So hud.state is never populated. The HUD never renders. This is a real, latent bug — the HUD never appears because nothing calls hud.setState.";
  const prior = "But wait, the screenshot earlier showed a HUD rendering with MONTH 24, POP=8, FOOD, GOLD. So something DID populate it once. Let me check the screenshot was from a previous boot.";
  assert.equal(isNudgeTurn({ toolCalls: 0, text: novel, priorText: prior }), false);
});

test("isNudgeTurn: long + repetitive text IS a nudge", () => {
  const same = "I'll try a different approach and see what happens with the next file read of the surrounding code to figure out where the population hook actually fires at runtime.";
  assert.equal(isNudgeTurn({ toolCalls: 0, text: same, priorText: same }), true);
});

test("isNudgeTurn: long text with no prior (first turn in a streak) is NOT a nudge", () => {
  const long = Array.from({ length: 30 }, (_, i) => `word${i}`).join(" ");
  assert.equal(isNudgeTurn({ toolCalls: 0, text: long, priorText: "" }), false);
});

test("isNudgeTurn: tunable thresholds", () => {
  const text = Array.from({ length: 12 }, () => "alpha").join(" ");
  // default short=15 → 12 words IS a nudge
  assert.equal(isNudgeTurn({ toolCalls: 0, text, priorText: "anything" }), true);
  // raise shortWords to 10 → 12 words no longer short
  assert.equal(isNudgeTurn({ toolCalls: 0, text, priorText: "different", shortWords: 10 }), false);
  // strict sim=0.0 → any novel text is NOT a nudge
  const long = Array.from({ length: 20 }, (_, i) => `w${i}`).join(" ");
  assert.equal(isNudgeTurn({ toolCalls: 0, text: long, priorText: "totally unrelated", simThreshold: 0 }), false);
});

test("accountTurnForNudgesRich: three substantive no-tool turns → stays 0 (the fix)", () => {
  const turns: string[] = [
    "state-pump-dom.ts has zero references to hud. So hud.state is never populated. The HUD never renders. This is a real, latent bug.",
    "But wait, the screenshot earlier showed a HUD rendering with MONTH 24, POP=8, FOOD, GOLD. So something DID populate it once. Let me check the screenshot was from a previous boot.",
    "The 552 KB screenshot was the broken state with HUD visible. So either the HUD IS populating from somewhere, or the screenshot is from a previous browser tab or cache.",
  ];
  let n = 0;
  for (let i = 0; i < turns.length; i++) {
    const text = turns[i] as string;
    const prior = i > 0 ? (turns[i - 1] as string) : "";
    n = accountTurnForNudgesRich(
      { toolCalls: 0, text, priorText: prior },
      n,
    );
  }
  assert.equal(n, 0, "real investigation work should never accumulate nudges");
});

test("accountTurnForNudgesRich: three short repetitive replies → reaches max", () => {
  let n = 0;
  for (let i = 0; i < 3; i++) {
    n = accountTurnForNudgesRich(
      { toolCalls: 0, text: "ok", priorText: "ok" },
      n,
    );
  }
  assert.equal(n, 3);
});

test("defaults", () => {
  assert.equal(DEFAULT_STALL_SHORT_WORDS, 15);
  assert.equal(DEFAULT_STALL_SIM_THRESHOLD, 0.6);
});
