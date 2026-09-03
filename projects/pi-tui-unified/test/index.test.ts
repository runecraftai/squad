import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import extension from "../src/index.js";

describe("extension registration", () => {
  it("overrides only Pi built-in tools and uses background-only message distinction", () => {
    const tools: Array<{ name: string }> = [];
    const markdownTransformers: Array<(markdown: string, context: { messageType: string }) => string> = [];
    let sessionStart: ((event: unknown, context: unknown) => void) | undefined;
    const pi = {
      on: (_event: string, handler: (event: unknown, context: unknown) => void) => {
        sessionStart = handler;
      },
      registerMarkdownTransformer: (transformer: typeof markdownTransformers[number]) => markdownTransformers.push(transformer),
      registerTool: (tool: { name: string }) => tools.push(tool),
    } as unknown as ExtensionAPI;

    extension(pi);
    sessionStart?.({}, {
      ui: {
        theme: {
          fg: (_color: string, text: string) => text,
          bg: (color: string, text: string) => `<${color}>${text}</${color}>`,
          getFgAnsi: (color: string) => color === "success" ? "\x1b[38;2;30;200;100m" : "\x1b[38;2;20;180;190m",
          getBgAnsi: () => "\x1b[48;2;30;30;30m",
          getColorMode: () => "truecolor",
        },
        setWorkingIndicator: () => undefined,
      },
    });

    expect(tools.map((tool) => tool.name)).toEqual(["read", "bash", "edit", "write", "ls", "find", "grep"]);
    expect(new Set(tools.map((tool) => tool.name)).size).toBe(tools.length);
    const user = markdownTransformers[0]?.("hello", { messageType: "user" }) ?? "";
    const agent = markdownTransformers[0]?.("hello", { messageType: "assistant" }) ?? "";
    const thinking = markdownTransformers[0]?.("hello", { messageType: "assistant-thinking" }) ?? "";
    expect(user).toMatch(/\x1b\[48;2;/);
    expect(agent).toMatch(/\x1b\[48;2;/);
    expect(agent).not.toBe(user);
    expect(thinking).not.toBe(agent);
    expect(user).not.toMatch(/USER|AGENT/);
  });
});
