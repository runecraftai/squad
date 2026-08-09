// pi-goal-list-loop-audit — v0.25.0
// tests/aggressive-mode.test.ts
//
// Eager-continuation contract items 5-8 (Section B). Item 8 as drafted
// drove the settings UI (no UI harness in this repo) — the settings layer
// is tested instead, per advisor: persistence, effective-defaults flip,
// and the explicit-wins semantics.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  resolveEffectiveAggressiveSettings,
  BASE_AUDIT_CAP,
  AGGRESSIVE_AUDIT_CAP,
  AGGRESSIVE_STUCK_MAX_INTERVENTIONS,
  DEFAULT_QUOTA_RETRY_MINUTES,
} from "../extensions/goal-loop-core.ts";
import { saveSettings, loadSettings } from "../extensions/goal-settings.ts";

test("aggressiveMode persists through the settings file (item 8)", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glla-aggr-"));
  saveSettings("project", dir, { aggressiveMode: true, quotaRetryMinutes: 45 });
  const raw = JSON.parse(fs.readFileSync(path.join(dir, ".pi-glla", "settings.json"), "utf-8"));
  assert.equal(raw.aggressiveMode, true);
  assert.equal(raw.quotaRetryMinutes, 45);
  assert.equal(loadSettings(dir).aggressiveMode, true);
});

test("effective settings: aggressiveMode ON flips the defaults (items 5+7)", () => {
  const eff = resolveEffectiveAggressiveSettings({ aggressiveMode: true });
  assert.equal(eff.auditCap, AGGRESSIVE_AUDIT_CAP);
  assert.equal(eff.stuckMaxInterventions, AGGRESSIVE_STUCK_MAX_INTERVENTIONS);
  assert.equal(eff.wedgeAlertMinutes, 0);
  assert.equal(eff.autoResume, true);
});

test("effective settings: OFF keeps base defaults; auditCap base is 5 (item 7)", () => {
  const eff = resolveEffectiveAggressiveSettings({});
  assert.equal(eff.aggressiveMode, false);
  assert.equal(eff.auditCap, BASE_AUDIT_CAP);
  assert.equal(BASE_AUDIT_CAP, 5);
  assert.equal(eff.stuckMaxInterventions, 5);
  assert.equal(eff.wedgeAlertMinutes, 30);
  // v0.28.7: OFF + unset = tri-state DEFAULT (undefined — hold on human
  // loads, resume on reload/fork), NOT false (explicit never-resume).
  assert.equal(eff.autoResume, undefined);
});

test("explicit per-key settings WIN over aggressiveMode (advisor semantics)", () => {
  const eff = resolveEffectiveAggressiveSettings({
    aggressiveMode: true,
    auditCap: 2,
    wedgeAlertMinutes: 15,
    autoResume: false,
  });
  assert.equal(eff.auditCap, 2);
  assert.equal(eff.wedgeAlertMinutes, 15);
  assert.equal(eff.autoResume, false);
  // ...but untouched keys still flip:
  assert.equal(eff.stuckMaxInterventions, AGGRESSIVE_STUCK_MAX_INTERVENTIONS);
});

test("quotaRetryMinutes default constant is 60 (item 11)", () => {
  assert.equal(DEFAULT_QUOTA_RETRY_MINUTES, 60);
});
