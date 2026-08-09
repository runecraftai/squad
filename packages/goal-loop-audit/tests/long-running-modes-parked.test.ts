// pi-goal-list-loop-audit — v0.27.7
// tests/long-running-modes-parked.test.ts
//
// The audit/LONG-RUNNING-MODES.md parking doc is the per-item evidence
// ledger for the 7-item /goal that produced it. Each test below pins one
// item's terminal state (shipped or parked) to a concrete artifact so a
// future auditor can verify the contract without re-reading chat history.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import { execSync } from "node:child_process";

const DOC = fs.readFileSync("audit/LONG-RUNNING-MODES.md", "utf-8");

test("Item 1 — parking doc itself is committed to git", () => {
  // The doc must be in the index.
  const listed = execSync("git ls-files audit/LONG-RUNNING-MODES.md", { encoding: "utf-8" }).trim();
  assert.equal(listed, "audit/LONG-RUNNING-MODES.md");
  // And on disk with substantive content.
  const stat = fs.statSync("audit/LONG-RUNNING-MODES.md");
  assert.ok(stat.size > 3000, `expected >3000 bytes (got ${stat.size})`);
});

test("Item 2 — 0.27.5 postaudit surface shipped, modes re-shaped to literal contract in 0.27.9", () => {
  assert.match(DOC, /Item 2.+pi-goal-list-loop-audit@0\.27\.5/s);
  assert.match(DOC, /22bbafa2.*0\.27\.5/);
  assert.match(DOC, /34d7ad4b.*0\.27\.7/);
  assert.match(DOC, /postaudit\?: Record<string, unknown>/);
  assert.match(DOC, /dual-read.*settings\.postaudit \?\? settings\.reviewer/);
  // 4 modes all listed as shipped (search for the leading keyword in each line)
  assert.match(DOC, /`off` .*no post-audit \(0\.27\.7\)/);
  assert.match(DOC, /`on` .*Confirm-gated cascade/);
  assert.match(DOC, /`auto` .*auto-enqueue any tasks it produces into .\/list/);
  assert.match(DOC, /`aggressive` .*auto-relaunch goal if it proposes one/);
  assert.doesNotMatch(DOC, /`report` ✅/); // no entry in the shipped-modes table
  // Source files exist
  assert.ok(fs.existsSync("extensions/loops/goal.ts"));
  assert.ok(fs.existsSync("extensions/goal-settings.ts"));
  // The package was at 0.27.9+
  const pkg = JSON.parse(fs.readFileSync("package.json", "utf-8"));
  assert.match(pkg.version, /^0\.(27\.9|[2-9]\d+\.\d+)$/, "local version is at 0.27.9 (4-mode contract) or later");
});

test("Item 3 — modlist removal: no /glla modlist menu item in code", () => {
  assert.match(DOC, /Item 3.+modlist removal/s);
  assert.match(DOC, /shipped in 0\.24\.0/);
  // Negative grep: no /glla modlist command
  const grep = execSync(`grep -RIn '"/glla modlist"\\|cmdModlist' extensions/ || true`, { encoding: "utf-8" }).trim();
  assert.equal(grep, "", `unexpected modlist references: ${grep}`);
});

test("Item 4 — bun test parallelization: package.json scripts use bun", () => {
  assert.match(DOC, /Item 4.+bun test parallelization/s);
  assert.match(DOC, /ec60a2b4.*0\.27\.6/);
  const pkg = JSON.parse(fs.readFileSync("package.json", "utf-8"));
  assert.equal(pkg.scripts.test, "bun test");
  assert.match(pkg.scripts["test:node"], /node --experimental-strip-types/);
  assert.match(pkg.scripts["test:all"], /bun test && tsc --noEmit/);
});

test("Item 5 — per-tool override subsystem shipped in 0.27.9", () => {
  assert.match(DOC, /Item 5.+per-project tool overrides/s);
  assert.match(DOC, /shipped in 0\.27\.9 as a first-class subsystem/);
  // The Settings type + toolOverrides block + SETTINGS_KEYS entry
  const src = fs.readFileSync("extensions/goal-settings.ts", "utf-8");
  assert.match(src, /toolOverrides\?:\s*\{\s*\n\s*\/\*\* Tools that MUST be active/);
  assert.match(src, /allow\?:\s*string\[\]/);
  assert.match(src, /hide\?:\s*string\[\]/);
  assert.match(src, /perToolConfig\?:\s*Record<string,\s*Record<string,\s*unknown>>/);
  // SETTINGS_KEYS includes toolOverrides
  assert.match(src, /SETTINGS_KEYS[\s\S]*?"toolOverrides",?\s*\]/);
  // goal.ts wires toolOverrides into ensureAgentToolsActive
  const goalSrc = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.match(goalSrc, /const overrides = loadSettings\(ctx\.cwd\)\.toolOverrides/);
  assert.match(goalSrc, /cmdToolOverride/);
  // Tool-override test file exists
  assert.ok(fs.existsSync("tests/tool-overrides.test.ts"));
});

test("Item 6 — paused widget renders `awaiting first turn` for zero telemetry (literal contract)", () => {
  assert.match(DOC, /Item 6.+paused widget wording/s);
  const widgetSrc = fs.readFileSync("extensions/goal-loop-display.ts", "utf-8");
  assert.match(widgetSrc, /hasTelemetry\s*\?/);
  assert.match(widgetSrc, /saved \u2014 \$\{spent\.join/);
  assert.match(widgetSrc, /awaiting first turn \u2014 resumes exactly here/);
  assert.doesNotMatch(widgetSrc, /"no work started"/);
});

test("Item 7 — chunk-near-context-full hint in continuation prompt", () => {
  assert.match(DOC, /Item 7.+chunk-near-context-full hint/s);
  const prompt = fs.readFileSync("prompts/goal-loop-continuation.md", "utf-8");
  assert.match(prompt, /Chunk output near context-full/);
  assert.match(prompt, /stop_reason="length"/);
});

test("All 7 items appear in the doc with state = shipped or explicitly parked", () => {
  // Each item header line.
  const expected = [
    /### Item 1 — parking doc itself/,
    /### Item 2 — `pi-goal-list-loop-audit@0\.27\.5`/,
    /### Item 3 — modlist removal/,
    /### Item 4 — bun test parallelization/,
    /### Item 5 — per-project tool overrides/,
    /### Item 6 — paused widget/,
    /### Item 7 — chunk-near-context-full hint/,
  ];
  for (const re of expected) assert.match(DOC, re, `missing: ${re}`);
  // Each item is marked "shipped" or "noted-as-done" or "parked" — never "in progress".
  const itemBodies = DOC.split(/### Item \d+ — /).slice(1);
  assert.equal(itemBodies.length, 7);
  for (const body of itemBodies) {
    assert.ok(
      /\*\*State\*\*:\s*(shipped|parked)/.test(body),
      `every item must have State: shipped or parked: ${body.slice(0, 80)}...`,
    );
    assert.ok(
      /\*\*Evidence\*\*:/.test(body),
      `every item must have Evidence: block: ${body.slice(0, 80)}...`,
    );
  }
});
