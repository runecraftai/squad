/**
 * pi-goal-list-loop-audit — v0.9.0
 * extensions/goal-loop-display.ts
 *
 * Pure display builders for the live TUI (status line + above-editor widget).
 * No pi imports — unit tests exercise these directly. The orchestrator calls
 * No RUNTIME imports at all: tests run under `node --experimental-strip-types`,
 * which does not rewrite `.js` → `.ts` specifiers — a value import from
 * ./goal-loop-core.js breaks the suite (type-only imports are erased, safe).
 * ctx.ui.setStatus/setWidget with whatever these return.
 */

import type { Goal, State } from "./goal-loop-core.js";
import { isPersistenceDegraded, lastPersistenceFailure } from "./goal-loop-core.js";
import { HELD_ON_RESTORE, type LoopState } from "./goal-loop-forever.js";

/** v0.28.17: a loop parked by the session-restore gate (was active when the
 * last session ended). Held loops must stay VISIBLE — before, only
 * state.loop?.active rendered anything and a reload made the loop vanish
 * from the always-on UI (user report 2026-07-29: "loops are the most
 * immature"). Stopped loops (any other stopReason) stay invisible. */
function heldLoop(state: State): LoopState | undefined {
  const l = state.loop;
  return l && !l.active && l.stopReason === HELD_ON_RESTORE ? l : undefined;
}

// ---- formatters ----

