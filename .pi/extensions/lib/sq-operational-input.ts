import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const operationalInputScript =
  process.env.SQUAD_OPERATIONAL_INPUT_SCRIPT ||
  resolve(dirname(fileURLToPath(import.meta.url)), "../../../bin/sq-operational-input.sh");

export const SQUAD_CURRENT_OPERATIONAL_KINDS = [
  "session-start",
  "sentry",
  "turn-end-guard",
  "away-supervisor",
  "from-squad",
  "launch-brief",
  "handoff-request",
] as const;

export type SquadCurrentOperationalKind =
  (typeof SQUAD_CURRENT_OPERATIONAL_KINDS)[number];

function runOperationalInputCommand(
  command: "encode" | "classify" | "kind",
  content: string,
  kind?: SquadCurrentOperationalKind,
): string | undefined {
  const args = command === "encode" ? [command, kind ?? ""] : [command];
  const result = spawnSync(operationalInputScript, args, {
    encoding: "utf8",
    input: content,
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) return undefined;
  return command === "classify" ? result.stdout.replace(/\n$/, "") : result.stdout;
}

export function encodeSquadOperationalInput(
  kind: SquadCurrentOperationalKind,
  content: string,
): string {
  const encoded = runOperationalInputCommand("encode", content, kind);
  if (encoded === undefined) {
    throw new Error(`could not encode Squad operational input kind ${kind}`);
  }
  return encoded;
}

export function classifySquadOperationalText(content: string): string | undefined {
  return runOperationalInputCommand("classify", content);
}

export function classifySquadCurrentOperationalText(
  content: string,
): string | undefined {
  return runOperationalInputCommand("kind", content);
}
