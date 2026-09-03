import { getLanguageFromPath, highlightCode } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, type Component } from "@earendil-works/pi-tui";

export type Foreground =
  | "accent"
  | "dim"
  | "error"
  | "mdHeading"
  | "mdQuote"
  | "muted"
  | "success"
  | "text"
  | "toolDiffAdded"
  | "toolDiffContext"
  | "toolDiffRemoved"
  | "toolOutput"
  | "toolTitle"
  | "warning";

export interface ThemeLike {
  fg(color: Foreground, text: string): string;
  bg(color: "toolErrorBg" | "toolSuccessBg", text: string): string;
  bold(text: string): string;
}

export interface DiffRow {
  kind: "change" | "context" | "header";
  oldText?: string;
  newText?: string;
  text?: string;
}

const TOKEN_PATTERN = /(\s+|[A-Za-z0-9_$]+|[^A-Za-z0-9_$\s]+)/g;

export function textContent(content: readonly { type: string; text?: string }[]): string {
  return content
    .filter((item): item is { type: "text"; text: string } => item.type === "text" && typeof item.text === "string")
    .map((item) => item.text)
    .join("\n");
}

export function parseDiffRows(diff: string): DiffRow[] {
  const rows: DiffRow[] = [];
  let removed: string[] = [];
  let added: string[] = [];

  const flushChanges = () => {
    const count = Math.max(removed.length, added.length);
    for (let index = 0; index < count; index += 1) {
      rows.push({
        kind: "change",
        oldText: removed[index],
        newText: added[index],
      });
    }
    removed = [];
    added = [];
  };

  for (const line of diff.split("\n")) {
    if (line.startsWith("@@")) {
      flushChanges();
      rows.push({ kind: "header", text: line });
    } else if (line.startsWith("---") || line.startsWith("+++")) {
      flushChanges();
      rows.push({ kind: "header", text: line });
    } else if (line.startsWith("-")) {
      removed.push(line.slice(1));
    } else if (line.startsWith("+")) {
      added.push(line.slice(1));
    } else if (line.startsWith(" ")) {
      flushChanges();
      rows.push({ kind: "context", oldText: line.slice(1), newText: line.slice(1) });
    } else if (line.length > 0) {
      flushChanges();
      rows.push({ kind: "context", oldText: line, newText: line });
    }
  }

  flushChanges();
  return rows;
}

export function writeDiff(content: string, path: string): string {
  const lines = content.split("\n");
  return [
    "--- /dev/null",
    `+++ ${path}`,
    "@@",
    ...lines.map((line) => `+${line}`),
  ].join("\n");
}

function changedTokenIndexes(source: string, other: string): Set<number> {
  const sourceTokens = source.match(TOKEN_PATTERN) ?? [];
  const otherTokens = other.match(TOKEN_PATTERN) ?? [];
  const lengths = Array.from({ length: sourceTokens.length + 1 }, () =>
    Array<number>(otherTokens.length + 1).fill(0),
  );

  for (let sourceIndex = sourceTokens.length - 1; sourceIndex >= 0; sourceIndex -= 1) {
    for (let otherIndex = otherTokens.length - 1; otherIndex >= 0; otherIndex -= 1) {
      lengths[sourceIndex]![otherIndex] = sourceTokens[sourceIndex] === otherTokens[otherIndex]
        ? lengths[sourceIndex + 1]![otherIndex + 1]! + 1
        : Math.max(lengths[sourceIndex + 1]![otherIndex]!, lengths[sourceIndex]![otherIndex + 1]!);
    }
  }

  const changed = new Set<number>();
  let sourceIndex = 0;
  let otherIndex = 0;
  while (sourceIndex < sourceTokens.length) {
    if (otherIndex < otherTokens.length && sourceTokens[sourceIndex] === otherTokens[otherIndex]) {
      sourceIndex += 1;
      otherIndex += 1;
      continue;
    }
    changed.add(sourceIndex);
    if (otherIndex >= otherTokens.length || lengths[sourceIndex + 1]![otherIndex]! >= lengths[sourceIndex]![otherIndex + 1]!) {
      sourceIndex += 1;
    } else {
      otherIndex += 1;
    }
  }
  return changed;
}

