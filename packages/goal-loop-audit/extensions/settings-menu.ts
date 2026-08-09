// pi-goal-list-loop-audit — v0.28.0
// extensions/settings-menu.ts
//
// The /glla settings menu as a real TUI table (v0.28.0).
//
// Pre-0.28.0 used `ctx.ui.select` with flat single-line rows; v0.28.0
// replaces it with a `ctx.ui.custom` Container/Text layout featuring:
//   • a top TABS row listing all 5 sections (left/right to switch sections)
//   • a 4-column table for the active section (KEY | VALUE | SOURCE | DESCRIPTION)
//   • up/down navigation scoped to the active section's rows
//   • Enter → emit the selected row's id (caller dispatches handler)
//   • Esc / Ctrl+C → emit undefined (caller exits)
//
// Sections (5 total) map to the pre-0.28.0 menu groupings:
//   keep-going | auditor | stall-brakes | subagents | other
//
// Extracted into its own module so tests can import `buildSettingsRows` directly
// (mirrors how `readState` lives in goal-loop-core.ts) and so the renderer is
// unit-testable via synthetic handleInput calls (no live TUI needed).
//
// The pre-v0.28.0 headless fallback (`/glla` with no args and no UI) keeps its
// existing text rendering — that's still the right shape for tmux/cron. Only
// the TUI menu becomes a table.

