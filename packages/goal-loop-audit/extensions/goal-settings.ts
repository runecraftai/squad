// pi-goal-list-loop-audit — v0.25.0
// extensions/goal-settings.ts
//
// The settings layer, extracted from loops/goal.ts so tests can drive it
// without importing the whole extension. Two-tier config (v0.7.0): GLOBAL
// is the normal home, PROJECT the rare local override. Resolution:
// project > global > defaults (per key).

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  DEFAULT_AUDIT_FEEDBACK_CHARS,
  DEFAULT_QUOTA_RETRY_MINUTES,
  mergeSettings,
  piGlaDir,
} from "./goal-loop-core.ts";
import type { SubagentModelStrategy } from "./goal-loop-subagents.js";

export interface Settings {
  /** "provider/model-id" or bare "model-id". Unset → session model. */
  auditorModel?: string;
  auditorThinkingLevel?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  /** Shell command run on goal complete / goal pause / loop stop; message passed as $1. */
  notifyCmd?: string;
  /** Per-goal token budget; crossing it pauses the goal. Off by default
   * (opt-in guard, v0.12.0): unset/0 = no budget. */
  tokenLimit?: number;
  /** v0.23.2: minutes of busy-but-silent before the wedge alert fires
   * (hung-command detector). Unset = 45; 0 = off. */
  wedgeAlertMinutes?: number;
  /** on → restored goals/loops/lists auto-resume even in fresh sessions
   * (unattended rigs). Default off: restore holds until /goal resume. */
  autoResume?: boolean;
  /** v0.28.23: off → decision pauses don't pop the select() picker (the
   * widget card still shows the options; /goal decide opens it on demand).
   * Default on; unattended rigs have no UI so this never fires there. */
  decisionPopup?: boolean;
  /** v0.28.14: what happens to stale carryover (paused goal, waiting list,
   * held loop from before this session) when NEW work activates.
   * pause (default) = leave it + ONE summary; clear = drop it all honestly;
   * resume = legacy silent stacking. */
  carryover?: "resume" | "pause" | "clear";
  /** v0.24.2: pause the goal after N consecutive auditor disapprovals (0 = unlimited).
   * Default 5 (raised from 3 in v0.25.0, contract item 7). */
  auditCap?: number;
  /** Maximum auditor-report characters returned to the executor after a
   * disapproval (0 = full report). Default 0 (full report). */
  auditFeedbackChars?: number;
  /** v0.25.0: flip the continuation defaults toward keep-going
   * (contract item 5): autoResume on, auditCap 10, stuckMax 10, wedge off,
   * quota errors auto-retry silently. Explicit per-key settings still win. */
  aggressiveMode?: boolean;
  /** Minutes to wait before auto-retrying a quota-exhausted auditor when
   * the upstream gave no Retry-After hint (contract item 11). Default 60. */
  quotaRetryMinutes?: number;
  /** Consecutive stuck interventions before a loop stops (default 5,
   * 10 under aggressiveMode). */
  stuckMaxInterventions?: number;
  /** v0.26.1: consecutive heartbeat refires without a real turn before
   * the goal pauses / loop stops (default 5; 0 = never escalate). */
  stallEscalationRefires?: number;
  /** v0.27.3: a turn with no tool calls AND fewer words than this is a
   * nudge. Default 15 words. Higher = stricter (more pauses). */
  stallShortWords?: number;
  /** v0.27.3: a turn with no tool calls whose text trigram-similarity to
   * the prior assistant turn exceeds this is a nudge. Default 0.6. Higher
   * = stricter (more pauses). */
  stallSimilarityThreshold?: number;
  /** on → propose_* drafts activate WITHOUT the Confirm dialog and the
   * interview floor is skipped — the seed carries the intent (unattended
   * rigs). Default off: nothing activates before the user confirms. */
  autoAcceptDrafts?: boolean;
  /** v0.24.6: subagent model strategy for pi-subagents default agents that
   * pin a model (Explore pins claude-haiku-4-5, which silently routes
   * subagents to a different provider/quota pool than the session).
   * "inherit-parent" (default) writes a managed ~/.pi/agent/agents/Explore.md
   * override without the model pin so subagents share the session model and
   * its quota; "agent-default" restores upstream behavior. Applies to NEW
   * sessions (pi-subagents registers agents at session start). */
  /** v0.26.0: reviewer (post-completion follow-up enqueuer) config —
   * project-scoped; see extensions/reviewer.ts DEFAULT_REVIEWER_CONFIG.
   * v0.27.5: superseded by `postaudit` (same shape, terminology reflects
   * the auditor-adjacent role). Both keys are read; `postaudit` wins
   * when both are present. `reviewer` is kept for backwards compat. */
  reviewer?: Record<string, unknown>;
  /** v0.27.5: post-completion audit config. Same shape as `reviewer`. */
  postaudit?: Record<string, unknown>;
  subagentModelStrategy?: SubagentModelStrategy;
  /** v0.24.6: per-agent-type model pin, e.g. { "Explore": "minimax/MiniMax-M3" }.
   * Always wins over subagentModelStrategy — the managed override is written
   * WITH this pin regardless of strategy. */
  subagentModelOverrides?: Record<string, string>;
  /** v0.27.9: per-tool overrides — allowlist (force tools visible despite
   * an external modlist), hidden (force tools hidden even when allowed by
   * the session), and per-tool config (Record<toolName, Record<key, value>>
   * — extensible for tool-specific knobs like timeouts, formats, etc.). */
  toolOverrides?: {
    /** Tools that MUST be active even when an external allowlist hides them. */
    allow?: string[];
    /** Tools that MUST be hidden even when the session allows them. */
    hide?: string[];
    /** Per-tool configuration knobs (extensible). */
    perToolConfig?: Record<string, Record<string, unknown>>;
  };
}

