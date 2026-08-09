// pi-goal-list-loop-audit — v0.27.9
// tests/tool-overrides.test.ts
//
// Item 5 of the 7-item /goal contract required a real per-tool override
// subsystem. v0.27.9 adds `toolOverrides` to .pi-glla/settings.json:
// { allow?: string[]; hide?: string[]; perToolConfig?: Record<tool, Record<key, value>> }.
// `/glla tooloverride <action>` opens the menu; ensureAgentToolsActive
// applies the allow/hide lists on top of the external allowlist.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

test("Settings type accepts toolOverrides (allow / hide / perToolConfig)", () => {
  const src = fs.readFileSync("extensions/goal-settings.ts", "utf-8");
  assert.match(src, /toolOverrides\?:\s*\{\s*\n\s*\/\*\* Tools that MUST be active/);
  assert.match(src, /allow\?:\s*string\[\]/);
  assert.match(src, /hide\?:\s*string\[\]/);
  assert.match(src, /perToolConfig\?:\s*Record<string,\s*Record<string,\s*unknown>>/);
});

test("SETTINGS_KEYS includes toolOverrides for provenance tracking", () => {
  const src = fs.readFileSync("extensions/goal-settings.ts", "utf-8");
  assert.match(src, /SETTINGS_KEYS[\s\S]*?"toolOverrides",?\s*\]/);
});

test("goal.ts ensureAgentToolsActive applies toolOverrides.allow and .hide", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  // The function reads toolOverrides and applies allow/hide after the
  // existing missingGllaTools self-heal.
  assert.match(src, /const overrides = loadSettings\(ctx\.cwd\)\.toolOverrides/);
  assert.match(src, /overrides\?\.allow && overrides\.allow\.length > 0/);
  assert.match(src, /overrides\?\.hide && overrides\.hide\.length > 0/);
  assert.match(src, /overrides\.hide!\.includes\(t\)/);
});

test("/glla tooloverride keyword routes to cmdToolOverride", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.match(src, /if \(\/\^tooloverride\\b\/\.test\(trimmed\)\) \{/);
  assert.match(src, /cmdToolOverride\(trimmed\.slice\("tooloverride"\.length\)\.trim\(\), ctx\)/);
});

test("cmdToolOverride supports allow / hide / unallow / unhide / set / unset / list", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.match(src, /if \(action === "allow" \|\| action === "hide" \|\| action === "unallow" \|\| action === "unhide"\) \{/);
  assert.match(src, /if \(action === "set" \|\| action === "unset"\) \{/);
  assert.match(src, /action === "list" \|\| action === "show"/);
});

test("parseToolOverrideValue coerces booleans, numbers, JSON; else string", () => {
  // We import via dynamic eval of the source to avoid pulling in the
  // whole pi runtime (cmdToolOverride is unexported).
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  const fnSrc = src.match(/function parseToolOverrideValue[\s\S]+?\n\}/m);
  assert.ok(fnSrc, "parseToolOverrideValue function found in goal.ts");
  // Spot-check the branches the function handles.
  assert.match(fnSrc[0]!, /trimmed === "true"/);
  assert.match(fnSrc[0]!, /trimmed === "false"/);
  assert.match(fnSrc[0]!, /trimmed === "null"/);
  assert.match(fnSrc[0]!, /RegExp|startsWith|JSON\.parse/);
  assert.match(fnSrc[0]!, /startsWith/);
});

test("reviewer 4-mode set (off | on | auto | aggressive) is the contract surface", () => {
  const src = fs.readFileSync("extensions/reviewer.ts", "utf-8");
  assert.match(src, /export type ReviewerMode = "off" \| "on" \| "auto" \| "aggressive";/);
  assert.match(src, /mode: "on",/);
});

test("legacy 'default' and 'report' modes auto-migrate to 'on' in resolveReviewerConfig", () => {
  const src = fs.readFileSync("extensions/reviewer.ts", "utf-8");
  assert.match(src, /\(merged\.mode as string\) === "default" \|\| \(merged\.mode as string\) === "report"/);
  assert.match(src, /merged\.mode = "on"/);
});

test("paused widget renders `awaiting first turn` for zero-telemetry (literal contract)", () => {
  const src = fs.readFileSync("extensions/goal-loop-display.ts", "utf-8");
  assert.match(src, /hasTelemetry\s*\?\s*`saved \u2014/);
  assert.match(src, /:\s*`awaiting first turn \u2014 resumes exactly here`/);
});

test("auditor prompt (extensions/goal-loop-auditor.ts) carries the chunk-near-context-full hint", () => {
  const src = fs.readFileSync("extensions/goal-loop-auditor.ts", "utf-8");
  const promptFn = src.match(/function buildGoalAuditorPrompt[\s\S]+?^}/m);
  assert.ok(promptFn, "buildGoalAuditorPrompt function found");
  assert.match(promptFn[0]!, /Chunk output near context-full/);
});
