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
        },
        setWorkingIndicator: () => undefined,
      },
    });

    expect(tools.map((tool) => tool.name)).toEqual(["read", "bash", "edit", "write", "ls", "find", "grep"]);
    expect(new Set(tools.map((tool) => tool.name)).size).toBe(tools.length);
    expect(markdownTransformers[0]?.("hello", { messageType: "user" })).toContain("userMessageBg");
    expect(markdownTransformers[0]?.("hello", { messageType: "assistant" })).toContain("customMessageBg");
    expect(markdownTransformers[0]?.("hello", { messageType: "user" })).not.toMatch(/USER|AGENT/);
  });
});