import {
  type Component,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";

import {
  DEFAULT_AUDIT_FEEDBACK_CHARS,
  DEFAULT_QUOTA_RETRY_MINUTES,
  DEFAULT_STALL_ESCALATION_REFIRES,
} from "./goal-loop-core.ts";
import {
  DEFAULT_STALL_SIM_THRESHOLD,
  DEFAULT_STALL_SHORT_WORDS,
  WEDGE_ALERT_DEFAULT_MINUTES,
} from "./goal-loop-backoff.ts";
import type { Settings } from "./goal-settings.ts";
import { resolveEffectiveSubagentModel } from "./goal-loop-subagents.ts";

// =================================================================
// Pure row builder (testable + reusable from the headless fallback)
// =================================================================

export type SettingsSectionId =
  | "keep-going"
  | "auditor"
  | "stall-brakes"
  | "subagents"
  | "other";

export const SETTINGS_SECTIONS: readonly { id: SettingsSectionId; label: string }[] = [
  { id: "keep-going", label: "Keep-going" },
  { id: "auditor", label: "Auditor" },
  { id: "stall-brakes", label: "Stall brakes" },
  { id: "subagents", label: "Subagents" },
  { id: "other", label: "Other" },
];

/** One menu row. `id` is the stable dispatch key (caller switch(id) → handler). */
export interface SettingsRow {
  /** Stable dispatch key — used both as the table id and as the switch(id) case. */
  id: string;
  /** Which section this row belongs to. */
  section: SettingsSectionId;
  /** KEY column — the setting name (left-aligned, padded to keyW). */
  label: string;
  /** VALUE column — current effective value, e.g. `true` / `(off)` / `60`. */
  valueText: string;
  /** SOURCE column — provenance tag: `project` / `global` / `default` / `runtime` (v0.28.20: bare — brackets were chrome). */
  sourceText: string;
  /** DESCRIPTION column — one-line explanation; truncated with ellipsis when narrow. */
  description: string;
}

export type ProvenanceSource = "project" | "global" | "default";

export interface MenuProvenance {
  value: unknown;
  source: ProvenanceSource;
}

/** Defaults surfaced in the menu when the user has not set a value. */
export interface MenuDefaults {
  auditCap: number;
  stuckMaxInterventions: number;
}

export const DEFAULT_MENU_DEFAULTS: MenuDefaults = {
  auditCap: 5,
  stuckMaxInterventions: 5,
};

/** Subagent model provenance context needed to render the subagent pins column. */
export interface MenuSubagentContext {
  /** Active session model id (provider/model) — used by inherit-parent resolution. */
  sessionModel?: string;
}

/**
 * Build the full ordered list of menu rows for every section.
 * Pure: no I/O, no extension context; the renderer composes sections onto rows.
 */
export function buildSettingsRows(
  settings: Settings,
  prov: Partial<Record<keyof Settings, MenuProvenance>>,
  subagent: MenuSubagentContext = {},
  defaults: MenuDefaults = DEFAULT_MENU_DEFAULTS,
): SettingsRow[] {
  const provFor = (k: keyof Settings): MenuProvenance =>
    prov[k] ?? { value: undefined, source: "default" };
  const show = (k: keyof Settings, fallback: string): string => {
    const p = provFor(k);
    return p.value === undefined ? fallback : String(p.value);
  };
  const src = (k: keyof Settings): string => provFor(k).source;

  const rows: SettingsRow[] = [];

  // ── Keep-going ──
  rows.push(
    {
      id: "autoResume",
      section: "keep-going",
      label: "Auto-resume on load",
      valueText: show("autoResume", "default"),
      sourceText: src("autoResume"),
      description:
        "on: resume on session load too · off: never · default: hold on EVERY load — explicit resume (v0.28.21)",
    },
    {
      id: "decisionPopup",
      section: "keep-going",
      label: "Decision popup",
      valueText: show("decisionPopup", "on"),
      sourceText: src("decisionPopup"),
      description:
        "on: decision pauses pop the select() picker · off: widget card only — /goal decide reopens the picker (v0.28.23)",
    },
    {
      id: "autoAcceptDrafts",
      section: "keep-going",
      label: "Auto-accept drafts",
      valueText: show("autoAcceptDrafts", "off"),
      sourceText: src("autoAcceptDrafts"),
      description: "on: goal/loop drafts activate without the Confirm dialog (unattended rigs)",
    },
    {
      id: "aggressiveMode",
      section: "keep-going",
      label: "Aggressive mode",
      valueText: show("aggressiveMode", "off"),
      sourceText: src("aggressiveMode"),
      description:
        "flips DEFAULTS toward keep-going (autoResume, cap 10, stuck 10, wedge off, quota auto-retry, cap→TODOs); explicit per-key settings still win",
    },
  );

  // ── Auditor ──
  rows.push(
    {
      id: "auditorModel",
      section: "auditor",
      label: "Auditor model",
      valueText: show("auditorModel", "pi session model"),
      sourceText: src("auditorModel"),
      description: "provider/model override for the isolated auditor",
    },
    {
      id: "auditorThinkingLevel",
      section: "auditor",
      label: "Auditor thinking",
      valueText: show("auditorThinkingLevel", "session, floor high"),
      sourceText: src("auditorThinkingLevel"),
      description: "thinking level for the auditor session",
    },
    {
      id: "auditCap",
      section: "auditor",
      label: "Audit cap",
      valueText: show("auditCap", `${defaults.auditCap}`),
      sourceText: src("auditCap"),
      description: "pause the goal after N consecutive disapprovals (0 = unlimited)",
    },
    {
      id: "auditFeedbackChars",
      section: "auditor",
      label: "Audit feedback chars",
      valueText: show(
        "auditFeedbackChars",
        DEFAULT_AUDIT_FEEDBACK_CHARS === 0 ? "full report" : `${DEFAULT_AUDIT_FEEDBACK_CHARS}`,
      ),
      sourceText: src("auditFeedbackChars"),
      description: "cap the executor-visible disapproval report (0 = full report)",
    },
    {
      id: "quotaRetryMinutes",
      section: "auditor",
      label: "Quota retry minutes",
      valueText: show("quotaRetryMinutes", `${DEFAULT_QUOTA_RETRY_MINUTES}`),
      sourceText: src("quotaRetryMinutes"),
      description: "auto-retry a quota-exhausted auditor after N minutes",
    },
  );

  // ── Stall brakes ──
  rows.push(
    {
      id: "wedgeAlertMinutes",
      section: "stall-brakes",
      label: "Wedge alert minutes",
      valueText: show("wedgeAlertMinutes", `${WEDGE_ALERT_DEFAULT_MINUTES}`),
      sourceText: src("wedgeAlertMinutes"),
      description: "hung-command alert while the session is busy (0 = off)",
    },
    {
      id: "stuckMaxInterventions",
      section: "stall-brakes",
      label: "Stuck max interventions",
      valueText: show("stuckMaxInterventions", `${defaults.stuckMaxInterventions}`),
      sourceText: src("stuckMaxInterventions"),
      description: "consecutive stuck interventions before a loop stops",
    },
    {
      id: "stallEscalationRefires",
      section: "stall-brakes",
      label: "Stall escalation refires",
      valueText: show("stallEscalationRefires", `${DEFAULT_STALL_ESCALATION_REFIRES}`),
      sourceText: src("stallEscalationRefires"),
      description:
        "heartbeat refires with no turn before the goal pauses / loop stops (0 = never)",
    },
    {
      id: "stallShortWords",
      section: "stall-brakes",
      label: "Stall short words",
      valueText: show("stallShortWords", `${DEFAULT_STALL_SHORT_WORDS}`),
      sourceText: src("stallShortWords"),
      description: "turns with no tools AND fewer words than this count as a nudge",
    },
    {
      id: "stallSimilarityThreshold",
      section: "stall-brakes",
      label: "Stall similarity threshold",
      valueText: show("stallSimilarityThreshold", `${DEFAULT_STALL_SIM_THRESHOLD}`),
      sourceText: src("stallSimilarityThreshold"),
      description:
        "no-tool turns whose text is > this similar to the prior turn count as a nudge (0–1)",
    },
  );

  // ── Subagents ──
  rows.push(
    {
      id: "subagentModelStrategy",
      section: "subagents",
      label: "Subagent model strategy",
      valueText: show("subagentModelStrategy", "inherit-parent"),
      sourceText: src("subagentModelStrategy"),
      description:
        "inherit-parent shares your session model + quota pool; agent-default uses the upstream pi-subagents default agents",
    },
    {
      id: "subagentModelOverrides.Explore",
      section: "subagents",
      label: "Subagent Explore pin",
      valueText: settings.subagentModelOverrides?.Explore ?? "follows strategy",
      sourceText:
        settings.subagentModelOverrides?.Explore !== undefined
          ? src("subagentModelOverrides")
          : "default",
      description: "provider/model pin; always wins over strategy",
    },
    {
      id: "subagentModelOverrides.Plan",
      section: "subagents",
      label: "Subagent Plan pin",
      valueText: settings.subagentModelOverrides?.Plan ?? "follows strategy",
      sourceText:
        settings.subagentModelOverrides?.Plan !== undefined
          ? src("subagentModelOverrides")
          : "default",
      description: "provider/model pin; always wins over strategy",
    },
    {
      id: "subagentModelOverrides.general-purpose",
      section: "subagents",
      label: "Subagent general-purpose pin",
      valueText: settings.subagentModelOverrides?.["general-purpose"] ?? "follows strategy",
      sourceText:
        settings.subagentModelOverrides?.["general-purpose"] !== undefined
          ? src("subagentModelOverrides")
          : "default",
      description: "provider/model pin; always wins over strategy",
    },
    {
      id: "subagentResolved",
      section: "subagents",
      label: "Effective resolution",
      // v0.28.20: compact — strip the parenthesized qualifier (the
      // DESCRIPTION column carries semantics) and dedupe identical
      // resolutions; the old 3-part parenthesized composite never fit.
      valueText: (() => {
        const strip = (r: string) => r.replace(/ \([^)]*\)$/, "").replace(/^\((.*)\)$/, "$1");
        const parts = [
          resolveEffectiveSubagentModel("Explore", settings, subagent.sessionModel),
          resolveEffectiveSubagentModel("Plan", settings, subagent.sessionModel),
          resolveEffectiveSubagentModel("general-purpose", settings, subagent.sessionModel),
        ].map(strip);
        return parts.every((p) => p === parts[0]) ? parts[0]! : parts.join(" · ");
      })(),
      sourceText: "runtime",
      description: "effective Explore / Plan / general-purpose model given current settings",
    },
  );

  // ── Other ──
  rows.push(
    {
      id: "notifyCmd",
      section: "other",
      label: "Notify command",
      valueText: show("notifyCmd", "auto"),
      sourceText: src("notifyCmd"),
      description: "custom command ($1 = message) · unset = auto-detect notify-send/osascript · 'off' = silent",
    },
    {
      id: "tokenLimit",
      section: "other",
      label: "Token limit per goal",
      valueText: show("tokenLimit", "off"),
      sourceText: src("tokenLimit"),
      description: "per-goal token budget; pause when exceeded (0 = off)",
    },
    {
      id: "postaudit",
      section: "other",
      label: "Postaudit",
      valueText: "open sub-menu",
      sourceText: "—",
      description:
        "post-completion follow-up enqueuer: mode, triggers, cascade, caps (postaudit / reviewer)",
    },
  );

  return rows;
}

