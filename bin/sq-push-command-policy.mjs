#!/usr/bin/env node
// Classify shell commands that invoke `git push`.
//
// The shared shell lexer keeps quoted data and command position separate, so a
// mention such as `echo "git push"` cannot trigger the delivery guard.

import { Lexer, splitProgram, commandPosition } from "./sq-arm-command-policy.mjs";

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function isGitPush(tokens) {
  const position = commandPosition(tokens);
  if (!position.command || basename(position.command.value) !== "git") return false;

  const words = position.words;
  let index = position.index + 1;
  while (index < words.length) {
    const value = words[index].value;
    if (value === "--") return false;
    if (value === "-C" || value === "--git-dir" || value === "--work-tree" || value === "--namespace" || value === "-c") {
      index += 2;
      continue;
    }
    if (value.startsWith("-C") && value.length > 2) {
      index += 1;
      continue;
    }
    if (value.startsWith("--git-dir=") || value.startsWith("--work-tree=") || value.startsWith("--namespace=") || value.startsWith("-c")) {
      index += 1;
      continue;
    }
    return value === "push";
  }
  return false;
}

function nestedShellCommands(position) {
  if (!position.command) return [];
  const name = basename(position.command.value);
  if (!['sh', 'bash', 'dash', 'zsh', 'ksh', 'fish'].includes(name)) return [];

  const words = position.words;
  for (let index = position.index + 1; index < words.length; index += 1) {
    const value = words[index].value;
    if (value === '--') {
      const payload = words[index + 1];
      return payload?.literal && payload.subs.length === 0 ? [payload.value] : [];
    }
    if (value === '-c' || /^-[A-Za-z]*c$/.test(value)) {
      const payload = words[index + 1];
      return payload?.literal && payload.subs.length === 0 ? [payload.value] : [];
    }
    if (/^-c.+/.test(value)) return [value.slice(2)];
  }
  return [];
}

export function commandHasGitPush(command, depth = 0) {
  if (depth > 12) return false;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return false;

  for (const tokens of splitProgram(lexed.tokens).nodes) {
    if (isGitPush(tokens)) return true;
    const position = commandPosition(tokens);
    for (const payload of nestedShellCommands(position)) {
      if (commandHasGitPush(payload, depth + 1)) return true;
    }
    for (const token of tokens) {
      if (token.type === 'group' && commandHasGitPush(token.content, depth + 1)) return true;
      if (token.type !== 'word') continue;
      for (const substitution of token.subs) {
        if (commandHasGitPush(substitution.content, depth + 1)) return true;
      }
    }
  }
  return false;
}

if (process.argv[1] && process.argv[1].endsWith("sq-push-command-policy.mjs")) {
  const command = process.argv.slice(2).join(" ");
  process.stdout.write(commandHasGitPush(command) ? "push\n" : "allow\n");
}
