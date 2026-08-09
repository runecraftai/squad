// pi-goal-list-loop-audit — v0.28.7
// tests/settings-editors.test.ts
//
// Behavioral pins for handleSettingChoice (audit T4): the v0.28.0 tests
// covered the settings MENU (render/nav/completeness) but never EXECUTED an
// editor — "menu renders and navigates perfectly while edits silently don't
// save" was the regression shape. These drive the per-key editors end-to-end
// (select/input → saveSettings with the right scope/key/value) against the
// REAL global settings file (snapshotted + restored around every test).
//
// Editor classes in the switch: select (booleans/enums) and input (strings/
// numbers with validation). No confirm-class editors exist (asserted: 0
// ctx.ui.confirm in the switch).

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import { handleSettingChoice } from "../extensions/loops/goal.js";
import { globalSettingsPath } from "../extensions/goal-settings.js";
import { makeMockCtx, tmpCwd } from "./harness/mock-pi.js";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

const GOAL_SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
const GLOBAL_FILE = globalSettingsPath();
const ORIGINAL = fs.existsSync(GLOBAL_FILE) ? fs.readFileSync(GLOBAL_FILE, "utf-8") : null;

function restoreGlobal(): void {
  if (ORIGINAL === null) {
    try {
      fs.unlinkSync(GLOBAL_FILE);
    } catch {
      /* didn't exist */
    }
  } else {
    fs.writeFileSync(GLOBAL_FILE, ORIGINAL);
  }
}

function readGlobal(): Record<string, unknown> {
  return fs.existsSync(GLOBAL_FILE) ? (JSON.parse(fs.readFileSync(GLOBAL_FILE, "utf-8")) as Record<string, unknown>) : {};
}

test("T4: select editor — autoResume writes on/off/default with the right key", async () => {
  try {
    const ctx = makeMockCtx(tmpCwd());
    ctx.ui.selectImpl = async () => "on — auto-resume on EVERY session start (unattended rigs)";
    await handleSettingChoice("autoResume", ctx as unknown as ExtensionContext);
    assert.equal(readGlobal().autoResume, true);

    ctx.ui.selectImpl = async () => "off — never auto-resume; always wait for an explicit resume";
    await handleSettingChoice("autoResume", ctx as unknown as ExtensionContext);
    assert.equal(readGlobal().autoResume, false);

    ctx.ui.selectImpl = async (t) => (t.startsWith("Auto-resume") ? "default — HOLD when a session is loaded (popup shows what waits); auto-resume on reload/fork so machinery never strands work" : undefined);
    await handleSettingChoice("autoResume", ctx as unknown as ExtensionContext);
    assert.ok(!("autoResume" in readGlobal()), "default removes the key (tri-state undefined)");
  } finally {
    restoreGlobal();
  }
});

test("T4: select editor — aggressiveMode writes the boolean + notifies", async () => {
  try {
    const ctx = makeMockCtx(tmpCwd());
    ctx.ui.selectImpl = async () => "on — autoResume, audit cap 10, stuck max 10, wedge alerts off, quota auto-retry, cap disapprovals become a TODO list and the goal KEEPS GOING";
    await handleSettingChoice("aggressiveMode", ctx as unknown as ExtensionContext);
    assert.equal(readGlobal().aggressiveMode, true);
    assert.ok(ctx.ui.matching("aggressive mode on").length >= 1, "mode flip announced");
  } finally {
    restoreGlobal();
  }
});

test("T4: input editor — auditorModel set / cleared on empty", async () => {
  try {
    const ctx = makeMockCtx(tmpCwd());
    ctx.ui.inputImpl = async () => "openai/gpt-5";
    await handleSettingChoice("auditorModel", ctx as unknown as ExtensionContext);
    assert.equal(readGlobal().auditorModel, "openai/gpt-5");

    ctx.ui.inputImpl = async () => "   ";
    await handleSettingChoice("auditorModel", ctx as unknown as ExtensionContext);
    assert.ok(!("auditorModel" in readGlobal()), "empty input removes the override");
  } finally {
    restoreGlobal();
  }
});