// =================================================================
// TUI table component
// =================================================================

/** Column separator (v0.28.18: box-drawing — the menu reads as a table). */
const COL_SEP = " │ ";
/** Header-rule junction matching COL_SEP's visible width. */
const COL_RULE_SEP = "─┼─";

/** Maximum width for each fixed column before truncation kicks in. */
const MAX_KEY_W = 32;
const MAX_VALUE_W = 24;
const MAX_SOURCE_W = 10;
const MIN_DESC_W = 12;

/** A minimal subset of pi-tui's Theme interface used by the renderer. */
export interface SettingsMenuTheme {
  fg(color: "accent" | "muted" | "dim" | "warning" | "success", text: string): string;
  bold(text: string): string;
}

/** Structural type for the KeybindingsManager — avoids pulling in the
 * full class so callers can supply any compatible implementation.
 * (Top-level and nested pi-tui ship separate KeybindingsManager classes
 * with private fields; structural typing sidesteps the cross-package type
 * incompatibility entirely.) */
export interface KeybindingsManagerLike {
  matches(data: string, key: string): boolean;
}

export interface SettingsMenuFactoryDeps {
  rows: SettingsRow[];
  title: string;
}

/**
 * TUI Component for the /glla settings menu. Renders a top tabs row + a
 * 4-column table for the active section. The host (extensions/loops/goal.ts)
 * constructs it via `ctx.ui.custom(...)` and dispatches the returned id
 * with `switch (id)` instead of the pre-v0.28.0 `startsWith` strings.
 */
