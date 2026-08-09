// pi-goal-list-loop-audit — v0.25.2
// tests/goal-loop-stats.test.ts
//
// /glla stats contract items 1-7: discovery, rollup, premature-success
// detection, table + JSON formats, filters.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  detectPrematureSuccess,
  discoverGllaProjects,
  filterPremature,
  formatRollupJson,
  formatRollupTable,
  parseLedgerEntries,
  rollupEntries,
  rollupProject,
  PREMATURE_THRESHOLDS,
} from "../extensions/goal-loop-stats.ts";

function mkProject(dir: string, name: string, ledgerLines: object[]): string {
  const root = path.join(dir, name);
  fs.mkdirSync(path.join(root, ".pi-glla"), { recursive: true });
  fs.writeFileSync(
    path.join(root, ".pi-glla", "active.jsonl"),
    ledgerLines.map((l) => JSON.stringify(l)).join("\n") + "\n",
  );
  return root;
}

const APPROVED_GOAL = {
  id: "g1",
  status: "complete",
  usage: { tokensUsed: 12000 },
  auditHistory: [{ approved: true }, { disapproved: true }, { approved: true }],
  telemetry: { turns: 120, fileWrites: 30, bashCalls: 25 },
};

const PREMATURE_GOAL = {
  id: "g2",
  status: "complete",
  usage: { tokensUsed: 3000 },
  auditHistory: [{ approved: true }],
  telemetry: { turns: 12, fileWrites: 0, bashCalls: 2 },
};

test("empty rig: no .pi-glla anywhere → empty discovery + no rollup", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-stats-empty-"));
  assert.deepEqual(discoverGllaProjects({ home: dir, cwd: dir, budgetMs: 500 }), []);
  assert.equal(rollupProject(dir), undefined);
});

test("single project with one approved goal: all counters correct", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-stats-"));
  const root = mkProject(dir, "proj", [
    { type: "goal_created", value: { goalId: "g1" }, at: "2026-07-20T10:00:00Z" },
    { type: "state", value: { goal: APPROVED_GOAL }, at: "2026-07-20T12:00:00Z" },
  ]);
  const r = rollupProject(root)!;
  assert.equal(r.goalsCreated, 1);
  assert.equal(r.auditsApproved, 2);
  assert.equal(r.auditsDisapproved, 1);
  assert.equal(r.auditsError, 0);
  assert.equal(r.avgTurns, 120);
  assert.equal(r.avgWrites, 30);
  assert.equal(r.prematureCount, 0);
  assert.equal(r.totalCost, 12000);
  assert.equal(r.lastActive, "2026-07-20T12:00:00Z");
});

test("premature-success detection fires on low turns + 0 writes + few bash", () => {
  assert.equal(detectPrematureSuccess(PREMATURE_GOAL), true);
  assert.equal(detectPrematureSuccess(APPROVED_GOAL), false);
  // Not approved → never premature:
  assert.equal(detectPrematureSuccess({ id: "x", auditHistory: [{ disapproved: true }], telemetry: { turns: 1, fileWrites: 0, bashCalls: 0 } }), false);
  // No telemetry (pre-0.25.2 archive) → unknown, not convicted:
  assert.equal(detectPrematureSuccess({ id: "y", auditHistory: [{ approved: true }] }), false);
  // Threshold sanity:
  assert.equal(PREMATURE_THRESHOLDS.maxTurns, 50);
});

test("JSON output schema matches the table columns", () => {
  const rollups = [
    rollupEntries("/home/x/proj", [
      { type: "goal_created", value: {}, at: "2026-07-20T10:00:00Z" },
      { type: "state", value: { goal: PREMATURE_GOAL }, at: "2026-07-21T10:00:00Z" },
    ]),
  ];
  const parsed = JSON.parse(formatRollupJson(rollups));
  assert.equal(parsed.length, 1);
  assert.deepEqual(Object.keys(parsed[0]).sort(), [
    "audits_approved", "audits_disapproved", "audits_error", "avg_turns", "avg_writes",
    "goals_created", "last_active", "premature_count", "project", "total_cost",
  ].sort());
  assert.equal(parsed[0].premature_count, 1);
  // Table has the same data + headers:
  const table = formatRollupTable(rollups);
  assert.match(table, /\| project \| goals \| approved \|/);
  assert.match(table, /\| ~?\S*proj \| 1 \| 1 \| 0 \| 0 \| 12 \| 0 \| 1 \| 3,000 \|/);
});

test("premature filter: only flagged projects, ratio-sorted", () => {
  const clean = rollupEntries("/p/clean", [{ type: "state", value: { goal: APPROVED_GOAL }, at: "2026-07-20T10:00:00Z" }]);
  const flagged = rollupEntries("/p/flagged", [
    { type: "goal_created", value: {}, at: "2026-07-20T10:00:00Z" },
    { type: "state", value: { goal: PREMATURE_GOAL }, at: "2026-07-20T11:00:00Z" },
  ]);
  const filtered = filterPremature([clean, flagged]);
  assert.equal(filtered.length, 1);
  assert.equal(filtered[0]!.project, "/p/flagged");
});

test("discovery finds nested projects and dedupes via cwd", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-stats-disc-"));
  const nested = mkProject(dir, path.join("Dev", "dracon-platform", "web", "games", "wip", "polis"), [
    { type: "goal_created", value: {}, at: "2026-07-20T10:00:00Z" },
  ]);
  const found = discoverGllaProjects({ home: dir, cwd: nested, budgetMs: 2000 });
  assert.deepEqual(found, [nested]);
});

test("parseLedgerEntries skips malformed lines", () => {
  const entries = parseLedgerEntries('{"type":"a"}\nnot json\n{"type":"b","at":"x"}\n{"no_type":1}\n');
  assert.equal(entries.length, 2);
});
