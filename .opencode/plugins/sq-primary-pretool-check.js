import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelts for OpenCode. The plugin-owned sentry arm is not a
// model tool call, but the model's bash tool still passes through the same
// primary-only arm, backend, and state-poll policies as the other harnesses.
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

      const checks = [
        ["sq-arm-pretool-check.sh", "denied by the sentry-arm PreToolUse seatbelt"],
        ["sq-backend-pretool-check.sh", "denied by the session-provider CLI seatbelt"],
        ["sq-poll-pretool-check.sh", "denied by the state-polling seatbelt"],
      ];
      for (const [checker, fallback] of checks) {
        const result = await runProcess(`${root}/bin/${checker}`, ["--command", command]);
        if (result.code !== 2) continue;
        throw new Error(result.stderr.trim() || fallback);
      }
    },
  };
};
