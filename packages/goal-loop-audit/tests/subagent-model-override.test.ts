// pi-goal-list-loop-audit — v0.24.6
// tests/subagent-model-override.test.ts
//
// Section I of the eager-continuation contract (goal-file items 33-36):
// pi-subagents' default Explore agent pins anthropic/claude-haiku-4-5, which
// silently routes subagents to a different provider/quota pool than the
// session. glla manages ~/.pi/agent/agents/Explore.md (the only pinned
// default) so subagents inherit the session model by default, with a
// settings escape hatch.

import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  buildAgentOverrideMd,
  defaultAgentDir,
  EXPLORE_DEFAULT_DESCRIPTION,
  EXPLORE_DEFAULT_SYSTEM_PROMPT,
  EXPLORE_DEFAULT_TOOLS,
  KNOWN_PINNED_DEFAULT_AGENTS,
  SUBAGENT_MANAGED_MARKER,
  syncSubagentModelOverrides,
} from "../extensions/goal-loop-subagents.ts";

function tmpAgentDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "glla-subagents-"));
}

function readOverride(agentDir: string, name: string): string | undefined {
  const file = path.join(agentDir, "agents", `${name}.md`);
  return fs.existsSync(file) ? fs.readFileSync(file, "utf-8") : undefined;
}

// ---- buildAgentOverrideMd ----

test("build: no model → no model: line, marker present, tools CSV, full prompt", () => {
  const md = buildAgentOverrideMd("Explore");
  assert.equal(/^model:/m.test(md), false, "must NOT contain a model: pin");
  assert.ok(md.includes(`x-managed-by: ${SUBAGENT_MANAGED_MARKER}`));
  assert.ok(md.includes(`tools: ${EXPLORE_DEFAULT_TOOLS}`));
  assert.ok(md.includes("prompt_mode: replace"));
  assert.ok(md.includes(EXPLORE_DEFAULT_SYSTEM_PROMPT));
  assert.ok(md.includes(EXPLORE_DEFAULT_DESCRIPTION));
});

test("build: with model → model pin written", () => {
  const md = buildAgentOverrideMd("Explore", "minimax/MiniMax-M3");
  assert.ok(/^model: minimax\/MiniMax-M3$/m.test(md));
  assert.ok(md.includes(`x-managed-by: ${SUBAGENT_MANAGED_MARKER}`));
});

test("build: unknown agent name throws", () => {
  assert.throws(() => buildAgentOverrideMd("Custom"), /no embedded default config/);
});

// ---- syncSubagentModelOverrides: writer safety contract ----

test("sync: file absent + inherit-parent → managed file created without pin", () => {
  const dir = tmpAgentDir();
  const r = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent" });
  assert.deepEqual(r.written, ["Explore"]);
  assert.deepEqual(r.removed, []);
  assert.deepEqual(r.skipped, []);
  const md = readOverride(dir, "Explore")!;
  assert.equal(/^model:/m.test(md), false);
  assert.ok(md.includes(SUBAGENT_MANAGED_MARKER));
});

test("sync: idempotent — second run writes nothing", () => {
  const dir = tmpAgentDir();
  syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent" });
  const r = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent" });
  assert.deepEqual(r.written, []);
  assert.deepEqual(r.removed, []);
  assert.deepEqual(r.skipped, []);
});

test("sync: managed file with stale content → updated in place", () => {
  const dir = tmpAgentDir();
  syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent", overrides: { Explore: "minimax/MiniMax-M3" } });
  assert.ok(/^model: minimax\/MiniMax-M3$/m.test(readOverride(dir, "Explore")!));
  // flip back to plain inherit — pin must be removed
  const r = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent" });
  assert.deepEqual(r.written, ["Explore"]);
  assert.equal(/^model:/m.test(readOverride(dir, "Explore")!), false);
});

test("sync: user-owned file (no marker) → refused, untouched, noted", () => {
  const dir = tmpAgentDir();
  fs.mkdirSync(path.join(dir, "agents"), { recursive: true });
  const file = path.join(dir, "agents", "Explore.md");
  const userContent = "---\ndescription: my own explore\n---\n\nuser prompt\n";
  fs.writeFileSync(file, userContent);
  const r = syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent" });
  assert.deepEqual(r.written, []);
  assert.equal(r.skipped.length, 1);
  assert.equal(r.skipped[0]!.name, "Explore");
  assert.match(r.skipped[0]!.reason, /user-owned/);
  assert.equal(fs.readFileSync(file, "utf-8"), userContent, "user file must be untouched");
});

