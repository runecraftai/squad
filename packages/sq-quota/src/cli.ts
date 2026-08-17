import { runAxiCli } from "axi-sdk-js";
import {
  authCommand,
  modelsCommand,
  quotaCommand,
  type QuotaContext,
} from "./commands.js";
import { VERSION } from "./version.js";

export const DESCRIPTION =
  "Report local agent-provider quota windows and model quota evidence.";

export const TOP_HELP = `usage: sq-quota [quota|auth|models] [flags]
commands[3]:
  (none)=quota, auth, models
output:
  Default TOON reports local quota evidence. models is a deterministic data join; --sort runway is explicit opt-in ordering. --tui renders a live human terminal report instead (q quits).
  By default, only providers with local credentials are shown. Use --all-providers to show every known provider.
flags[12]:
  --provider <claude,codex,cursor,copilot,grok,kimi,opencode>, --json, --full, --tui, --refresh <30s-24h>, --once, --allow-keychain-prompt, --all-providers, --intelligence <high|medium|low>, --sort <runway>, --help, -v/--version
examples:
  sq-quota
  sq-quota --provider claude
  sq-quota --provider cursor,copilot,grok,kimi,opencode
  sq-quota --all-providers
  sq-quota --json
  sq-quota --full
  sq-quota --tui
  sq-quota --tui --refresh 1m
  sq-quota --tui --once
  sq-quota auth
  sq-quota models --intelligence high
  sq-quota models --sort runway
`;

type MainOptions = {
  argv?: string[];
  stdout?: { write: (chunk: string) => unknown };
  binPath?: string;
};

export async function main(options: MainOptions = {}): Promise<void> {
  const binPath = options.binPath ?? process.argv[1] ?? "sq-quota";
  const argv = normalizeArgv(options.argv ?? process.argv.slice(2));

  await runAxiCli<QuotaContext>({
    argv,
    description: DESCRIPTION,
    version: VERSION,
    topLevelHelp: TOP_HELP,
    ...(options.stdout ? { stdout: options.stdout } : {}),
    commands: {
      quota: quotaCommand,
      auth: authCommand,
      models: modelsCommand,
    },
    // `quota` is the implicit default command, so the bare-invocation home view
    // is never reached (see normalizeArgv); wiring it keeps the SDK contract.
    home: quotaCommand,
    resolveContext: () => ({ binPath }),
    getCommandHelp: (command) =>
      command === "quota" || command === "auth" || command === "models"
        ? TOP_HELP
        : undefined,
  });
}

/**
 * Route the flag-first default surface onto the `quota` command. `sq-quota`,
 * `sq-quota --json`, and `sq-quota --provider claude` all mean "run quota",
 * but runAxiCli routes on argv[0] and rejects a leading flag. Prefixing the
 * implicit `quota` command name preserves the historical surface while letting
 * the SDK own routing, help, version, and error framing.
 */
export function normalizeArgv(raw: string[]): string[] {
  if (raw.length === 0) return ["quota"];
  if (findLegacyFlag(raw, (arg) => arg === "--help" || arg === "-h") >= 0) {
    return ["--help"];
  }
  const versionIndex = findLegacyFlag(raw, isVersionFlag);
  if (versionIndex >= 0) {
    return [raw[versionIndex]];
  }
  const commandIndex = findCommand(raw);
  if (commandIndex > 0) {
    return [
      raw[commandIndex],
      ...raw.slice(0, commandIndex),
      ...raw.slice(commandIndex + 1),
    ];
  }
  const first = raw[0];
  if (raw.length === 1 && isTopLevelFlag(first)) {
    return raw;
  }
  if (
    first === "quota" ||
    first === "auth" ||
    first === "models" ||
    first === "update"
  ) {
    return raw;
  }
  if (first.startsWith("-")) {
    return ["quota", ...raw];
  }
  return raw;
}

function isTopLevelFlag(flag: string): boolean {
  return flag === "--help" || isVersionFlag(flag);
}

function isVersionFlag(flag: string): boolean {
  return flag === "-v" || flag === "-V" || flag === "--version";
}

function findLegacyFlag(
  raw: string[],
  predicate: (arg: string) => boolean,
): number {
  for (let index = 0; index < raw.length; index++) {
    const arg = raw[index];
    if (arg === "--provider") {
      index++;
      continue;
    }
    if (predicate(arg)) return index;
  }
  return -1;
}

function findCommand(raw: string[]): number {
  for (let index = 0; index < raw.length; index++) {
    const arg = raw[index];
    if (arg === "--provider") {
      index++;
      continue;
    }
    if (
      arg === "quota" ||
      arg === "auth" ||
      arg === "models" ||
      arg === "update"
    ) {
      return index;
    }
  }
  return -1;
}
