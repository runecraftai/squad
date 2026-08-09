// pi-goal-list-loop-audit — v0.25.6
// tests/subagent-polish.test.ts
//
// Subagent polish: per-type pins for Plan/general-purpose, managed-file
// repair detection + notify, effective-resolution display, subagent
// quota-error detection (pi-subagents#175).

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  buildAgentOverrideMd,
  resolveEffectiveSubagentModel,
  syncSubagentModelOverrides,
  OVERRIDABLE_AGENT_TYPES,
} from "../extensions/goal-loop-subagents.ts";
import { isSubagentQuotaResult } from "../extensions/quota-retry.ts";

test("per-type pins: Plan and general-purpose are overridable with embedded defaults", () => {
  assert.deepEqual([...OVERRIDABLE_AGENT_TYPES].sort(), ["Explore", "Plan", "general-purpose"]);
  // Plan pin: read-only tools + replace mode + model pin + marker:
  const plan = buildAgentOverrideMd("Plan", "minimax/MiniMax-M3");
  assert.match(plan, /model: minimax\/MiniMax-M3/);
  assert.match(plan, /tools: read, bash, grep, find, ls/);
  assert.match(plan, /prompt_mode: replace/);
  assert.match(plan, /x-managed-by: pi-goal-list-loop-audit/);
  assert.match(plan, /software architect and planning specialist/);
  // general-purpose: NO tools line (all tools upstream) + append mode:
  const gp = buildAgentOverrideMd("general-purpose", "minimax/MiniMax-M3");
  assert.doesNotMatch(gp, /^tools:/m);
  assert.match(gp, /prompt_mode: append/);
  assert.match(gp, /model: minimax\/MiniMax-M3/);
});

test("strategy-driven sync writes ONLY Explore; Plan/general-purpose need explicit pins", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-subagent-"));
  const sync = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent", overrides: {} });
  assert.deepEqual(sync.written, ["Explore"]);
  assert.ok(fs.existsSync(path.join(dir, "agents", "Explore.md")));
  assert.ok(!fs.existsSync(path.join(dir, "agents", "Plan.md")), "Plan must NOT get a strategy-driven file");
  // Explicit Plan pin writes it:
  const sync2 = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent", overrides: { Plan: "minimax/MiniMax-M3" } });
  assert.deepEqual(sync2.written, ["Plan"]);
  assert.match(fs.readFileSync(path.join(dir, "agents", "Plan.md"), "utf-8"), /model: minimax\/MiniMax-M3/);
});

test("repair detection: externally deleted/altered managed files are re-written and flagged", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-subagent-repair-"));
  // First sync: initial write, NOT a repair:
  const first = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent", overrides: {} });
  assert.deepEqual(first.written, ["Explore"]);
  assert.deepEqual(first.repaired, []);
  // External deletion:
  fs.unlinkSync(path.join(dir, "agents", "Explore.md"));
  const second = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent", overrides: {} });
  assert.deepEqual(second.written, ["Explore"]);
  assert.deepEqual(second.repaired, ["Explore"], "deleted managed file repaired + flagged");
  // External alteration:
  fs.appendFileSync(path.join(dir, "agents", "Explore.md"), "\n# user scribble\n");
  const third = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent", overrides: {} });
  assert.deepEqual(third.repaired, ["Explore"], "altered managed file repaired + flagged");
  // Idempotent: no change → no repair:
  const fourth = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent", overrides: {} });
  assert.deepEqual(fourth.written, []);
  assert.deepEqual(fourth.repaired, []);
});

test("effective resolution: per-type pin > inherit-parent > agent-default", () => {
  assert.equal(
    resolveEffectiveSubagentModel("Plan", { subagentModelOverrides: { Plan: "x/y" } }, "p/s"),
    "x/y (per-type pin)",
  );
  assert.equal(
    resolveEffectiveSubagentModel("Plan", { subagentModelStrategy: "inherit-parent" }, "p/s"),
    "p/s (inherits session)",
  );
  assert.equal(
    resolveEffectiveSubagentModel("Explore", { subagentModelStrategy: "agent-default" }),
    "anthropic/claude-haiku-4-5 (upstream pin)",
  );
  assert.equal(
    resolveEffectiveSubagentModel("general-purpose", { subagentModelStrategy: "agent-default" }),
    "(agent default)",
  );
});

test("subagent quota detection: Agent + quota payload only", () => {
  // The wild pi-subagents#175 shape:
  assert.equal(isSubagentQuotaResult("Agent", true, "Error: 403 Key limit exceeded"), true);
  assert.equal(isSubagentQuotaResult("Agent", true, JSON.stringify({ error: "429 rate limit" })), true);
  // Not errors / not quota / not Agent:
  assert.equal(isSubagentQuotaResult("Agent", false, "403 Key limit exceeded"), false);
  assert.equal(isSubagentQuotaResult("Agent", true, "file not found"), false);
  assert.equal(isSubagentQuotaResult("bash", true, "403 Key limit exceeded"), false);
});
