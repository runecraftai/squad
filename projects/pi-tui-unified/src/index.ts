import type {
  BashToolDetails,
  EditToolDetails,
  ExtensionAPI,
  KeybindingsManager,
  LsToolDetails,
  ReadToolDetails,
  Theme,
} from "@earendil-works/pi-coding-agent";
import {
  CustomEditor,
  createBashTool,
  createEditTool,
  createFindTool,
  createGrepTool,
  createLsTool,
  createReadTool,
  createWriteTool,
} from "@earendil-works/pi-coding-agent";
import { Text, type EditorTheme, type TUI, visibleWidth } from "@earendil-works/pi-tui";
import {
  DiffView,
  renderListEntries,
  renderReadLines,
  textContent,
  writeDiff,
} from "./rendering.js";

function resultText(result: { content: readonly { type: string; text?: string }[] }): string {
  return textContent(result.content);
}

function statusText(isError: boolean, theme: Theme): string {
  return isError ? theme.fg("error", "✗ error") : theme.fg("success", "✓ done");
}

class BackgroundEditor extends CustomEditor {
  constructor(
    tui: TUI,
    editorTheme: EditorTheme,
    keybindings: KeybindingsManager,
    private readonly appTheme: Theme,
  ) {
    super(tui, editorTheme, keybindings);
  }

  render(width: number): string[] {
    return super.render(width).map((line) => {
      const padding = " ".repeat(Math.max(0, width - visibleWidth(line)));
      return this.appTheme.bg("selectedBg", `${line}${padding}`);
    });
  }
}

