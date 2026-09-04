import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  Lexer,
  commandPosition,
  splitProgram,
} from "./sq-arm-command-policy.mjs";

// Keep this literal synchronized with SQUAD_BACKEND_KNOWN in bin/sq-backend.sh;
// the contract test catches drift without sourcing that side-effectful library.
export const SQUAD_BACKEND_KNOWN = new Set(["tmux", "herdr", "zellij", "orca", "cmux"]);

const SHELLS = new Set(["sh", "bash", "dash", "zsh", "ksh", "fish"]);
const RESERVED_COMMAND_PREFIXES = new Set(["!", "coproc", "elif", "else", "if", "then", "time", "until", "while"]);
const MAX_DEPTH = 8;

function basename(value) {
  const parts = String(value).split("/");
  return parts[parts.length - 1] || "";
}

function literalValue(token) {
  return token?.type === "word" ? String(token.value ?? "") : "";
}

function shellPayload(words, commandIndex) {
  for (let index = commandIndex + 1; index < words.length; index += 1) {
    const value = literalValue(words[index]);
    if (value === "--") continue;
    if (value === "-c" || /^-[^-]*c[^-]*$/.test(value)) {
      return literalValue(words[index + 1]);
    }
  }
  return "";
}

function shellStdinPayloads(node, position) {
  const commandName = basename(String(position.command?.value ?? ""));
  if (!SHELLS.has(commandName)) return [];
  const words = position.words;
  for (let index = (position.index ?? 0) + 1; index < words.length; index += 1) {
    const value = literalValue(words[index]);
    if (value === "--" || !value.startsWith("-")) return [];
    if (value === "-c" || /^-[^-]*c[^-]*$/.test(value)) return [];
  }
  return node
    .filter((token) => token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string")
    .map((token) => token.heredoc);
}

function reservedCommand(node) {
  const first = node.findIndex((token) => token.type === "word");
  if (first === -1 || !RESERVED_COMMAND_PREFIXES.has(literalValue(node[first]))) return [];
  let start = first + 1;
  if (literalValue(node[first]) === "time" && literalValue(node[start]) === "-p") start += 1;
  return node.slice(start);
}

function nodeHasBackend(node, depth) {
  const position = commandPosition(node);
  if (position?.command && SQUAD_BACKEND_KNOWN.has(basename(position.command.value))) return true;

  const words = position?.words ?? [];
  const commandIndex = position?.index ?? 0;
  const commandName = basename(String(position?.command?.value ?? ""));
  if (SHELLS.has(commandName)) {
    const payload = shellPayload(words, commandIndex);
    if (payload && containsRawBackend(payload, depth + 1)) return true;
  }
  if (commandName === "eval") {
    const payload = words.slice(commandIndex + 1).map(literalValue).filter(Boolean).join(" ");
    if (payload && containsRawBackend(payload, depth + 1)) return true;
  }
  const reserved = reservedCommand(node);
  if (reserved.length > 0 && nodeHasBackend(reserved, depth + 1)) return true;
  for (const token of node) {
    if (token.type === "group" && containsRawBackend(token.content, depth + 1)) return true;
    for (const substitution of token.subs ?? []) {
      if (containsRawBackend(substitution.content, depth + 1)) return true;
    }
  }
  for (const payload of position?.wrapperPayloads ?? []) {
    if (containsRawBackend(payload, depth + 1)) return true;
  }
  for (const payload of shellStdinPayloads(node, position)) {
    if (containsRawBackend(payload, depth + 1)) return true;
  }
  return false;
}

function containsRawBackend(command, depth = 0) {
  if (depth > MAX_DEPTH || !String(command).trim()) return false;
  const lexed = new Lexer(String(command)).tokenize();
  if (lexed.error) return false;
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    if (nodeHasBackend(node, depth)) return true;
  }
  return false;
}

function deny() {
  return {
    decision: "deny",
    code: "backend-raw-session-control",
    reason:
      "Direct session-provider CLI control is blocked. Use the Squad lifecycle wrappers " +
      "(for example bin/sq-send.sh, bin/sq-spawn.sh, bin/sq-teardown.sh, or bin/sq-window-state.sh).",
  };
}

export function decision(command) {
  if (!String(command ?? "").trim() || !containsRawBackend(command)) return { decision: "allow" };
  return deny();
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
    if (index === -1 || index + 1 >= process.argv.length) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(process.argv[index + 1]);
      if (result.decision === "allow") process.stdout.write("allow\n");
      else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
