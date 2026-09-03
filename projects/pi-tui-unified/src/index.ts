import type {
  BashToolDetails,
  EditToolDetails,
  ExtensionAPI,
  LsToolDetails,
  ReadToolDetails,
  Theme,
} from "@earendil-works/pi-coding-agent";
import {
  createBashTool,
  createEditTool,
  createFindTool,
  createGrepTool,
  createLsTool,
  createReadTool,
  createWriteTool,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import {
  DiffView,
  renderListEntries,
  renderReadLines,
  textContent,
  tintMarkdown,
  writeDiff,
} from "./rendering.js";

function resultText(result: { content: readonly { type: string; text?: string }[] }): string {
  return textContent(result.content);
}

function statusText(isError: boolean, theme: Theme): string {
  return isError ? theme.fg("error", "✗ error") : theme.fg("success", "✓ done");
}

type Rgb = [number, number, number];

function ansiRgb(ansi: string, background: boolean): Rgb | undefined {
  const kind = background ? 48 : 38;
  const trueColor = ansi.match(new RegExp(`\\x1b\\[${kind};2;(\\d+);(\\d+);(\\d+)m`));
  if (trueColor) return [Number(trueColor[1]), Number(trueColor[2]), Number(trueColor[3])];
  const indexed = ansi.match(new RegExp(`\\x1b\\[${kind};5;(\\d+)m`));
  if (!indexed) return undefined;
  return ansi256Rgb(Number(indexed[1]));
}

function ansi256Rgb(index: number): Rgb {
  if (index < 16) {
    const palette: Rgb[] = [
      [0, 0, 0], [128, 0, 0], [0, 128, 0], [128, 128, 0],
      [0, 0, 128], [128, 0, 128], [0, 128, 128], [192, 192, 192],
      [128, 128, 128], [255, 0, 0], [0, 255, 0], [255, 255, 0],
      [0, 0, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255],
    ];
    return palette[index] ?? [0, 0, 0];
  }
  if (index >= 232) {
    const gray = 8 + (index - 232) * 10;
    return [gray, gray, gray];
  }
  const cube = index - 16;
  const channels = [Math.floor(cube / 36), Math.floor(cube / 6) % 6, cube % 6];
  return channels.map((channel) => channel === 0 ? 0 : 55 + channel * 40) as Rgb;
}

function rgb256([red, green, blue]: Rgb): number {
  const cube = (value: number) => value < 48 ? 0 : value < 114 ? 1 : Math.round((value - 55) / 40);
  const cubeRgb = (value: number) => value === 0 ? 0 : 55 + value * 40;
  const channels = [cube(red), cube(green), cube(blue)];
  const cubeIndex = 16 + channels[0]! * 36 + channels[1]! * 6 + channels[2]!;
  const cubeDistance = (cubeRgb(channels[0]!) - red) ** 2 + (cubeRgb(channels[1]!) - green) ** 2 + (cubeRgb(channels[2]!) - blue) ** 2;
  const gray = Math.round((red + green + blue) / 3);
  const grayIndex = Math.max(0, Math.min(23, Math.round((gray - 8) / 10)));
  const grayValue = 8 + grayIndex * 10;
  const grayDistance = (grayValue - red) ** 2 + (grayValue - green) ** 2 + (grayValue - blue) ** 2;
  return grayDistance < cubeDistance ? 232 + grayIndex : cubeIndex;
}

function tintedBackground(theme: Theme, foreground: "accent" | "success" | "thinkingText", base: "userMessageBg" | "toolPendingBg"): (text: string) => string {
  const tint = ansiRgb(theme.getFgAnsi(foreground), false);
  const background = ansiRgb(theme.getBgAnsi(base), true);
  if (!tint || !background) return (text) => theme.bg(base, text);
  const mixed: Rgb = background.map((value, index) => Math.round(value * 0.72 + tint[index]! * 0.28)) as Rgb;
  const ansi = theme.getColorMode() === "truecolor"
    ? `\x1b[48;2;${mixed[0]};${mixed[1]};${mixed[2]}m`
    : `\x1b[48;5;${rgb256(mixed)}m`;
  return (text) => `${ansi}${text}\x1b[49m`;
}

export default function piTuiUnified(pi: ExtensionAPI): void {
  let userMessageBackground = (text: string) => text;
  let agentMessageBackground = (text: string) => text;
  let thinkingMessageBackground = (text: string) => text;

  pi.on("session_start", (_event, ctx) => {
    userMessageBackground = tintedBackground(ctx.ui.theme, "accent", "userMessageBg");
    agentMessageBackground = tintedBackground(ctx.ui.theme, "success", "userMessageBg");
    thinkingMessageBackground = tintedBackground(ctx.ui.theme, "thinkingText", "toolPendingBg");
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

  pi.registerMarkdownTransformer((markdown, { messageType }) => {
    if (messageType === "user") return tintMarkdown(markdown, userMessageBackground);
    if (messageType === "assistant") return tintMarkdown(markdown, agentMessageBackground);
    if (messageType === "assistant-thinking") return tintMarkdown(markdown, thinkingMessageBackground);
    return markdown;
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
