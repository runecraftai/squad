import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import extension from "../src/index.js";

describe("extension registration", () => {
  it("overrides only Pi built-in tools and registers no conflicting names", () => {
    const tools: Array<{ name: string }> = [];
    const markdownTransformers: Array<(markdown: string, context: { messageType: string }) => string> = [];
    const pi = {
      on: () => undefined,
      registerMarkdownTransformer: (transformer: typeof markdownTransformers[number]) => markdownTransformers.push(transformer),
      registerTool: (tool: { name: string }) => tools.push(tool),
    } as unknown as ExtensionAPI;

    extension(pi);

    expect(tools.map((tool) => tool.name)).toEqual(["read", "bash", "edit", "write", "ls", "find", "grep"]);
    expect(new Set(tools.map((tool) => tool.name)).size).toBe(tools.length);
    expect(markdownTransformers[0]?.("hello", { messageType: "user" })).toContain("USER");
    expect(markdownTransformers[0]?.("hello", { messageType: "assistant" })).toContain("AGENT");
  });
});
