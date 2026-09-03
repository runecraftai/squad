import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import extension from "../src/index.js";

describe("extension registration", () => {
  it("wraps the composer without replacing built-in Markdown rendering", () => {
    const tools: Array<{ name: string }> = [];
    let sessionStart: ((event: unknown, context: unknown) => void) | undefined;
    let editorFactory: unknown;
    const pi = {
      on: (_event: string, handler: (event: unknown, context: unknown) => void) => {
        sessionStart = handler;
      },
      registerTool: (tool: { name: string }) => tools.push(tool),
    } as unknown as ExtensionAPI;

    extension(pi);
    sessionStart?.({}, {
      ui: {
        getEditorComponent: () => undefined,
        setEditorComponent: (factory: unknown) => {
          editorFactory = factory;
        },
        theme: {
          fg: (_color: string, text: string) => text,
          bg: (_color: string, text: string) => text,
        },
        setWorkingIndicator: () => undefined,
      },
    });

    expect(tools.map((tool) => tool.name)).toEqual(["read", "bash", "edit", "write", "ls", "find", "grep"]);
    expect(new Set(tools.map((tool) => tool.name)).size).toBe(tools.length);
    expect(editorFactory).toBeTypeOf("function");
  });
});