test("sync: strategy agent-default → managed file deleted, user file kept", () => {
  const dir = tmpAgentDir();
  // managed file present
  syncSubagentModelOverrides({ agentDir: dir, strategy: "inherit-parent" });
  assert.ok(readOverride(dir, "Explore"));
  const r = syncSubagentModelOverrides({ agentDir: dir, strategy: "agent-default" });
  assert.deepEqual(r.removed, ["Explore"]);
  assert.equal(readOverride(dir, "Explore"), undefined);

  // user-owned file present
  fs.mkdirSync(path.join(dir, "agents"), { recursive: true });
  const file = path.join(dir, "agents", "Explore.md");
  fs.writeFileSync(file, "---\ndescription: mine\n---\n\nmine\n");
  const r2 = syncSubagentModelOverrides({ agentDir: dir, strategy: "agent-default" });
  assert.deepEqual(r2.removed, []);
  assert.equal(r2.skipped.length, 1);
  assert.ok(fs.existsSync(file), "user file must survive agent-default");
});

test("sync: per-type override always wins over strategy", () => {
  const dir = tmpAgentDir();
  const r = syncSubagentModelOverrides({
    agentDir: dir,
    strategy: "agent-default", // would normally delete — override must win
    overrides: { Explore: "minimax/MiniMax-M3" },
  });
  assert.deepEqual(r.written, ["Explore"]);
  assert.deepEqual(r.removed, []);
  assert.ok(/^model: minimax\/MiniMax-M3$/m.test(readOverride(dir, "Explore")!));
});

test("sync: override for a non-embedded agent type → skipped with note", () => {
  const dir = tmpAgentDir();
  const r = syncSubagentModelOverrides({
    agentDir: dir,
    strategy: "inherit-parent",
    overrides: { Custom: "minimax/MiniMax-M3" },
  });
  // Explore still synced normally
  assert.deepEqual(r.written, ["Explore"]);
  const customSkip = r.skipped.find(s => s.name === "Custom");
  assert.ok(customSkip, "Custom override must be skipped");
  assert.match(customSkip!.reason, /no embedded default config/);
  assert.equal(readOverride(dir, "Custom"), undefined);
});

test("defaultAgentDir points at ~/.pi/agent", () => {
  assert.equal(defaultAgentDir(), path.join(os.homedir(), ".pi", "agent"));
});

// ---- Drift guard: embedded copies vs the installed pi-subagents ----
// If tintinweb changes the default Explore config (or pins a model on another
// default agent), this test fails and prompts re-syncing the embedded copies
// in extensions/goal-loop-subagents.ts.

test("drift: embedded Explore copy matches installed pi-subagents default", (t) => {
  const candidates = [
    path.join(os.homedir(), ".pi", "agent", "npm", "node_modules", "@tintinweb", "pi-subagents", "src", "default-agents.ts"),
    process.env.PI_SUBAGENTS_DEFAULT_AGENTS ?? "",
  ].filter(Boolean);
  const src = candidates.find(p => fs.existsSync(p));
  if (!src) {
    t.skip("pi-subagents not installed in this environment — drift check skipped");
    return;
  }
  const content = fs.readFileSync(src, "utf-8");
  const exploreBlock = content.slice(content.indexOf('"Explore",'), content.indexOf('"Plan",'));

  // model pin: either absent (upstream fixed it) or still haiku — embedded
  // copy is valid either way, but KNOWN_PINNED_DEFAULT_AGENTS must reflect
  // which defaults pin a model.
  const pinnedAgents = [...content.matchAll(/model:\s*"([^"]+)"/g)].map(m => m[1]);
  if (pinnedAgents.length === 0) {
    // Upstream removed all pins — our managed override is harmless but
    // KNOWN_PINNED_DEFAULT_AGENTS should be emptied.
    assert.deepEqual(
      [...KNOWN_PINNED_DEFAULT_AGENTS], [],
      "upstream no longer pins any default agent model — empty KNOWN_PINNED_DEFAULT_AGENTS",
    );
    t.skip("upstream removed model pins");
    return;
  }

  const descMatch = exploreBlock.match(/description:\s*"((?:[^"\\]|\\.)*)"/);
  assert.ok(descMatch, "could not extract Explore description from installed default-agents.ts");
  const installedDesc = JSON.parse(`"${descMatch![1]}"`);
  assert.equal(
    EXPLORE_DEFAULT_DESCRIPTION, installedDesc,
    "embedded Explore description drifted from installed pi-subagents — re-sync extensions/goal-loop-subagents.ts",
  );

  const spStart = exploreBlock.indexOf("systemPrompt: `") + "systemPrompt: `".length;
  const spEnd = exploreBlock.indexOf("`,", spStart);
  assert.ok(spStart > 15 && spEnd > spStart, "could not extract Explore systemPrompt");
  const installedPrompt = exploreBlock.slice(spStart, spEnd)
    .replace(/\\`/g, "`").replace(/\\\$/g, "$").replace(/\\\\/g, "\\");
  assert.equal(
    EXPLORE_DEFAULT_SYSTEM_PROMPT, installedPrompt,
    "embedded Explore systemPrompt drifted from installed pi-subagents — re-sync extensions/goal-loop-subagents.ts",
  );
});