export const DEFAULT_SETTINGS: Settings = {
  // Unset = follow the pi session thinking level (user selects thinking in
  // pi, auditor follows), floor "high" — the auditor is the verification
  // gate, depth is worth more there than speed. /glla thinking= overrides.
  auditorThinkingLevel: undefined,
  // v0.24.6: subagents inherit the session model by default — one quota
  // pool, no surprise 403s from a pinned default agent's provider.
  subagentModelStrategy: "inherit-parent",
  auditFeedbackChars: DEFAULT_AUDIT_FEEDBACK_CHARS,
  // v0.25.0 (contract Section B): keep-going is opt-in via aggressiveMode;
  // the dial flips DEFAULTS, never explicit per-key user settings.
  aggressiveMode: false,
  quotaRetryMinutes: DEFAULT_QUOTA_RETRY_MINUTES,
};

export function globalSettingsPath(): string {
  // v0.28.18: test/embedding override — the suite must be hermetic from
  // the developer's real global settings file (a user setting autoAccept
  // globally once made draft-Confirm tests auto-accept and fail).
  const override = process.env.GLLA_GLOBAL_SETTINGS_PATH;
  if (override) return override;
  return path.join(os.homedir(), ".pi", "agent", "pi-goal-list-loop-audit.settings.json");
}

export function projectSettingsPath(cwd: string): string {
  return path.join(piGlaDir(cwd), "settings.json");
}

export function readSettingsFile(file: string): Partial<Settings> {
  try {
    if (!fs.existsSync(file)) return {};
    const parsed = JSON.parse(fs.readFileSync(file, "utf-8"));
    return typeof parsed === "object" && parsed !== null ? parsed as Partial<Settings> : {};
  } catch {
    return {};
  }
}

export function loadSettings(cwd: string): Settings {
  return mergeSettings(
    DEFAULT_SETTINGS as unknown as Record<string, unknown>,
    readSettingsFile(globalSettingsPath()) as Record<string, unknown>,
    readSettingsFile(projectSettingsPath(cwd)) as Record<string, unknown>,
  ) as unknown as Settings;
}

/** Every provenance-tracked key (the /glla headless display + UI). */
export const SETTINGS_KEYS: Array<keyof Settings> = [
  "auditorModel",
  "auditorThinkingLevel",
  "notifyCmd",
  "tokenLimit",
  "wedgeAlertMinutes",
  "autoResume",
  "decisionPopup",
  "carryover",
  "autoAcceptDrafts",
  "auditCap",
  "auditFeedbackChars",
  "subagentModelStrategy",
  "subagentModelOverrides",
  "aggressiveMode",
  "quotaRetryMinutes",
  "stuckMaxInterventions",
  "stallEscalationRefires",
  "stallShortWords",
  "stallSimilarityThreshold",
  "postaudit",
  "toolOverrides",
];

/** Where each effective setting comes from (for the /glla display). */
export function settingsProvenance(cwd: string): Record<keyof Settings, { value: unknown; source: "project" | "global" | "default" }> {
  const proj = readSettingsFile(projectSettingsPath(cwd));
  const glob = readSettingsFile(globalSettingsPath());
  const effective = loadSettings(cwd);
  const out: Record<string, { value: unknown; source: "project" | "global" | "default" }> = {};
  for (const k of SETTINGS_KEYS) {
    if ((proj as Record<string, unknown>)[k] !== undefined) out[k] = { value: (proj as any)[k], source: "project" };
    else if ((glob as Record<string, unknown>)[k] !== undefined) out[k] = { value: (glob as any)[k], source: "global" };
    else out[k] = { value: (effective as any)[k], source: "default" };
  }
  return out as Record<keyof Settings, { value: unknown; source: "project" | "global" | "default" }>;
}

export function saveSettings(scope: "global" | "project", cwd: string, patch: Partial<Settings>): void {
  const file = scope === "global" ? globalSettingsPath() : projectSettingsPath(cwd);
  const current = readSettingsFile(file);
  const next: Record<string, unknown> = { ...current };
  for (const [k, v] of Object.entries(patch)) {
    if (v === undefined) delete next[k]; // key=unset removes the key
    else next[k] = v;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(next, null, 2));
}
