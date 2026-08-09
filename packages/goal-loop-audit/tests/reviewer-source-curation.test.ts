// pi-goal-list-loop-audit — v0.26.4
// tests/reviewer-source-curation.test.ts
//
// Source curation: the 0.26.3 completion produced ANOTHER junk review
// (4 false "architectural" findings) — all meta-artifacts mined from the
// APPROVED audit report (the executor's own completion claims) and from
// backticked code spans. Regex guards lose the arms race against
// meta-text; the fix is curating WHAT gets scanned.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  classifyFindingText,
  extractFindings,
  stripCodeSpans,
  resolveReviewerConfig,
  runReviewer,
  type ReviewerDeps,
} from "../extensions/reviewer.ts";

const SRC_GOAL = fs.readFileSync("extensions/loops/goal.ts", "utf-8");

// The exact 4 junk findings from the 0.26.3 misfire:
const LIVE_FALSE_POSITIVES = [
  '4. **Vocabulary skip**: `REVIEWER_VOCAB` regex present covering all specified terms plus `problems/(improvements|architectural)`.',
  '{ class: "architectural", re: /\\brewrite\\b|new dependency|schema change|\\bredesign\\b/i },',
  "'Docs: CHANGELOG `[0.26.2]` entry and INSTALL.md reviewer mode matrix ... problems/architectural/clean) ...',",
  '\'47:test("auto mode: architectural findings enqueue to /list — proposeGoal NEVER called", ...\',',
];

test("stripCodeSpans removes fenced blocks and inline spans", () => {
  const text = ' prose `const x = rewrite();` more\n```ts\n{ class: "architectural", re: /rewrite/ }\n```\ntail';
  const out = stripCodeSpans(text);
  assert.ok(!out.includes("rewrite"), "code content gone");
  assert.ok(!out.includes("architectural"));
  assert.ok(out.includes("prose") && out.includes("tail"), "prose survives");
});

test("the 4 junk lines from the 0.26.3 misfire extract NOTHING through the curated pipeline", () => {
  const findings = extractFindings([{ name: "audit", text: LIVE_FALSE_POSITIVES.join("\n") }], 10);
  assert.deepEqual(findings, []);
});

test("brace-led and quote-led lines are code-ish, never findings", () => {
  assert.equal(classifyFindingText('{ class: "architectural", re: /\\brewrite\\b|new dependency|schema change/ },'), undefined);
  assert.equal(classifyFindingText('  ["rewrite the parser", "schema change"],'), undefined);
  assert.equal(classifyFindingText("'we should rewrite the schema',"), undefined);
  assert.equal(classifyFindingText('"requires a schema change in the ledger",'), undefined);
});

test("fireReviewer only mines disapproved/error audit reports, never approved ones", () => {
  assert.match(SRC_GOAL, /e\.verdict === "disapproved" \|\| e\.verdict === "error"/);
  assert.match(SRC_GOAL, /APPROVED audit report is the executor's\n    \/\/ own completion claims/);
});

test("a DISAPPROVED report's required-fixes extract as findings; an APPROVED meta-report is inert", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-curate-"));
  const approvedMeta = "## Verification\n1. `REVIEWER_VOCAB` regex present covering problems/(improvements|architectural) — PASS.\n2. `{ class: \"architectural\", re: /rewrite|schema change/ }` present — PASS.";
  const disapprovedReal = "## Required fixes\n- TODO: the retry backoff is broken — it retries immediately.\n- consider adding a timeout to the auditor spawn";
  // Approved meta-report: zero findings (spans stripped, vocab guarded).
  const meta = extractFindings([{ name: "audit", text: approvedMeta }], 10);
  assert.deepEqual(meta, [], "approved meta-report yields nothing");
  // Disapproved report: the real findings come through.
  const real = extractFindings([{ name: "audit", text: disapprovedReal }], 10);
  assert.equal(real.length, 2);
  assert.equal(real[0]!.class, "bug");
  assert.equal(real[1]!.class, "refactor");
  // And through runReviewer end-to-end:
  const calls = { enqueued: [] as string[][], proposed: [] as string[] };
  const deps: ReviewerDeps = {
    cwd: dir,
    nowMs: Date.parse("2026-07-26T14:00:00Z"),
    ledgerEntries: [],
    sources: [
      { name: "audit", text: approvedMeta },
      { name: "audit", text: disapprovedReal },
    ],
    enqueueListItems: (o) => calls.enqueued.push(o),
    proposeGoal: (g) => { calls.proposed.push(g); return true; },
    notify: () => {},
    ledger: () => {},
  };
  const out = runReviewer(resolveReviewerConfig(), { kind: "goal", goalId: "g1", objective: "ship 0.26.4", terminal: "goal-complete" }, deps);
  assert.equal(out.enqueued, 2);
  assert.equal(calls.proposed.length, 0);
});

test("real prose findings still classify after curation", () => {
  assert.equal(classifyFindingText("we should rewrite the event schema to normalize it"), "architectural");
  assert.equal(classifyFindingText("TODO: the retry backoff is broken"), "bug");
  assert.equal(classifyFindingText("consider adding a timeout to the spawn"), "refactor");
});
