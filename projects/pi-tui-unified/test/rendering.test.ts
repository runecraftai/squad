import { visibleWidth } from "@earendil-works/pi-tui";
import { describe, expect, it } from "vitest";
import {
  DiffView,
  parseDiffRows,
  renderListEntries,
  renderReadLines,
  tintMarkdown,
  writeDiff,
  type ThemeLike,
} from "../src/rendering.js";

const theme: ThemeLike = {
  fg: (color, text) => `<${color}>${text}</${color}>`,
  bg: (_color, text) => text,
  bold: (text) => `<bold>${text}</bold>`,
};

describe("pi-tui-unified rendering", () => {
  it("pairs edits for split rendering", () => {
    expect(parseDiffRows("@@\n-old\n+new")).toEqual([
      { kind: "header", text: "@@" },
      { kind: "change", oldText: "old", newText: "new" },
    ]);
  });

  it("creates a unified diff for writes", () => {
    expect(writeDiff("one\ntwo", "src/file.ts")).toBe(
      "--- /dev/null\n+++ src/file.ts\n@@\n+one\n+two",
    );
  });

  it("tints message content without changing Markdown markers", () => {
    const rendered = tintMarkdown("# Heading\n\n- item\n\n```ts\nconst x = 1;\n```", (text) => `[bg]${text}[/bg]`);
    expect(rendered).toContain("# [bg]Heading[/bg]");
    expect(rendered).toContain("- [bg]item[/bg]");
    expect(rendered).toContain("const x = 1;");
    expect(rendered).not.toMatch(/USER|AGENT/);
  });

  it("adds line numbers and preserves syntax output", () => {
    const rendered = renderReadLines("const value = 1;\nreturn value;", "file.ts", theme);
    expect(rendered).toContain("<dim>1</dim>");
    expect(rendered).toContain("<dim>2</dim>");
    expect(rendered).toContain("const value = 1;");
  });

  it("uses separate theme tokens for files and directories", () => {
    const rendered = renderListEntries("src/\nREADME.md", theme);
    expect(rendered).toContain("<accent>󰉋</accent>");
    expect(rendered).toContain("<muted>󰈔</muted>");
  });

  it("renders edit diffs side by side", () => {
    const lines = new DiffView("@@\n-old value\n+new value", "file.ts", true, theme).render(50);
    expect(lines.some((line) => line.includes("−") && line.includes("+") && line.includes("│"))).toBe(true);
  });

  it("renders writes as unified additions", () => {
    const lines = new DiffView(writeDiff("const x = 1;", "file.ts"), "file.ts", false, theme).render(50);
    expect(lines.some((line) => line.includes("+ ") && line.includes("const x = 1;"))).toBe(true);
  });

  it("keeps split rows within the requested terminal width", () => {
    const lines = new DiffView("@@\n-old line that is much too long for the viewport\n+new line that is much too long for the viewport", "file.ts", true, theme).render(24);
    expect(lines.every((line) => visibleWidth(line.replace(/<\/?[^>]+>/g, "")) <= 24)).toBe(true);
  });
});