export default function piTuiUnified(pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    const previousEditor = ctx.ui.getEditorComponent();
    ctx.ui.setEditorComponent((tui, editorTheme, keybindings) => {
      if (previousEditor) return previousEditor(tui, editorTheme, keybindings);
      return new BackgroundEditor(tui, editorTheme, keybindings, ctx.ui.theme);
    });
    ctx.ui.setWorkingIndicator({
      frames: [
        ctx.ui.theme.fg("dim", "·"),
        ctx.ui.theme.fg("muted", "•"),
        ctx.ui.theme.fg("accent", "●"),
        ctx.ui.theme.fg("muted", "•"),
      ],
      intervalMs: 120,
    });
  });

  const cwd = process.cwd();
  const originalRead = createReadTool(cwd);
  pi.registerTool({
    name: "read",
    label: originalRead.label,
    description: originalRead.description,
    parameters: originalRead.parameters,
    async execute(toolCallId, params, signal, onUpdate) {
      return originalRead.execute(toolCallId, params, signal, onUpdate);
    },
    renderCall(args, theme) {
      return new Text(`${theme.fg("toolTitle", theme.bold("read "))}${theme.fg("accent", args.path)}`, 0, 0);
    },
    renderResult(result, { isPartial }, theme, context) {
      if (isPartial) return new Text(theme.fg("warning", "Reading…"), 0, 0);
      if (context.isError) return new Text(`${statusText(true, theme)} ${theme.fg("error", resultText(result))}`, 0, 0);
      const details = result.details as ReadToolDetails | undefined;
      const suffix = details?.truncation?.truncated ? `\n${theme.fg("warning", "[truncated]")}` : "";
      return new Text(`${statusText(false, theme)}\n${renderReadLines(resultText(result), context.args.path, theme)}${suffix}`, 0, 0);
    },
  });

  const originalBash = createBashTool(cwd);
  pi.registerTool({
    name: "bash",
    label: originalBash.label,
    description: originalBash.description,
    parameters: originalBash.parameters,
    async execute(toolCallId, params, signal, onUpdate) {
      return originalBash.execute(toolCallId, params, signal, onUpdate);
    },
    renderCall(args, theme) {
      return new Text(`${theme.fg("toolTitle", theme.bold("$ "))}${theme.fg("accent", args.command)}`, 0, 0);
    },
    renderResult(result, { isPartial, expanded }, theme, context) {
      if (isPartial) return new Text(theme.fg("warning", "Running…"), 0, 0);
      const details = result.details as BashToolDetails | undefined;
      const output = resultText(result);
      let text = statusText(context.isError, theme);
      if (details?.truncation?.truncated) text += ` ${theme.fg("warning", "[truncated]")}`;
      if (output) {
        const lines = expanded ? output.split("\n") : output.split("\n").slice(0, 5);
        const outputColor = context.isError ? "error" : "toolOutput";
        text += `\n${lines.map((line) => theme.fg(outputColor, line)).join("\n")}`;
        if (!expanded && output.split("\n").length > lines.length) text += `\n${theme.fg("muted", "… expand for more output")}`;
      }
      return new Text(text, 0, 0);
    },
  });

  const originalEdit = createEditTool(cwd);
  pi.registerTool({
    name: "edit",
    label: originalEdit.label,
    description: originalEdit.description,
    parameters: originalEdit.parameters,
    async execute(toolCallId, params, signal, onUpdate) {
      return originalEdit.execute(toolCallId, params, signal, onUpdate);
    },
    renderCall(args, theme) {
      return new Text(`${theme.fg("toolTitle", theme.bold("edit "))}${theme.fg("accent", args.path)}`, 0, 0);
    },
    renderResult(result, { isPartial }, theme, context) {
      if (isPartial) return new Text(theme.fg("warning", "Editing…"), 0, 0);
      if (context.isError) return new Text(`${statusText(true, theme)} ${theme.fg("error", resultText(result))}`, 0, 0);
      const details = result.details as EditToolDetails | undefined;
      if (!details?.diff) return new Text(statusText(false, theme), 0, 0);
      return new DiffView(details.diff, context.args.path, true, theme);
    },
  });

  const originalWrite = createWriteTool(cwd);
  pi.registerTool({
    name: "write",
    label: originalWrite.label,
    description: originalWrite.description,
    parameters: originalWrite.parameters,
    async execute(toolCallId, params, signal, onUpdate) {
      return originalWrite.execute(toolCallId, params, signal, onUpdate);
    },
    renderCall(args, theme) {
      return new Text(`${theme.fg("toolTitle", theme.bold("write "))}${theme.fg("accent", args.path)}`, 0, 0);
    },
    renderResult(result, { isPartial }, theme, context) {
      if (isPartial) return new Text(theme.fg("warning", "Writing…"), 0, 0);
      if (context.isError) return new Text(`${statusText(true, theme)} ${theme.fg("error", resultText(result))}`, 0, 0);
      return new DiffView(writeDiff(context.args.content, context.args.path), context.args.path, false, theme);
    },
  });

  const originalLs = createLsTool(cwd);
  pi.registerTool({
    name: "ls",
    label: originalLs.label,
    description: originalLs.description,
    parameters: originalLs.parameters,
    async execute(toolCallId, params, signal, onUpdate) {
      return originalLs.execute(toolCallId, params, signal, onUpdate);
    },
    renderCall(args, theme) {
      return new Text(`${theme.fg("toolTitle", theme.bold("ls "))}${theme.fg("accent", args.path ?? ".")}`, 0, 0);
    },
    renderResult(result, { isPartial }, theme, context) {
      if (isPartial) return new Text(theme.fg("warning", "Listing…"), 0, 0);
      if (context.isError) return new Text(`${statusText(true, theme)} ${theme.fg("error", resultText(result))}`, 0, 0);
      const details = result.details as LsToolDetails | undefined;
      const suffix = details?.entryLimitReached || details?.truncation?.truncated ? `\n${theme.fg("warning", "[truncated]")}` : "";
      return new Text(`${statusText(false, theme)}\n${renderListEntries(resultText(result), theme)}${suffix}`, 0, 0);
    },
  });

  for (const [name, factory] of [["find", createFindTool], ["grep", createGrepTool]] as const) {
    const original = factory(cwd);
    pi.registerTool({
      name,
      label: original.label,
      description: original.description,
      parameters: original.parameters,
      async execute(toolCallId, params, signal, onUpdate) {
        return original.execute(toolCallId, params, signal, onUpdate);
      },
      renderCall(args, theme) {
        return new Text(`${theme.fg("toolTitle", theme.bold(`${name} `))}${theme.fg("accent", JSON.stringify(args))}`, 0, 0);
      },
      renderResult(result, { isPartial, expanded }, theme, context) {
        if (isPartial) return new Text(theme.fg("warning", `${name === "find" ? "Finding" : "Searching"}…`), 0, 0);
        if (context.isError) return new Text(`${statusText(true, theme)} ${theme.fg("error", resultText(result))}`, 0, 0);
        const output = resultText(result);
        const lines = expanded ? output : output.split("\n").slice(0, 20).join("\n");
        return new Text(`${statusText(false, theme)}${lines ? `\n${theme.fg("toolOutput", lines)}` : ""}`, 0, 0);
      },
    });
  }
}
