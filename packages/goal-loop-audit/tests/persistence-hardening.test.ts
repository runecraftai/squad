// pi-goal-list-loop-audit — v0.28.6
// tests/persistence-hardening.test.ts
//
// Pins the v0.28.6 persistence-integrity hardening (audit findings E1 + T6 —
// audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md Stream 2):
//   E1  a disk failure (ENOSPC/EACCES/wedged mount) used to THROW out of
//       appendLedger/writeGoalMd/archiveCurrentGoal mid-handler — killing
//       the orchestrator turn and silently diverging RAM from disk. Now
//       every persistence step runs through runPersistStep: failures latch
//       a session-wide degraded flag (loud first-failure notify + TUI flag),
//       RAM stays authoritative, the next successful write self-heals.
//   T6  schema drift — the goal schema and the Goal interface must not
//       diverge; plus readState corruption tolerance (a truncated trailing
//       active.jsonl line from a mid-write kill must not lose state).
//
// Includes REAL filesystem failure injection (not just source pins).

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  appendLedger,
  writeGoalMd,
  readState,
  isPersistenceDegraded,
  lastPersistenceFailure,
} from "../extensions/goal-loop-core.js";

const CORE = fs.readFileSync("extensions/goal-loop-core.ts", "utf-8");
const GOAL = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
const DISPLAY = fs.readFileSync("extensions/goal-loop-display.ts", "utf-8");
const SCHEMA = fs.readFileSync("schemas/goal.schema.json", "utf-8");

function tmpdir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "glla-persist-"));
}

/** A cwd whose .pi-glla path is a FILE — every mkdir/append under it fails. */
function brokenCwd(): string {
  const dir = tmpdir();
  fs.writeFileSync(path.join(dir, ".pi-glla"), "not a directory");
  return dir;
}

test("readState: a truncated trailing active.jsonl line loads cleanly (mid-write kill)", () => {
  const cwd = tmpdir();
  fs.mkdirSync(path.join(cwd, ".pi-glla"), { recursive: true });
  const good1 = JSON.stringify({ type: "state", value: { goal: null, list: [] }, at: "2026-07-28T10:00:00Z" });
  const good2 = JSON.stringify({ type: "state", value: { goal: { id: "g-good", status: "active" }, list: [] }, at: "2026-07-28T10:01:00Z" });
  const truncated = '{"type":"state","value":{"goal":{"id":"g-torn"'; // mid-write kill
  fs.writeFileSync(path.join(cwd, ".pi-glla", "active.jsonl"), good1 + "\n" + good2 + "\n" + truncated + "\n");
  const s = readState(cwd);
  assert.equal((s.goal as { id: string } | null)?.id, "g-good", "torn tail skipped, last good state wins");
  assert.deepEqual(s.list, []);
});

test("E1: disk failure latches the degraded flag, never throws; a landing write self-heals", () => {
  const bad = brokenCwd();
  assert.doesNotThrow(() => appendLedger(bad, "state", { goal: null, list: [] }));
  assert.equal(isPersistenceDegraded(), true, "failure latched");
  assert.equal(lastPersistenceFailure()?.what, "appendLedger");

  // writeGoalMd also guarded — and still returns the intended path:
  const file = writeGoalMd(bad, { id: "g1", objective: "x", status: "active", policy: "goal", autoContinue: true, usage: { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0, turns: 0 }, createdAt: "2026-07-28T10:00:00Z", updatedAt: "2026-07-28T10:00:00Z" } as never);
  assert.ok(file.endsWith(path.join(".pi-glla", "goals", "g1.md")), "intended path returned even on failure");
  assert.equal(isPersistenceDegraded(), true);

  // self-heal: a write to a HEALTHY cwd lands → flag clears:
  const good = tmpdir();
  appendLedger(good, "state", { goal: null, list: [] });
  assert.equal(isPersistenceDegraded(), false, "a landing write clears the flag");
  assert.equal(lastPersistenceFailure(), null);
});

test("E1: all four persistence entry points run through runPersistStep", () => {
  assert.match(CORE, /export function runPersistStep<T>\(what: string, fn: \(\) => T\): T \| undefined/);
  assert.match(CORE, /runPersistStep\("appendLedger", \(\) => \{/);
  assert.match(CORE, /runPersistStep\("writeGoalMd", \(\) => \{/);
  assert.match(CORE, /runPersistStep\("readState", \(\) => /);
  assert.match(GOAL, /runPersistStep\("archiveCurrentGoal", \(\) => \{/);
});

test("E1: archive removes the active md ONLY when the archive landed", () => {
  assert.match(GOAL, /const archived = runPersistStep\("archiveCurrentGoal"[\s\S]*?\) === true;/);
  assert.match(GOAL, /if \(archived\) \{\s*\n\s*try \{ fs\.unlinkSync\(goalMdPath/);
});

test("E1: loud first-failure notify + recovery notify at the persistState choke point", () => {
  assert.match(GOAL, /notifyPersistenceState\(ctx\); \/\/ v0\.28\.6 \(E1\): loud on the first failure/);
  assert.match(GOAL, /if \(isPersistenceDegraded\(\) && !persistenceDegradedNotified\) \{/);
  assert.match(GOAL, /⚠ Persistence degraded: \$\{err\?.what/);
  assert.match(GOAL, /Persistence recovered — \.pi-glla writes are landing again\./);
});

test("E1: TUI persistence-degraded flag (first widget line, until a write lands)", () => {
  assert.match(DISPLAY, /import \{ isPersistenceDegraded, lastPersistenceFailure \} from "\.\/goal-loop-core\.js";/);
  assert.match(DISPLAY, /if \(inner && isPersistenceDegraded\(\)\) \{/);
  assert.match(DISPLAY, /⚠ persistence degraded — \.pi-glla writes failing/);
});

test("T6: schema does not drift from the Goal interface", () => {
  const schema = JSON.parse(SCHEMA);
  const ifaceStart = CORE.indexOf("export interface Goal");
  const ifaceEnd = CORE.indexOf("\n}", ifaceStart);
  const iface = CORE.slice(ifaceStart, ifaceEnd);
  for (const key of Object.keys(schema.properties)) {
    assert.ok(iface.includes(key), `schema property "${key}" missing from the Goal interface`);
  }
});