test("T4: input editor validation — auditCap rejects garbage loudly, accepts integers, clears on empty", async () => {
  try {
    const ctx = makeMockCtx(tmpCwd());
    ctx.ui.inputImpl = async () => "7";
    await handleSettingChoice("auditCap", ctx as unknown as ExtensionContext);
    assert.equal(readGlobal().auditCap, 7);

    ctx.ui.inputImpl = async () => "abc";
    await handleSettingChoice("auditCap", ctx as unknown as ExtensionContext);
    assert.equal(readGlobal().auditCap, 7, "invalid input leaves the saved value untouched");
    assert.ok(ctx.ui.matching("not a non-negative integer").length >= 1, "validation failure is loud");

    ctx.ui.inputImpl = async () => "";
    await handleSettingChoice("auditCap", ctx as unknown as ExtensionContext);
    assert.ok(!("auditCap" in readGlobal()), "empty input restores the default");
  } finally {
    restoreGlobal();
  }
});

test("T4: a dismissed editor (Esc → undefined) writes NOTHING", async () => {
  try {
    restoreGlobal(); // known-clean baseline
    const before = readGlobal();
    const ctx = makeMockCtx(tmpCwd());
    ctx.ui.selectImpl = async () => undefined; // user pressed Esc
    await handleSettingChoice("autoResume", ctx as unknown as ExtensionContext);
    await handleSettingChoice("aggressiveMode", ctx as unknown as ExtensionContext);
    ctx.ui.inputImpl = async () => undefined;
    await handleSettingChoice("auditorModel", ctx as unknown as ExtensionContext);
    assert.deepEqual(readGlobal(), before, "no key written by a dismissed editor");
  } finally {
    restoreGlobal();
  }
});

test("T4: the switch has no confirm-class editors (select + input only)", () => {
  const sw = GOAL_SRC.slice(GOAL_SRC.indexOf("export async function handleSettingChoice"));
  const switchBody = sw.slice(0, sw.indexOf("\n}\n"));
  assert.equal((switchBody.match(/ctx\.ui\.confirm/g) ?? []).length, 0, "a new confirm-class editor appeared — extend these tests");
});

test("v0.28.34: notify folds a default IN — auto-detect notify-send/osascript, 'off' silences, custom overrides", () => {
  const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");
  // resolution order: explicit off → custom → auto-probe:
  assert.match(SRC, /if \(settings\.notifyCmd === "off" \|\| !extensionApi\) return;/);
  assert.match(SRC, /const cmd = settings\.notifyCmd \?\? autoNotifyCmd;/);
  assert.match(SRC, /command -v notify-send \|\| command -v osascript/);
  assert.match(SRC, /autoNotifyCmd = `notify-send "pi-goal-list-loop-audit" "\$1"`;/);
  assert.match(SRC, /GLLA_MSG="\$1" osascript/);
  // pushes stay actionable-only (no per-turn site exists):
  assert.match(SRC, /Pushes fire only where there is something to DO/);
  const MENU = fs.readFileSync("extensions/settings-menu.ts", "utf-8");
  assert.match(MENU, /unset = auto-detect notify-send\/osascript · 'off' = silent/);
  // README decoupling (user: "too married to our own eco"):
  const README = fs.readFileSync("README.md", "utf-8");
  assert.match(README, /^## Subagents$/m);
  assert.doesNotMatch(README, /## Subagents \(`@tintinweb\/pi-subagents`\)/);
  assert.match(README, /any subagent provider — e\.g\. `@tintinweb\/pi-subagents` —/);
  assert.match(README, /Overlaps — pick one/);
  assert.match(README, /We ran both\s+and removed pi-tasks\./);
  assert.match(README, /auto-detects `notify-send`\/`osascript`; `notify=off` silences/);
});
