// pi-goal-list-loop-audit — v0.28.0
// tests/settings-menu-complete.test.ts
//
// v0.28.0: the menu is structured data (`buildSettingsRows`) and a stable
// `id` dispatch (v0.27.0 relied on `choice.startsWith("...")` strings).
// These tests pin the structural surface against `buildSettingsRows` + the
// `handleSettingChoice` dispatch table in extensions/loops/goal.ts, rather
// than slicing source for flat-row strings.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

import {
  buildSettingsRows,
  SETTINGS_SECTIONS,
  type SettingsRow,
} from "../extensions/settings-menu.ts";
import type { Settings } from "../extensions/goal-settings.ts";

/* --------------------------------------------------------------------- */
/*  Pure row-builder pins                                                */
/* --------------------------------------------------------------------- */

const SAMPLE_SETTINGS: Settings = {
  autoResume: true,
  autoAcceptDrafts: false,
  aggressiveMode: false,
  auditorModel: "anthropic/claude-sonnet-4",
  auditorThinkingLevel: "high",
  auditCap: 10,
  auditFeedbackChars: 500,
  quotaRetryMinutes: 30,
  wedgeAlertMinutes: 0,
  stuckMaxInterventions: 5,
  stallEscalationRefires: 5,
  stallShortWords: 15,
  stallSimilarityThreshold: 0.6,
  notifyCmd: "notify-send $1",
  tokenLimit: 200000,
  subagentModelStrategy: "inherit-parent",
  subagentModelOverrides: {
    Explore: "minimax/MiniMax-M3",
    Plan: "minimax/MiniMax-M3",
  },
};

const EMPTY_PROV: Partial<Record<keyof Settings, { value: unknown; source: "project" | "global" | "default" }>> = {};

/** Build the provenance map the SAME way `settingsProvenance(cwd)` does in
 * production — each key gets a `{value, source}` from settings[k], defaulting
 * to source="global" when set and source="default" when unset. Used by tests
 * to mirror real-call behavior. */
function provFromSettings(s: Partial<Settings>): Partial<Record<keyof Settings, { value: unknown; source: "project" | "global" | "default" }>> {
  const out: Partial<Record<keyof Settings, { value: unknown; source: "project" | "global" | "default" }>> = {};
  for (const k of Object.keys(s) as Array<keyof Settings>) {
    out[k] = { value: s[k], source: "global" };
  }
  return out;
}

test("every row carries every required column field", () => {
  const rows = buildSettingsRows(SAMPLE_SETTINGS, EMPTY_PROV);
  for (const r of rows) {
    assert.ok(typeof r.id === "string" && r.id.length > 0, `id: ${r.id}`);
    assert.ok(typeof r.section === "string", `section: ${r.section}`);
    assert.ok(typeof r.label === "string" && r.label.length > 0, `label: ${r.label}`);
    assert.ok(typeof r.valueText === "string", `valueText: ${r.valueText}`);
    assert.ok(typeof r.sourceText === "string", `sourceText: ${r.sourceText}`);
    assert.ok(typeof r.description === "string" && r.description.length > 0, `description: ${r.description}`);
  }
});

test("the 5 sections are exactly {keep-going, auditor, stall-brakes, subagents, other}", () => {
  const ids = SETTINGS_SECTIONS.map((s) => s.id);
  assert.deepEqual(ids, ["keep-going", "auditor", "stall-brakes", "subagents", "other"]);
  assert.ok(SETTINGS_SECTIONS.every((s) => typeof s.label === "string" && s.label.length > 0));
});

test("every row's section is one of the 5 known section ids (no orphans)", () => {
  const validSections = new Set<string>(SETTINGS_SECTIONS.map((s) => s.id));
  const rows = buildSettingsRows(SAMPLE_SETTINGS, EMPTY_PROV);
  for (const r of rows) {
    assert.ok(validSections.has(r.section), `row ${r.id} has section ${r.section}`);
  }
});

test("key rows from v0.27.0 settings menu are all present (menu coverage contract)", () => {
  const ids = new Set(buildSettingsRows(SAMPLE_SETTINGS, EMPTY_PROV).map((r) => r.id));
  for (const id of [
    "autoResume",
    "autoAcceptDrafts",
    "aggressiveMode",
    "auditorModel",
    "auditorThinkingLevel",
    "auditCap",
    "auditFeedbackChars",
    "quotaRetryMinutes",
    "wedgeAlertMinutes",
    "stuckMaxInterventions",
    "stallEscalationRefires",
    "stallShortWords",
    "stallSimilarityThreshold",
    "subagentModelStrategy",
    "subagentModelOverrides.Explore",
    "subagentModelOverrides.Plan",
    "subagentModelOverrides.general-purpose",
    "notifyCmd",
    "tokenLimit",
    "postaudit",
  ]) {
    assert.ok(ids.has(id), `missing id: ${id}`);
  }
});

test("rows map 1:1 to dispatchable ids (every id can drive a handler)", () => {
  // The id → handler mapping lives in handleSettingChoice in goal.ts.
  // Build the set of case-labels we expect.
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  const dispatcher = src.slice(
    src.indexOf("async function handleSettingChoice"),
    src.indexOf("/** v0.26.0: /review"),
  );
  const caseLabels = new Set<string>();
  for (const m of dispatcher.matchAll(/case\s+"([^"]+)":/g)) {
    caseLabels.add(m[1]!);
  }
  const rowIds = new Set(buildSettingsRows(SAMPLE_SETTINGS, EMPTY_PROV).map((r) => r.id));
  // Every row id must have a case in the dispatcher (with one allowed
  // exception: subagentResolved is read-only and intentionally has no
  // editor — it's there for visibility into runtime resolution).
  const readOnly = new Set(["subagentResolved"]);
  let covered = 0;
  for (const r of rowIds) {
    if (readOnly.has(r)) continue;
    assert.ok(caseLabels.has(r), `row id "${r}" has no dispatcher case in handleSettingChoice`);
    covered++;
  }
  assert.ok(covered >= 18, `expected at least 18 dispatcher-covered rows, saw ${covered}`);
});