export class SettingsMenuComponent implements Component {
  private readonly rows: SettingsRow[];
  private readonly title: string;
  private readonly requestRender: () => void;
  private readonly theme: SettingsMenuTheme;
  private readonly keybindings: KeybindingsManagerLike;
  private readonly done: (id: string | undefined) => void;

  private activeSectionIdx: number;
  private selectedIdx: number;
  private cachedWidth?: number;
  private cachedLines?: string[];

  constructor(
    deps: SettingsMenuFactoryDeps,
    requestRender: () => void,
    theme: SettingsMenuTheme,
    keybindings: KeybindingsManagerLike,
    done: (id: string | undefined) => void,
  ) {
    this.rows = deps.rows;
    this.title = deps.title;
    this.requestRender = requestRender;
    this.theme = theme;
    this.keybindings = keybindings;
    this.done = done;
    this.activeSectionIdx = 0;
    this.selectedIdx = 0;
  }

  /** Index into `SETTINGS_SECTIONS`. Exposed for tests. */
  getActiveSectionIdx(): number {
    return this.activeSectionIdx;
  }

  /** Index into the active-section's visible rows. Exposed for tests. */
  getSelectedIdx(): number {
    return this.selectedIdx;
  }

  /** Rows in the active section. Exposed for tests. */
  visibleRows(): SettingsRow[] {
    return this.rows.filter(
      (r) => r.section === SETTINGS_SECTIONS[this.activeSectionIdx]!.id,
    );
  }

  private refresh(): void {
    this.cachedWidth = undefined;
    this.cachedLines = undefined;
    this.requestRender();
  }

  /** Move within the active section, wrapping at ends. Exposed for tests. */
  move(delta: number): void {
    const vs = this.visibleRows();
    if (vs.length === 0) return;
    const n = vs.length;
    this.selectedIdx = ((this.selectedIdx + delta) % n + n) % n;
    this.refresh();
  }

  /** Switch section. -1 = left, +1 = right; wraps at ends. Exposed for tests. */
  switchSection(delta: number): void {
    const n = SETTINGS_SECTIONS.length;
    this.activeSectionIdx = ((this.activeSectionIdx + delta) % n + n) % n;
    this.selectedIdx = 0;
    this.refresh();
  }

  private resolveSelectedId(): string | undefined {
    return this.visibleRows()[this.selectedIdx]?.id;
  }

  private widths(width: number) {
    let keyW = visibleWidth(this.theme.bold("KEY"));
    let valueW = visibleWidth(this.theme.bold("VALUE"));
    let sourceW = visibleWidth(this.theme.bold("SOURCE"));
    // v0.28.18: widths are computed across ALL sections (not just the
    // active one) so the grid does NOT reflow on tab switch — a table's
    // columns stay put. The 2-char selection prefix ("▶ "/"  ") counts
    // toward the KEY column (before, rows overflowed keyW by 2 and the
    // whole VALUE column sat 2 chars right of the header's VALUE).
    for (const r of this.rows) {
      if (visibleWidth(r.label) + 2 > keyW) keyW = visibleWidth(r.label) + 2;
      if (visibleWidth(r.valueText) > valueW) valueW = visibleWidth(r.valueText);
      if (visibleWidth(r.sourceText) > sourceW) sourceW = visibleWidth(r.sourceText);
    }
    keyW = Math.min(keyW, MAX_KEY_W);
    valueW = Math.min(valueW, MAX_VALUE_W);
    sourceW = Math.min(sourceW, MAX_SOURCE_W);
    const descW = Math.max(MIN_DESC_W, width - keyW - valueW - sourceW - 3 * visibleWidth(COL_SEP));
    return { keyW, valueW, sourceW, descW };
  }

