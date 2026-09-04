import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  Lexer,
  commandPosition,
  splitProgram,
} from "./sq-arm-command-policy.mjs";

const READ_COMMANDS = new Set([
  "[",
  "[[",
  "awk",
  "cat",
  "find",
  "grep",
  "head",
  "ls",
  "read",
  "rg",
  "sed",
  "stat",
  "tail",
  "test",
  "watch",
  "wc",
]);
const CONTROL_PREFIXES = new Set(["do", "elif", "else", "then", "until", "while"]);
const SHELLS = new Set(["sh", "bash", "dash", "zsh", "ksh", "fish"]);
const MAX_DEPTH = 8;

function basename(value) {
  const parts = String(value).split("/");
  return parts[parts.length - 1] || "";
}

function commandInfo(node) {
  const position = commandPosition(node);
  const words = position.words.map((word) => String(word.value ?? ""));
  let index = position.index;
  if (CONTROL_PREFIXES.has(basename(words[index] ?? ""))) index += 1;
  return {
    position,
    words,
    index,
    command: basename(words[index] ?? ""),
  };
}

function hasStatePath(words) {
  return words.some((word) => /(?:^|\/|[A-Za-z0-9_$.-]+\/)state\//.test(word));
}

function isStateDirectory(value) {
  return /(?:^|\/)state(?:\/|$)/.test(value);
}

function hasReadTarget(words, index) {
  return words.slice(index + 1).some((word) => word !== "--" && !word.startsWith("-"));
}

function nodeChangesToStateDirectory(info) {
  if (info.command !== "cd") return false;
  return info.words.slice(info.index + 1).some(isStateDirectory);
}

function nodeLeavesStateDirectory(info) {
  if (info.command !== "cd") return false;
  return info.words.slice(info.index + 1).some((word) => word === ".." || word === "../");
}

function nodeHasStateRead(info, stateCwd) {
  const explicitStatePath = hasStatePath(info.words);
  if (READ_COMMANDS.has(info.command) && (explicitStatePath || (stateCwd && hasReadTarget(info.words, info.index)))) return true;
  return info.words.slice(info.index + 1).some((word, index) =>
    ["-d", "-e", "-f", "-r", "-s"].includes(word) && hasStatePath(info.words.slice(info.index + 2 + index)),
  );
}

function shellPayload(position) {
  const words = position?.words ?? [];
  for (let index = (position?.index ?? 0) + 1; index < words.length; index += 1) {
    const value = String(words[index]?.value ?? "");
    if (value === "--") continue;
    if (value === "-c" || /^-[^-]*c[^-]*$/.test(value)) return String(words[index + 1]?.value ?? "");
  }
  return "";
}

function analyze(command, depth = 0) {
  if (depth > MAX_DEPTH || !String(command ?? "").trim()) return { loop: false, stateRead: false };
  const lexed = new Lexer(String(command)).tokenize();
  if (lexed.error) return { loop: false, stateRead: false };
  const { nodes } = splitProgram(lexed.tokens);
  const result = { loop: false, stateRead: false };
  let stateCwd = false;
  for (const node of nodes) {
    const info = commandInfo(node);
    result.loop ||= info.command === "sleep" || info.words[info.position.index] === "while";
    result.stateRead ||= nodeHasStateRead(info, stateCwd);
    if (nodeChangesToStateDirectory(info)) stateCwd = true;
    if (nodeLeavesStateDirectory(info)) stateCwd = false;

    const nested = [];
    if (SHELLS.has(info.command)) nested.push(shellPayload(info.position));
    for (const token of node) {
      for (const content of [token.content, ...(token.subs ?? []).map((substitution) => substitution.content)]) {
        if (content) nested.push(content);
      }
    }
    for (const payload of nested) {
      const child = analyze(payload, depth + 1);
      result.loop ||= child.loop;
      result.stateRead ||= child.stateRead;
    }
  }
  return result;
}

export function decision(command) {
  const analysis = analyze(command);
  if (!analysis.loop || !analysis.stateRead) return { decision: "allow" };
  return {
    decision: "deny",
    code: "state-poll-loop",
    reason:
      "Polling state/ in a shell loop is blocked. Use the Squad wake queue or " +
      "bin/sq-status-notify.sh watch instead of hand-polling state files.",
  };
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const index = process.argv.indexOf("--command");
    const result = decision(index === -1 ? "" : process.argv[index + 1] ?? "");
    if (result.decision === "allow") process.stdout.write("allow\n");
    else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