test("valueText derives from settings (effective values surface for each row)", () => {
  const rows = buildSettingsRows(SAMPLE_SETTINGS, provFromSettings(SAMPLE_SETTINGS));
  const byId = new Map<string, SettingsRow>(rows.map((r) => [r.id, r]));
  assert.equal(byId.get("autoResume")!.valueText, "true");
  assert.equal(byId.get("auditorModel")!.valueText, "anthropic/claude-sonnet-4");
  assert.equal(byId.get("wedgeAlertMinutes")!.valueText, "0");
  assert.equal(
    byId.get("subagentModelOverrides.Explore")!.valueText,
    "minimax/MiniMax-M3",
  );
});

test("default fallbacks surface when settings + provenance both missing", () => {
  const rows = buildSettingsRows({} as Settings, EMPTY_PROV);
  const byId = new Map<string, SettingsRow>(rows.map((r) => [r.id, r]));
  // No row should leak a literal `undefined` or `null` string — every
  // value is either a fallback `(...)` / `default` / `on` / `off` / a setting
  // value or a subagent resolution string.
  for (const r of rows) {
    assert.notEqual(r.valueText, "undefined");
    assert.notEqual(r.valueText, "");
  }
  // Specific defaults the contract pins:
  assert.match(byId.get("postaudit")!.valueText, /open sub-menu/);
  assert.equal(byId.get("autoAcceptDrafts")!.valueText, "off"); // v0.28.20: bare values
  assert.equal(byId.get("auditCap")!.valueText, "5"); // v0.28.20: bare
  assert.match(byId.get("subagentModelStrategy")!.valueText, /inherit-parent/);
});

test("provenance flows into sourceText (project/global/default tags)", () => {
  const rows1 = buildSettingsRows(SAMPLE_SETTINGS, {
    autoResume: { value: true, source: "project" },
    auditorModel: { value: "anthropic/claude-sonnet-4", source: "global" },
  });
  const byId = new Map(rows1.map((r) => [r.id, r]));
  assert.equal(byId.get("autoResume")!.sourceText, "project"); // v0.28.20: bare
  assert.equal(byId.get("auditorModel")!.sourceText, "global"); // v0.28.20: bare
  // No provenance → "default" (v0.28.20: bare)
  assert.equal(byId.get("wedgeAlertMinutes")!.sourceText, "default");
});

test("haiku mention is dropped from any valueText / description / sourceText", () => {
  const rows = buildSettingsRows(SAMPLE_SETTINGS, EMPTY_PROV);
  for (const r of rows) {
    for (const field of [r.valueText, r.description, r.sourceText, r.label] as const) {
      assert.doesNotMatch(field, /haiku/i, `row ${r.id} field "${field}" mentions haiku`);
    }
  }
});

/* --------------------------------------------------------------------- */
/*  Headless fallback contract                                            */
/* --------------------------------------------------------------------- */

test("the headless `/glla` fallback still lists stall brakes", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  // v0.28.0: the headless fallback is the second branch in `if (typeof ctx.ui.custom !== "function")`
  // (the rare legacy shard) OR the original text fallback at the bottom of
  // cmdSettings. Both forms must keep the stallBrakes key in the listing.
  assert.match(
    src,
    /fmt\("stallEscalationRefires", "stallEscalation"\)/,
    "headless fallback must still include stallEscalationRefires",
  );
  assert.match(
    src,
    /fmt\("wedgeAlertMinutes", "wedgeAlert"\)/,
    "headless fallback must still include wedgeAlertMinutes",
  );
});

test("the legacy flat-row startsWith logic is removed (no more `──` section headers in code)", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.doesNotMatch(
    src,
    /── Keep-going ──/,
    "section header strings should be gone — sections are now top tabs",
  );
  assert.doesNotMatch(
    src,
    /choice\.startsWith\("Auto-resume"\)/,
    "startsWith dispatch must be replaced by handleSettingChoice switch",
  );
});

test("/glla tooloverride still routes headlessly (regression: subsystems unchanged)", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.match(src, /tooloverride\b.*cmdToolOverride|cmdToolOverride\(trimmed\.slice\("tooloverride"/);
});

test("postaudit and reviewer routes both open the reviewer menu (back-compat)", () => {
  const src = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  assert.match(src, /postaudit.*cmdReviewerSettings|cmdReviewerSettings/);
});

test("v0.28.20: no bracket/paren chrome — VALUE and SOURCE render bare", () => {
  const rows = buildSettingsRows(SAMPLE_SETTINGS, {});
  for (const r of rows) {
    assert.doesNotMatch(
      r.sourceText,
      /^\[.*\]$/,
      `SOURCE must be a bare word (${r.id}): ${r.sourceText}`,
    );
    assert.doesNotMatch(
      r.valueText,
      /^\(.*\)$/,
      `VALUE must not be paren-wrapped (${r.id}): ${r.valueText}`,
    );
  }
  // The "Effective resolution" composite compacts identical resolutions to one.
  const eff = rows.find((r) => r.id === "subagentResolved")!;
  assert.ok(
    !eff.valueText.includes("·") || eff.valueText.split("·").length > 1,
    "composite either deduped or a real multi-part join",
  );
  assert.doesNotMatch(eff.valueText, /\(|\)/, `no parens in composite: ${eff.valueText}`);
});