export function fmtElapsed(ms: number): string {
  if (ms < 0) ms = 0;
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  // Seconds stay visible up to the hour: the elapsed counter is the
  // liveness signal — minute-only granularity looks frozen on a 1s tick.
  if (m < 60) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${String(m % 60).padStart(2, "0")}m`;
}

export function fmtTokens(n: number): string {
  if (n < 1000) return `${n}`;
  if (n < 100_000) return `${(n / 1000).toFixed(1)}k`;
  return `${Math.round(n / 1000)}k`;
}

export function truncate(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, Math.max(0, max - 1)) + "…";
}

/**
 * Word-wrap to `width`, capped at `maxLines` (v0.27.1). A pause is the one
 * state where the FULL text matters — the reason often carries a decision
 * the user must make (dedup choices, impossible-verdict narrowing), and a
 * 60-char truncate hid it. Over-long words are hard-split; when the cap
 * cuts content the last line ends with "…" (the pause-time notification
 * and /goal status always carry the full text).
 */
export function wrap(s: string, width: number, maxLines: number): string[] {
  const norm = s.replace(/\s+/g, " ").trim();
  const words = norm.split(" ").filter(Boolean);
  const all: string[] = [];
  let cur = "";
  for (let w of words) {
    const next = cur ? `${cur} ${w}` : w;
    if (next.length <= width) { cur = next; continue; }
    if (cur) all.push(cur);
    while (w.length > width) { all.push(w.slice(0, width)); w = w.slice(width); }
    cur = w;
  }
  if (cur) all.push(cur);
  if (all.length === 0) all.push("");
  if (all.length <= maxLines) return all;
  const out = all.slice(0, maxLines);
  // The last kept line already fits within width — truncate() would leave it
  // unmarked, so force the ellipsis to signal "more in /goal status".
  out[maxLines - 1] = out[maxLines - 1]!.slice(0, Math.max(0, width - 1)) + "…";
  return out;
}

/**
 * Width-aware truncation budget (v0.22.2). The hardcoded caps are FLOORS for
 * narrow terminals; when the terminal is wider, lines may use the available
 * width instead of being cut at a fixed ~60 chars (pi-tasks truncates at
 * tui.terminal.columns — match that behavior). `prefixCols` is the visible
 * width of the static prefix on the line (branch glyph + pi's 1-col gutter).
 */
function budgetFor(width: number | undefined, prefixCols: number, floor: number): number {
  if (!width || width <= 0) return floor;
  return Math.max(floor, width - 1 - prefixCols);
}

function sinceIso(iso: string): number {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? Date.now() - t : 0;
}

// ---- semantic colors (optional; tests call without a theme → plain strings) ----

export type DisplayColor = "accent" | "success" | "warning" | "error" | "muted" | "dim";
export interface DisplayTheme {
  fg(color: DisplayColor, text: string): string;
}
const paint = (theme: DisplayTheme | undefined, color: DisplayColor, text: string): string => (theme ? theme.fg(color, text) : text);

/** Pause reasons that mean "something broke", not "waiting on the user". */
const ERROR_PAUSE = /token limit|stalled|infra|auditor.*fail/i;
const pauseIsError = (g: Goal): boolean => ERROR_PAUSE.test(g.pauseReason ?? "");

/** v0.28.22: the rendering class of a pause — declared kind wins; legacy
 * pauses (no kind) fall back to the error-regex so old states still
 * classify sensibly. */
type PauseKind = "decision" | "error" | "wait" | "blocked";
const pauseKind = (g: Goal): PauseKind | undefined => g.pauseKind ?? (pauseIsError(g) ? "error" : undefined);

/** v0.28.22: "06:40 UTC" from an ISO string (wait-pause countdown). */
const shortClock = (iso: string): string => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso.slice(0, 16) : d.toISOString().slice(11, 16) + " UTC";
};

// ---- status line (one-liner, always-on) ----

export interface AuditDisplayProgress {
  currentTool?: string;
  label?: string;
  elapsedMs?: number;
  /** v0.25.4: last progress-event time — the widget flags auditor-quiet
   * stalls when this goes stale while the audit is in flight. */
  lastEventAt?: number;
}

/**
 * One-line status for ctx.ui.setStatus("pi-glla", …).
 * Returns undefined when nothing is being supervised (clears the segment).
 */
export function buildStatusText(state: State, audit?: AuditDisplayProgress | null, now = Date.now(), theme?: DisplayTheme, extras?: { stalls?: number }): string | undefined {
  if (state.loop?.active) {
    const l = state.loop;
    // v0.26.1: surface the refire streak — a spinning supervisor is the
    // zombie signature (hegemon incident: 619 refires, 0 turns).
    const stallSuffix = (extras?.stalls ?? 0) > 0 ? ` · ${paint(theme, "warning", `stalls:${extras!.stalls}`)}` : "";
    // v0.23.0: metricless spec loop — no arrow/best/stall, no plateau.
    if (!l.measureCmd) {
      return `glla: loop ${paint(theme, "accent", "∞")} iter ${l.iteration}${l.maxIterations > 0 ? `/${l.maxIterations}` : ""} · metricless${stallSuffix}`;
    }
    const arrow = paint(theme, "accent", l.direction === "min" ? "↓" : "↑");
    const stallText = `stall ${l.stallCount}/${l.plateauWindow}`;
    const stall = l.stallCount >= l.plateauWindow - 1 ? paint(theme, "warning", stallText) : stallText;
    return `glla: loop ${arrow} iter ${l.iteration}/${l.maxIterations > 0 ? l.maxIterations : "∞"} · best ${l.bestValue ?? "n/a"} · ${stall}${stallSuffix}`;
  }
  const g = state.goal;
  const held = heldLoop(state);
  // v0.28.17: a held loop rides every goal state as a compact suffix.
  const heldSuffix = held ? paint(theme, "warning", " · loop⏸held") : "";
  if (!g) {
    if (held) return `glla: loop ${paint(theme, "warning", "⏸ held")} · iter ${held.iteration} — /loop to resume`;
    return undefined;
  }
  if (g.status === "auditing") {
    const tool = audit?.currentTool ? ` · ${audit.currentTool}` : "";
    return `glla: ${paint(theme, "accent", "auditing…")}${tool}${heldSuffix}`;
  }
  if (g.status === "paused") {
    // v0.28.22: the status line names the ACTIONABILITY, not the reason —
    // "decision needed" / "action needed" / "waiting" tell you at a glance
    // whether the session needs you. Legacy pauses keep the reason dump.
    const kind = pauseKind(g);
    if (kind === "decision") return `glla: ${g.policy} ${paint(theme, "accent", "⏸ decision needed")}${heldSuffix}`;
    if (kind === "error") return `glla: ${g.policy} ${paint(theme, "error", `⏸ action needed — ${truncate(g.pauseReason ?? "", 30)}`)}${heldSuffix}`;
    if (kind === "wait") return `glla: ${g.policy} ${paint(theme, "dim", `⏳ waiting${g.pauseResumeAt ? ` · resumes ${shortClock(g.pauseResumeAt)}` : ""}`)}${heldSuffix}`;
    const label = `${g.policy} paused ⏸ ${truncate(g.pauseReason ?? "", 40)}`;
    return `glla: ${paint(theme, pauseIsError(g) ? "error" : "warning", label)}${heldSuffix}`;
  }
  if (g.status === "active") {
    // v0.28.1 (S1/S2): a stale-handle interrupt keeps the goal ACTIVE (the
    // next fresh session auto-resumes it) — say so instead of looking healthy.
    if (g.interruptedAt) {
      return `glla: ${g.policy} ${paint(theme, "error", "⚠ interrupted — stale handle · auto-resumes on pi restart")}${heldSuffix}`;
    }
    // v0.24.7: list policy gets its own wording — a queue item is not a goal.
    // v0.28.11 (U10): goal policy joins it — "list 29" read as a command
    // fragment; "29 queued" says what the number IS. Both policies now
    // render "… · N queued".
    const n = state.list?.length ?? 0;
    const queue = n === 0 ? "" : ` · ${n} queued`;
    const tasks = g.taskList ? ` ${countDone(g)}/${countTotal(g)} tasks ·` : "";
    return `glla: ${g.policy} ${paint(theme, "success", "●")}${tasks} ${fmtElapsed(now - Date.parse(g.createdAt))}${queue}${heldSuffix}`;
  }
  // complete/aborted → clear — but a held loop still shows.
  if (held) return `glla: loop ${paint(theme, "warning", "⏸ held")} · iter ${held.iteration} — /loop to resume`;
  return undefined;
}

function countDone(g: Goal): number {
  let n = 0;
  const walk = (ts: Array<{ status: string; subtasks?: any[] }>) => {
    for (const t of ts) {
      if (t.status === "complete") n++;
      if (t.subtasks) walk(t.subtasks);
    }
  };
  walk(g.taskList?.tasks ?? []);
  return n;
}

function countTotal(g: Goal): number {
  let n = 0;
  const walk = (ts: Array<{ subtasks?: any[] }>) => {
    for (const t of ts) {
      n++;
      if (t.subtasks) walk(t.subtasks);
    }
  };
  walk(g.taskList?.tasks ?? []);
  return n;
}

// ---- above-editor widget (multi-line panel) ----

/**
 * Widget lines for ctx.ui.setWidget("pi-glla", lines).
 * Returns undefined when nothing is worth showing.
 */
export function buildWidgetLines(state: State, audit?: AuditDisplayProgress | null, now = Date.now(), theme?: DisplayTheme, width?: number, extras?: { stalls?: number }): string[] | undefined {
  const inner = buildWidgetLinesInner(state, audit, now, theme, width, extras);
  // v0.28.6 (E1): a persistence failure outranks everything — first line,
  // on every render, until a write lands again.
  if (inner && isPersistenceDegraded()) {
    const err = lastPersistenceFailure();
    return [paint(theme, "error", `⚠ persistence degraded — .pi-glla writes failing (${truncate(err?.error ?? "disk error", 40)}); state in RAM`), ...inner];
  }
  return inner;
}

function buildWidgetLinesInner(state: State, audit?: AuditDisplayProgress | null, now = Date.now(), theme?: DisplayTheme, width?: number, extras?: { stalls?: number }): string[] | undefined {
  if (state.loop?.active) return loopLines(state.loop, now, theme, width, extras);
  const g = state.goal;
  const held = heldLoop(state);
  if (!g || g.status === "complete" || g.status === "aborted") {
    // v0.28.17: no visible goal — the held loop gets its own card.
    return held ? heldLoopLines(held, now, theme, width) : undefined;
  }
  const lines = goalLines(g, state, audit, now, theme, width);
  // v0.28.17: a held loop rides the goal card as a trailing line.
  if (held) {
    lines.push(`${paint(theme, "warning", "⏸")} ${truncate(held.target, budgetFor(width, 3, 64))}`);
    lines.push(`└─ ${paint(theme, "dim", `loop held · iter ${held.iteration} — /loop to resume`)}`);
  }
  return lines;
}

/** v0.28.17: standalone card for a restore-held loop (no goal visible). */
function heldLoopLines(l: LoopState, now: number, theme?: DisplayTheme, width?: number): string[] {
  return [
    `${paint(theme, "warning", "⏸")} ${truncate(l.target, budgetFor(width, 3, 64))}`,
    `├─ loop held · iter ${l.iteration} · ${fmtElapsed(now - Date.parse(l.startedAt))} so far`,
    `└─ ${paint(theme, "dim", "held by the session-restore gate — /loop to resume, /loop stop to drop")}`,
  ];
}

// Branch lines sit flush-left (pi-tasks convention): pi's widget renderer
// adds its own one-space gutter, so any indent here doubles up.
function goalLines(g: Goal, state: State, audit: AuditDisplayProgress | null | undefined, now: number, theme?: DisplayTheme, width?: number): string[] {
  // Head glyph is ● (not ◆): U+25C6 renders as a color-emoji diamond in some
  // terminal fonts and ignores ANSI color; ● takes the paint everywhere.
  const icon =
    g.status === "paused"
      ? paint(theme, pauseIsError(g) ? "error" : "warning", "⏸")
      : g.status === "auditing"
        ? paint(theme, "accent", "⟡")
        : paint(theme, "success", "●");
  const head = `${icon} ${truncate(g.objective.replace(/\s+/g, " "), budgetFor(width, 3, 64))}`;
  // v0.24.7: a list item is named as such and points at /list — before,
  // the widget called it "active" and hinted "/goal status", reading as if
  // queue work were a standalone goal.
  const isList = g.policy === "list";
  const statusWord = g.status === "active" ? paint(theme, "success", "active") : g.status;
  // v0.28.30: the status line ALWAYS names the type (user note: "I don't
  // always see the type — I'd need to scroll up to see if goal/list/loop").
  // Before, only list items were named; a plain goal's card said "paused ·
  // 3m" with no type word. The loop surface has its own card.
  const typeWord = isList ? "list item · " : "goal · ";
  // Token segment only when a budget is set (v0.22.0): the guard is opt-in,
  // and "0/0 tok" carried no information when off.
  const tokenLimit = g.usage?.tokensLimit ?? 0;
  const tokens = tokenLimit > 0 ? ` · ${paint(theme, "dim", `${fmtTokens(g.usage?.tokensUsed ?? 0)}/${fmtTokens(tokenLimit)} tok`)}` : "";
  const lines = [head, `├─ ${typeWord}${statusWord} · ${fmtElapsed(now - Date.parse(g.createdAt))}${tokens}`];
  if (g.status === "auditing") {
    lines.push(`├─ auditor: ${audit?.label ?? "running"}${audit?.currentTool ? ` · ${truncate(audit.currentTool, 30)}` : ""}`);
    // v0.25.4: auditor-quiet stall — progress events stopped arriving
    // while the audit is in flight (hung model call, stuck tool).
    const quietMs = audit?.lastEventAt !== undefined ? now - audit.lastEventAt : 0;
    if (quietMs > 3 * 60_000) {
      lines.push(`└─ ${paint(theme, "warning", `auditor quiet ${fmtElapsed(quietMs)} — may be stuck; Esc aborts, verdict is not counted`)}`);
    } else if (audit?.elapsedMs) lines.push(`└─ ${paint(theme, "dim", `${fmtElapsed(audit.elapsedMs)} in isolated session`)}`);
    else lines.push(`└─ ${paint(theme, "dim", "isolated session, read-only tools")}`);
    return lines;
  }
  if (g.status === "paused" && g.pauseReason) {
    const kind = pauseKind(g);
    const isErr = kind === "error";
    const budget = budgetFor(width, 3, 60);
    // v0.28.22: actionability banner — a decision pause, an operational
    // failure, and a time-gated wait must not look alike (user report:
    // "if something actionable is going on it can be hard to tell").
    if (kind === "decision") lines.push(`├─ ${paint(theme, "accent", "decision needed — your call unblocks this")}`);
    else if (kind === "error") lines.push(`├─ ${paint(theme, "error", "action needed — this won't fix itself")}`);
    else if (kind === "wait") lines.push(`├─ ${paint(theme, "dim", "waiting — nothing for you to do")}`);
    // v0.27.1: wrap reason + suggested action (see wrap()). v0.28.22:
    // decision/wait reasons cap at 2 lines — the options/countdown below
    // carry the actionable content; error reasons keep 3.
    const reasonPaint = isErr ? "error" : kind === "wait" ? "dim" : "warning";
    wrap(g.pauseReason, budget, kind === "decision" || kind === "wait" ? 2 : 3).forEach((w, i) => {
      lines.push(`${i === 0 ? "├─" : "│ "} ${paint(theme, reasonPaint, w)}`);
    });
    // v0.28.22: decision options — one numbered line each (Claude Code /
    // muselinn-Ask convention), the recommended one accented and flagged.
    if (kind === "decision" && g.pauseOptions && g.pauseOptions.length > 0) {
      g.pauseOptions.slice(0, 6).forEach((opt, i) => {
        const rec = g.pauseRecommended === i + 1;
        const text = `${i + 1}. ${truncate(opt, budget - 4)}${rec ? " ◂ recommended" : ""}`;
        lines.push(`│  ${paint(theme, rec ? "accent" : "dim", text)}`);
      });
      if (g.pauseOptions.length > 6) lines.push(`│  ${paint(theme, "dim", `… and ${g.pauseOptions.length - 6} more`)}`);
    }
    // v0.28.22: wait countdown — when the pause lifts on its own.
    if (kind === "wait" && g.pauseResumeAt) {
      const ms = Date.parse(g.pauseResumeAt) - now;
      const when = Number.isNaN(ms) ? g.pauseResumeAt : ms <= 0 ? "now" : `${shortClock(g.pauseResumeAt)} (in ${fmtElapsed(ms)})`;
      lines.push(`├─ ${paint(theme, "dim", `resumes ${when} — or /goal resume now`)}`);
    }
    // v0.27.1: what survives the pause — the first question at a pause is
    // "did I lose the work?". Answer it on the card.
    // v0.27.9: when the goal has no telemetry yet (restored-in-fresh-session
    // before the first turn), render "awaiting first turn" instead of "saved"
    // — the latter was misleading because no work was ever "saved" before the
    // session ended.
    const spent: string[] = [];
    const tokUsed = g.usage?.tokensUsed ?? 0;
    const audits = g.auditHistory?.length ?? 0;
    if (tokUsed > 0) spent.push(`${fmtTokens(tokUsed)} tok spent`);
    if (audits > 0) spent.push(`${audits} audit${audits === 1 ? "" : "s"}`);
    const hasTelemetry = spent.length > 0;
    const savedLine = hasTelemetry
      ? `saved — ${spent.join(" · ")} · resumes exactly here`
      : `awaiting first turn — resumes exactly here`;
    if (g.pauseSuggestedAction) {
      lines.push(`├─ ${paint(theme, "dim", truncate(savedLine, budget))}`);
      const wrapped = wrap(g.pauseSuggestedAction, budget, 3);
      // v0.28.22: for ACTION NEEDED pauses the action is the point — pop it.
      const actionPaint = kind === "error" ? "warning" : "dim";
      wrapped.forEach((w, i) => lines.push(`${i === wrapped.length - 1 ? "└─" : "│ "} ${paint(theme, actionPaint, w)}`));
    } else {
      lines.push(`└─ ${paint(theme, "dim", truncate(savedLine, budget))}`);
    }
    return lines;
  }
  const next = nextPending(g);
  if (next) lines.push(`├─ next: ${truncate(next, budgetFor(width, 9, 56))}`);
  const queue = state.list?.length ?? 0;
  const footer = isList
    ? `${queue > 0 ? `${queue} queued · ` : ""}/list · /glla`
    : `${queue > 0 ? `${queue} queued · ` : ""}/goal status · /glla`;
  lines.push(`└─ ${paint(theme, "dim", footer)}`);
  return lines;
}

function loopLines(l: LoopState, now: number, theme?: DisplayTheme, width?: number, extras?: { stalls?: number }): string[] {
  // v0.26.1: the refire streak, shown only while nonzero.
  const stallNote = (extras?.stalls ?? 0) > 0 ? ` · ${paint(theme, "warning", `stalls:${extras!.stalls}`)}` : "";
  // v0.23.0: metricless spec loop — no arrow/best/stall, no plateau.
  if (!l.measureCmd) {
    const lines = [
      `${paint(theme, "accent", "●")} ${truncate(l.target, budgetFor(width, 3, 64))}`,
      `├─ loop ∞ iter ${l.iteration}${l.maxIterations > 0 ? `/${l.maxIterations}` : ""} · ${fmtElapsed(now - Date.parse(l.startedAt))}${stallNote}`,
      `└─ ${paint(theme, "dim", "metricless — work the spec (no plateau)")}`,
    ];
    if (l.branchName) lines.push(`⎇ ${paint(theme, "muted", truncate(l.branchName, budgetFor(width, 3, 50)))}`);
    return lines;
  }
  const arrow = paint(theme, "accent", l.direction === "min" ? "↓" : "↑");
  const best = paint(theme, "success", `${l.bestValue ?? "n/a"}`);
  const stallText = `stall ${l.stallCount}/${l.plateauWindow}`;
  const stall = l.stallCount >= l.plateauWindow - 1 ? paint(theme, "warning", stallText) : stallText;
  const lines = [
    `${paint(theme, "accent", "●")} ${truncate(l.target, budgetFor(width, 3, 64))}`,
    `├─ loop ${arrow} iter ${l.iteration}/${l.maxIterations > 0 ? l.maxIterations : "∞"} · ${fmtElapsed(now - Date.parse(l.startedAt))}`,
    `├─ best ${best} · last ${l.lastValue ?? "n/a"} · ${stall}`,
    `└─ ${paint(theme, "dim", truncate(l.measureCmd, budgetFor(width, 3, 56)))}`,
  ];
  if (l.branchName) lines.push(`⎇ ${paint(theme, "muted", truncate(l.branchName, budgetFor(width, 3, 50)))}`);
  return lines;
}

function nextPending(g: Goal): string | undefined {
  const tasks = g.taskList?.tasks ?? [];
  const queue = [...tasks];
  while (queue.length > 0) {
    const t = queue.shift()!;
    if (t.status === "pending") return t.title;
    if (t.subtasks) queue.push(...t.subtasks);
  }
  return undefined;
}
