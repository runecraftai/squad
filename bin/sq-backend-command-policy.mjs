import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  Lexer,
  commandPosition,
  splitProgram,
} from "./sq-arm-command-policy.mjs";

// Keep this literal synchronized with SQUAD_BACKEND_KNOWN in bin/sq-backend.sh.
export const SQUAD_BACKEND_KNOWN = new Set(["tmux", "herdr", "zellij", "orca", "cmux", "tuios"]);

// The guard's registry of the one Squad surface that reaches session-provider
// grant state on purpose. It is named here so every refusal tells the operator
// the sanctioned pane-grant path instead of leaving the provider's own raw
// advice as the only answer. It is deliberately NOT a backend CLI name, so the
// raw-control rule never matches its command word: this registry publishes a
// replacement, it opens no CLI access of its own.
export const SANCTIONED_PANE_GRANT_SURFACE = "bin/sq-pane-grants.sh";

const SHELLS = new Set(["sh", "bash", "dash", "zsh", "ksh", "fish"]);
const MAX_DEPTH = 8;

function basename(value) {
  const parts = String(value).split("/");
  return parts[parts.length - 1] || "";
}

function literalValue(token) {
  return token?.type === "word" ? String(token.value ?? "") : "";
}

function shellPayload(position) {
  const words = position?.words ?? [];
  for (let index = (position?.index ?? 0) + 1; index < words.length; index += 1) {
    const value = literalValue(words[index]);
    if (value === "--") continue;
    if (value === "-c" || /^-[^-]*c[^-]*$/.test(value)) {
      return literalValue(words[index + 1]);
    }
  }
  return "";
}

function nodeHasBackend(node, depth) {
  const position = commandPosition(node);
  if (position?.command && SQUAD_BACKEND_KNOWN.has(basename(position.command.value))) return true;

  const commandName = basename(literalValue(position?.command));
  if (SHELLS.has(commandName)) {
    const payload = shellPayload(position);
    if (payload && containsRawBackend(payload, depth + 1)) return true;
  }
  if (commandName === "eval") {
    const payload = (position?.words ?? []).slice((position?.index ?? 0) + 1).map(literalValue).filter(Boolean).join(" ");
    if (payload && containsRawBackend(payload, depth + 1)) return true;
  }

  for (const token of node) {
    for (const content of [token.content, ...(token.subs ?? []).map((substitution) => substitution.content)]) {
      if (content && containsRawBackend(content, depth + 1)) return true;
    }
  }
  for (const payload of position?.wrapperPayloads ?? []) {
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

// Both provider grant verbs match on the whole word, and the leading class keeps
// the read verb from matching inside the write verb's name.
const RAW_GRANT_WRITE = /(?:^|[^-A-Za-z0-9_])set-pane-grants(?![A-Za-z0-9_-])/;
const RAW_GRANT_READ = /(?:^|[^-A-Za-z0-9_])pane-grants(?![A-Za-z0-9_-])/;

function deny(command) {
  let reason =
    "Direct session-provider CLI control is blocked. Use the Squad lifecycle wrappers " +
    "(for example bin/sq-send.sh, bin/sq-spawn.sh, bin/sq-teardown.sh, or bin/sq-window-state.sh).";
  // Only the providers' grant verbs have a sanctioned replacement, so the other
  // backends' refusals stay free of advice about a verb they do not have. Each
  // verb points at its own wrapper subcommand: a caller that only wanted to read
  // grants must not be told to perform the one write the wrapper allows.
  const text = String(command);
  if (RAW_GRANT_WRITE.test(text)) {
    reason += ` Pane grants go through ${SANCTIONED_PANE_GRANT_SURFACE} grant respond <target>, never the CLI's own set-pane-grants.`;
  } else if (RAW_GRANT_READ.test(text)) {
    reason += ` Reading pane grants goes through ${SANCTIONED_PANE_GRANT_SURFACE} show [<target>], never the CLI's own pane-grants.`;
  }
  return { decision: "deny", code: "backend-raw-session-control", reason };
}

export function decision(command) {
  if (!String(command ?? "").trim() || !containsRawBackend(command)) return { decision: "allow" };
  return deny(command);
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