  private padEnd(text: string, width: number): string {
    const w = visibleWidth(text);
    return w >= width ? text : text + " ".repeat(width - w);
  }

  private renderBody(width: number): string[] {
    const { keyW, valueW, sourceW, descW } = this.widths(width);
    const sep = this.theme.fg("dim", COL_SEP);

    const lines: string[] = [];

    lines.push(this.theme.fg("accent", this.theme.bold(this.title)));

    // v0.28.19: color-only tabs (user call: "dropping the brackets") —
    // active = accent + bold, inactive = dim. No bracket chrome.
    lines.push(
      SETTINGS_SECTIONS.map((s, i) =>
        i === this.activeSectionIdx
          ? this.theme.fg("accent", this.theme.bold(s.label))
          : this.theme.fg("dim", s.label),
      ).join("  "),
    );

    lines.push(
      [
        this.padEnd(this.theme.bold("KEY"), keyW),
        this.padEnd(this.theme.bold("VALUE"), valueW),
        this.padEnd(this.theme.bold("SOURCE"), sourceW),
        this.theme.bold("DESCRIPTION"),
      ].join(sep),
    );
    // Header rule — the grid line that makes it read as a table.
    lines.push(
      this.theme.fg(
        "dim",
        ["─".repeat(keyW), "─".repeat(valueW), "─".repeat(sourceW), "─".repeat(descW)].join(COL_RULE_SEP),
      ),
    );

    const vs = this.visibleRows();
    if (vs.length === 0) {
      lines.push(this.theme.fg("muted", "(no settings in this section)"));
    } else {
      vs.forEach((r, i) => {
        const selected = i === this.selectedIdx;
        const prefix = selected ? "▶ " : "  ";
        // v0.28.18: KEY (incl. prefix) and VALUE are truncated to their
        // column — before, an over-long VALUE (e.g. the subagent effective-
        // resolution composite) overflowed and shoved SOURCE/DESCRIPTION
        // right on that row only, breaking the grid.
        const row = [
          this.padEnd(truncateToWidth(prefix + r.label, keyW, "…"), keyW),
          this.padEnd(truncateToWidth(r.valueText, valueW, "…"), valueW),
          this.padEnd(truncateToWidth(r.sourceText, sourceW, "…"), sourceW),
          truncateToWidth(r.description, descW, "…"),
        // Selected row: plain separators — the whole row gets one accent
        // wrap; a nested dim separator's reset code would end it early.
        ].join(selected ? COL_SEP : sep);
        lines.push(selected ? this.theme.fg("accent", row) : row);
      });
    }

    lines.push(
      this.theme.fg(
        "dim",
        "←/→ tab · ↑/↓ move · enter drill-in · esc exit",
      ),
    );

    return lines;
  }

  render(width: number): string[] {
    if (this.cachedLines && this.cachedWidth === width) return this.cachedLines;
    this.cachedWidth = width;
    this.cachedLines = this.renderBody(width);
    return this.cachedLines;
  }

  handleInput(data: string): void {
    if (this.keybindings.matches(data, "tui.select.confirm")) {
      this.done(this.resolveSelectedId());
      return;
    }
    if (this.keybindings.matches(data, "tui.select.cancel") || data === "\x1b") {
      this.done(undefined);
      return;
    }
    if (this.keybindings.matches(data, "tui.select.up")) {
      this.move(-1);
      return;
    }
    if (this.keybindings.matches(data, "tui.select.down")) {
      this.move(+1);
      return;
    }
    // Left/right cycle sections. The Keybindings type only has up/down, so we
    // match the raw CSI arrow-key sequences directly. Some terminals emit
    // SS3 ("\x1bOD"/"\x1bOC") instead — fall back to those too.
    if (data === "\x1b[D" || data === "\x1bOD") {
      this.switchSection(-1);
      return;
    }
    if (data === "\x1b[C" || data === "\x1bOC") {
      this.switchSection(+1);
      return;
    }
    if (data === "\t") {
      this.switchSection(+1);
      return;
    }
    if (data === "\x1b[Z") {
      this.switchSection(-1);
      return;
    }
  }

  invalidate(): void {
    this.cachedWidth = undefined;
    this.cachedLines = undefined;
  }
}
