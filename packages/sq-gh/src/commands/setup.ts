import { AxiError, installSessionStartHooks } from "axi-sdk-js";
import { renderHelp, renderOutput } from "../toon.js";

export const SETUP_HELP = `usage: sq-gh setup hooks
Install or repair agent SessionStart hooks for sq-gh ambient context.

examples:
  sq-gh setup hooks
`;

export async function setupCommand(args: string[]): Promise<string> {
  if (args.length !== 1 || args[0] !== "hooks") {
    throw new AxiError("Unknown setup action", "VALIDATION_ERROR", [
      "Run `sq-gh setup hooks`",
    ]);
  }

  installSessionStartHooks();

  return renderOutput([
    "hooks:\n  status: installed\n  integrations: Claude Code, Codex, OpenCode",
    renderHelp(["Restart your agent session to receive sq-gh ambient context"]),
  ]);
}
