// pi-goal-list-loop-audit — v0.27.4
// tests/completion-trailing-space.test.ts
//
// Pi's applyCompletion does NOT add a trailing space for argument
// completions (it does for the top-level /goal itself). glla's subcommand
// items now include a trailing space in `value` (label stays clean) so the
// user can type the argument immediately — no more `/goal startasdahlasf`.
// Key=value items (ending in `=`) keep no space because the user types the
// value right after the `=`.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";

const SRC = fs.readFileSync("extensions/loops/goal.ts", "utf-8");

function extractFactory(): string {
  const start = SRC.indexOf("const completions = ");
  const end = SRC.indexOf(" pi.registerCommand(", start);
  return SRC.slice(start, end).trim();
}

function buildFactory(): (items: Array<[string, string]>) => (prefix: string) => Array<{ value: string; label: string; description: string }> {
  const factory = extractFactory();
  // Strip TS type annotations; the function is otherwise plain ES2022.
  const js = factory
    .replace(/^const completions = /, "return ")
    .replace(/: Array<\[string, string\]>/g, "")
    .replace(/: string\b/g, "");
  // eslint-disable-next-line no-new-func
  return new Function(js)() as ReturnType<typeof buildFactory>;
}

test("subcommand items get a trailing space in value, label stays clean", () => {
  const factory = buildFactory();
  const f = factory([
    ["start", "skip drafting"],
    ["status", "show status"],
    ["tweak", "narrow the goal"],
    ["cancel", "abort"],
  ]);
  assert.deepEqual(f(""), [
    { value: "start ", label: "start", description: "skip drafting" },
    { value: "status ", label: "status", description: "show status" },
    { value: "tweak ", label: "tweak", description: "narrow the goal" },
    { value: "cancel ", label: "cancel", description: "abort" },
  ]);
  assert.deepEqual(f("s"), [
    { value: "start ", label: "start", description: "skip drafting" },
    { value: "status ", label: "status", description: "show status" },
  ]);
});

test("key=value items get NO trailing space (user types the value right after the =)", () => {
  const factory = buildFactory();
  const f = factory([
    ["model=", "auditor model override"],
    ["thinking=", "auditor thinking level"],
    ["notify=", "desktop push command"],
  ]);
  assert.deepEqual(f(""), [
    { value: "model=", label: "model=", description: "auditor model override" },
    { value: "thinking=", label: "thinking=", description: "auditor thinking level" },
    { value: "notify=", label: "notify=", description: "desktop push command" },
  ]);
  assert.deepEqual(f("m"), [{ value: "model=", label: "model=", description: "auditor model override" }]);
});

test("mixed list (bare commands + key=value) — the asymmetric rule", () => {
  const factory = buildFactory();
  const f = factory([
    ["stats", "ledger rollups"],
    ["audits", "audit-log browser"],
    ["autoaccept=", "on: drafts activate without Confirm"],
    ["model=", "auditor model override"],
  ]);
  assert.deepEqual(f(""), [
    { value: "stats ", label: "stats", description: "ledger rollups" },
    { value: "audits ", label: "audits", description: "audit-log browser" },
    { value: "autoaccept=", label: "autoaccept=", description: "on: drafts activate without Confirm" },
    { value: "model=", label: "model=", description: "auditor model override" },
  ]);
});

test("filter still prefix-based (no other behavior change)", () => {
  const factory = buildFactory();
  const f = factory([["start", "a"], ["status", "b"], ["resume", "c"]]);
  assert.equal(f("st").length, 2);
  assert.equal(f("s").length, 2);
  assert.equal(f("xyz").length, 0);
});

test("registerCommand: /goal, /glla, /list, /loop all use the shared factory", () => {
  for (const cmd of ["goal", "glla", "list", "loop"]) {
    const m = SRC.match(new RegExp(`pi\\.registerCommand\\("${cmd}"[\\s\\S]+?getArgumentCompletions: completions\\(`));
    assert.ok(m, `${cmd} registers with the completions factory`);
  }
});
