import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: the arm mechanism itself lives entirely in
// sq-primary-sentry-arm.js (a plugin-owned child process, never a model tool
// call), so the residual risk here is the AGENT shelling `bin/sq-sentry-arm.sh`
// wrong through its own bash tool - the anti-pattern bin/sq-arm-pretool-check.sh
// guards against (see that script's header and docs/arm-pretool-check.md).
// tool.execute.before can block by throwing (verified 2026-07-09 against
// OpenCode 1.17.15: throwing here prevents the bash command from running and
// surfaces the thrown message as the failed tool result).

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryPretoolCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;

      for (const [script, fallback] of [
        ["sq-backend-pretool-check.sh", "denied by the session-provider CLI seatbelt"],
        ["sq-poll-pretool-check.sh", "denied by the state-polling seatbelt"],
        ["sq-arm-pretool-check.sh", "denied by the sentry-arm PreToolUse seatbelt"],
      ]) {
        const result = await runProcess(`${root}/bin/${script}`, ["--command", command]);
        if (result.code === 2) throw new Error(result.stderr.trim() || fallback);
      }
    },
  };
};
