import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  classifySquadCurrentOperationalText,
  encodeSquadOperationalInput,
} from "./lib/sq-operational-input.ts";

let guardFollowupActive = false;

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.SQUAD_BASE || process.env.SQUAD_HOME || process.env.SQUAD_ROOT_OVERRIDE || root;
const state = process.env.SQUAD_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

// Pi's session_start reasons are startup | reload | new | resume | fork, and a
// separate session_compact event fires after a compaction. "new" is Pi's /clear
// (a fresh session in the SAME process, so the unit lock is still ours), while
// reload, resume, and fork all keep prior context. bin/sq-sessionstart-run.sh
// owns what each source means; this maps Pi's vocabulary onto its --source
// names and injects whatever it prints.
const sessionstartDeliveryBytes = 512 * 1024;
const sessionstartTruncatedMarker =
  "\n\nPI SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";

function runSessionstartHook(source: string): Promise<string> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/sq-sessionstart-run.sh`, ["--source", source], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    const chunks: Buffer[] = [];
    let retainedBytes = 0;
    let truncated = false;
    child.stdout.on("data", (chunk: Buffer) => {
      if (retainedBytes >= sessionstartDeliveryBytes) {
        truncated = true;
        return;
      }
      const remaining = sessionstartDeliveryBytes - retainedBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      chunks.push(retained);
      retainedBytes += retained.length;
      if (retained.length !== chunk.length) truncated = true;
    });
    child.on("error", () => resolveResult(""));
    child.on("close", (code) => {
      if (code !== 0) {
        resolveResult("");
        return;
      }
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      resolveResult(truncated ? `${raw}${sessionstartTruncatedMarker}` : raw);
    });
  });
}

async function injectSessionstart(pi: ExtensionAPI, source: string): Promise<void> {
  const raw = await runSessionstartHook(source);
  if (!raw) return;
  try {
    // Pi is the only adapter that injects a MESSAGE rather than hook stdout, so
    // whatever it injects must carry operational provenance or the Reporting skill
    // would have to guess whether it was commander-authored. The wrapper already
    // returns an encoded nudge on a context-preserving open, so only an
    // unencoded digest needs the marker added here.
    const content = classifySquadCurrentOperationalText(raw)
      ? raw
      : encodeSquadOperationalInput("session-start", raw);
    pi.sendMessage({
      customType: "Squad-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    });
  } catch {
  }
}

// New-session handoff surface (docs/handoff-request.md). At a milestone close
// Squad records a durable handoff request; this surface presents the handoff
// card exactly once per milestone by running bin/sq-handoff-surface.sh on every
// agent settle. That script owns the once-per-milestone atomic mark under the
// handoff-queue lock, so whichever surface runs first - this extension or the
// session-start digest - presents the card and every later call stays silent.
// The card is delivered as a typed handoff-request operational wake so
// Reporting does not mistake an injected card for a commander message.
function runHandoffSurface(): Promise<string> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/sq-handoff-surface.sh`, {
      stdio: ["ignore", "pipe", "ignore"],
    });
    const chunks: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => {
      chunks.push(chunk);
    });
    child.on("error", () => resolveResult(""));
    child.on("close", () => resolveResult(Buffer.concat(chunks).toString("utf8").trim()));
  });
}

async function surfaceHandoff(pi: ExtensionAPI): Promise<void> {
  const card = await runHandoffSurface();
  if (!card) return;
  try {
    const content = encodeSquadOperationalInput("handoff-request", card);
    await pi.sendUserMessage(content, { deliverAs: "followUp" });
  } catch {
  }
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/sq-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

// PreToolUse seatbelts (bin/sq-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/sq-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra Pi -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-09 against pi 0.80.5:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/${script}`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("sq-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("sq-cd-pretool-check.sh", command);
}

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", async (event) => {
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const source = { startup: "startup", new: "clear", resume: "resume", fork: "fork" }[reason];
    markLoaded();
    if (!source) return;
    await injectSessionstart(pi, source);
  });

  // Pi's compaction equivalent. The digest is what a compacted session has just
  // lost, so re-emitting it here is the point rather than a side effect.
  pi.on?.("session_compact", async () => {
    await injectSessionstart(pi, "compact");
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the sentry-arm PreToolUse seatbelt" };
  });

  pi.on("agent_settled", async () => {
    await surfaceHandoff(pi);

    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }

    const result = await runGuard();
    if (result.code !== 2) return;

    guardFollowupActive = true;
    try {
      const content = encodeSquadOperationalInput(
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The sentry cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      guardFollowupActive = false;
    }
  });

  markLoaded();
}
