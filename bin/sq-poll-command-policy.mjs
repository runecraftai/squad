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

function wordsFor(node) {
  return commandPosition(node).words.map((word) => String(word.value ?? ""));
}

function effectiveCommand(words) {
  const first = basename(words[0] ?? "");
  if (CONTROL_PREFIXES.has(first)) return basename(words[1] ?? "");
  return first;
}

function hasStatePath(words) {
  return words.some((word) => /(?:^|\/|[A-Za-z0-9_$.-]+\/)state\//.test(word));
}

function nodeHasStateRead(node) {
  const words = wordsFor(node);
  if (!hasStatePath(words)) return false;
  const command = effectiveCommand(words);
  if (READ_COMMANDS.has(command)) return true;
  return words.some((word, index) =>
    ["-d", "-e", "-f", "-r", "-s"].includes(word) && hasStatePath(words.slice(index + 1)),
  );
}

function hasSleepConstruct(nodes) {
  return nodes.some((node) => {
    const words = wordsFor(node);
    const command = effectiveCommand(words);
    return command === "sleep";
  });
}

function hasWhileConstruct(nodes) {
  return nodes.some((node) => wordsFor(node)[0] === "while");
}

function shellPayload(words) {
  for (let index = 1; index < words.length; index += 1) {
    const value = words[index];
    if (value === "--") continue;
    if (value === "-c" || /^-[^-]*c[^-]*$/.test(value)) return words[index + 1] ?? "";
  }
  return "";
}

function analyze(command, depth = 0) {
  if (depth > MAX_DEPTH || !String(command ?? "").trim()) return { loop: false, stateRead: false };
  const lexed = new Lexer(String(command)).tokenize();
  if (lexed.error) return { loop: false, stateRead: false };
  const { nodes } = splitProgram(lexed.tokens);
  const result = {
    loop: hasSleepConstruct(nodes) || hasWhileConstruct(nodes),
    stateRead: nodes.some(nodeHasStateRead),
  };
  for (const node of nodes) {
    const position = commandPosition(node);
    const words = position.words.map((word) => String(word.value ?? ""));
    const nested = [];
    if (SHELLS.has(basename(words[0] ?? ""))) nested.push(shellPayload(words));
    for (const token of node) {
      for (const substitution of token.subs ?? []) nested.push(substitution.content);
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