function highlightLine(line: string, language: string | undefined): string {
  return highlightCode(line, language)[0] ?? line;
}

function highlightWords(line: string, other: string, language: string | undefined, theme: ThemeLike): string {
  const tokens = line.match(TOKEN_PATTERN) ?? [line];
  const changed = changedTokenIndexes(line, other);
  let tokenIndex = 0;
  return tokens
    .map((token) => {
      const highlighted = highlightLine(token, language);
      const emphasized = changed.has(tokenIndex) && token.trim().length > 0
        ? theme.bold(highlighted)
        : highlighted;
      tokenIndex += 1;
      return emphasized;
    })
    .join("");
}

function renderCode(line: string, other: string | undefined, language: string | undefined, theme: ThemeLike): string {
  if (other === undefined || line === other) return highlightLine(line, language);
  return highlightWords(line, other, language, theme);
}

export function renderReadLines(text: string, path: string, theme: ThemeLike): string {
  const lines = text.split("\n");
  const numberWidth = String(lines.length).length;
  const language = getLanguageFromPath(path);
  return lines
    .map((line, index) => `${theme.fg("dim", String(index + 1).padStart(numberWidth, " "))} ${highlightLine(line, language)}`)
    .join("\n");
}

export function renderListEntries(text: string, theme: ThemeLike): string {
  return text
    .split("\n")
    .map((line) => {
      if (line.endsWith("/")) return `${theme.fg("accent", "󰉋")} ${theme.fg("toolOutput", line)}`;
      if (line.startsWith("[")) return theme.fg("warning", line);
      return `${theme.fg("muted", "󰈔")} ${theme.fg("toolOutput", line)}`;
    })
    .join("\n");
}

export class DiffView implements Component {
  constructor(
    private readonly diff: string,
    private readonly path: string,
    private readonly split: boolean,
    private readonly theme: ThemeLike,
  ) {}

  render(width: number): string[] {
    const language = getLanguageFromPath(this.path);
    const rows = parseDiffRows(this.diff);
    if (!this.split) return rows.flatMap((row) => this.renderUnified(row, width, language));

    const separator = this.theme.fg("toolDiffContext", " │ ");
    const available = Math.max(2, width - 3);
    const leftWidth = Math.max(1, Math.floor(available / 2));
    const rightWidth = Math.max(1, available - leftWidth);
    return rows.map((row) => {
      if (row.kind === "header") return truncateToWidth(this.theme.fg("muted", row.text ?? ""), width);
      const oldText = row.oldText ?? "";
      const newText = row.newText ?? "";
      const oldStyled = oldText
        ? renderCode(oldText, newText, language, this.theme)
        : this.theme.fg("dim", "");
      const newStyled = newText
        ? renderCode(newText, oldText, language, this.theme)
        : this.theme.fg("dim", "");
      const oldPrefix = row.kind === "change" && oldText ? this.theme.fg("toolDiffRemoved", "− ") : "  ";
      const newPrefix = row.kind === "change" && newText ? this.theme.fg("toolDiffAdded", "+ ") : "  ";
      return `${truncateToWidth(oldPrefix + oldStyled, leftWidth)}${separator}${truncateToWidth(newPrefix + newStyled, rightWidth)}`;
    });
  }

  invalidate(): void {}

  private renderUnified(row: DiffRow, width: number, language: string | undefined): string[] {
    if (row.kind === "header") return [truncateToWidth(this.theme.fg("muted", row.text ?? ""), width)];
    if (row.kind === "context") {
      return [truncateToWidth(`  ${renderCode(row.oldText ?? "", row.newText, language, this.theme)}`, width)];
    }
    const lines: string[] = [];
    if (row.oldText !== undefined) {
      lines.push(truncateToWidth(`${this.theme.fg("toolDiffRemoved", "− ")}${renderCode(row.oldText, row.newText, language, this.theme)}`, width));
    }
    if (row.newText !== undefined) {
      lines.push(truncateToWidth(`${this.theme.fg("toolDiffAdded", "+ ")}${renderCode(row.newText, row.oldText, language, this.theme)}`, width));
    }
    return lines;
  }
}
