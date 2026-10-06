// Durable native handoff from the away-mode daemon to a Pi primary hosted in TUIOS.
// This uses Pi's supported message queue API; it never types into a terminal composer.
import { randomBytes } from "node:crypto";
import { closeSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const markerPrefix = "[SQUAD_PI_AFK_HANDOFF:";
const intervalMs = 1000;
type HandoffRequest = { id: string; session: string; window: string; message: string };

function stateDir(): string | null {
  if (process.env.TUIOS_ENV !== "1" || !process.env.TUIOS_SESSION || !process.env.TUIOS_PANE_ID) return null;
  const home = process.env.SQUAD_BASE || process.env.SQUAD_HOME || process.env.SQUAD_ROOT_OVERRIDE;
  if (!home) return null;
  return resolve(home, process.env.SQUAD_STATE_OVERRIDE || "state", ".pi-away-handoff");
}

function identity(): string | null {
  const proc = `/proc/${process.pid}`;
  try {
    const stat = readFileSync(`${proc}/stat`, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 1).trim().split(/\s+/);
    const start = fields[19];
    const cmdline = readFileSync(`${proc}/cmdline`);
    if (!start || !cmdline.length) return null;
    return `linux-starttime=${start} cmdline-hex=${cmdline.toString("hex")}`;
  } catch {
    const ps = spawnSync("ps", ["-p", String(process.pid), "-o", "lstart=", "-o", "command="], { encoding: "utf8", env: { ...process.env, LC_ALL: "C" } });
    const value = ps.status === 0 ? ps.stdout.trim() : "";
    return value || null;
  }
}

function ensureDir(dir: string): boolean {
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const info = lstatSync(dir);
    return info.isDirectory() && !info.isSymbolicLink() && (info.mode & 0o077) === 0;
  } catch {
    return false;
  }
}

function atomicJson(path: string, value: unknown): void {
  const tmp = `${path}.${process.pid}.${randomBytes(8).toString("hex")}.tmp`;
  const fd = openSync(tmp, "wx", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(value)}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, path);
}

function readJson<T>(path: string): T | null {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;
  }
}

function writeStatus(dir: string, id: string, status: string): void {
  atomicJson(`${dir}/result.json`, { id, status, pid: process.pid, at: Date.now() });
}

function messageText(message: unknown): string {
  if (!message || typeof message !== "object") return "";
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => part && typeof part === "object" && "text" in part ? String(part.text) : "").join("\n");
}

export default function (pi: ExtensionAPI): void {
  let dir: string | null = null;
  let targetSession = "";
  let targetWindow = "";
  let processIdentity: string | null = null;
  let context: ExtensionContext | null = null;
  let timer: ReturnType<typeof setInterval> | null = null;
  let sending = false;
  // Positive modal signal: Pi emits ui_prompt_start/ui_prompt_end around every
  // built-in dialog (select/confirm/input/editor/custom). A queued escalation
  // must never start a turn while one is open, so delivery defers until the
  // count returns to zero. This is a native signal from the running process,
  // never an inference from idle/done state or from rendered terminal text.
  let promptsOpen = 0;

  pi.on?.("ui_prompt_start", () => { promptsOpen += 1; });
  pi.on?.("ui_prompt_end", () => { promptsOpen = promptsOpen > 0 ? promptsOpen - 1 : 0; });

  const publishReady = (): void => {
    if (!dir || !processIdentity || !context) return;
    atomicJson(`${dir}/ready.json`, {
      version: 3,
      pid: process.pid,
      identity: processIdentity,
      session: targetSession,
      window: targetWindow,
      idle: context.isIdle(),
      draft: context.ui.getEditorText().trim().length > 0,
      prompts: promptsOpen,
      // Lets the sender distinguish a send that is genuinely in flight from a
      // stale "submitting" record left by a crashed extension, without ever
      // guessing that an unacknowledged escalation was delivered.
      sending,
      heartbeat: Date.now(),
    });
  };

  const pump = async (): Promise<void> => {
    try {
      if (!dir || !context || !ensureDir(dir)) return;
      // Liveness, exact-target binding, and the delivery state are published on
      // every tick - including while a send is in flight - so a queued escalation
      // can wait durably and the sender can tell a live send apart from a stale
      // record. Submission is gated separately below on idle, an empty editor,
      // no open prompt, and no in-flight send.
      publishReady();
      if (sending) return;
      if (!context.isIdle() || context.ui.getEditorText().trim() || promptsOpen > 0) return;
      const request = readJson<HandoffRequest>(`${dir}/request.json`);
      if (!request || !/^[a-f0-9]{64}$/.test(request.id) || request.session !== targetSession || request.window !== targetWindow || !request.message) return;
      const result = readJson<{ id?: string; status?: string }>(`${dir}/result.json`);
      if (result?.id === request.id && result.status !== "new") return;
      try {
        writeStatus(dir, request.id, "submitting");
        sending = true;
        const content = `${request.message}\n\n${markerPrefix}${request.id}]`;
        await pi.sendUserMessage(content, { deliverAs: "followUp" });
        const after = readJson<{ id?: string; status?: string }>(`${dir}/result.json`);
        if (after?.id !== request.id || after.status !== "handled") writeStatus(dir, request.id, "queued");
      } catch {
        writeStatus(dir, request.id, "uncertain");
      } finally {
        sending = false;
      }
    } catch {
      sending = false;
    }
  };

  pi.on?.("session_start", (_event, ctx) => {
    if (timer) clearInterval(timer);
    context = ctx;
    dir = stateDir();
    targetSession = process.env.TUIOS_SESSION || "";
    targetWindow = process.env.TUIOS_PANE_ID || "";
    processIdentity = identity();
    promptsOpen = 0;
    if (!dir || !processIdentity || !ensureDir(dir)) {
      dir = null;
      return;
    }
    void pump();
    timer = setInterval(() => void pump(), intervalMs);
    timer.unref?.();
  });

  pi.on?.("before_agent_start", (event) => {
    if (!dir) return;
    const content = typeof event.prompt === "string" ? event.prompt : messageText(event.prompt);
    const match = content.match(/\[SQUAD_PI_AFK_HANDOFF:([a-f0-9]{64})\]/);
    if (!match) return;
    const request = readJson<HandoffRequest>(`${dir}/request.json`);
    if (request?.id === match[1]) writeStatus(dir, request.id, "handled");
  });

  pi.on?.("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = null;
    context = null;
    promptsOpen = 0;
    if (dir) {
      try {
        const ready = readJson<{ pid?: number; identity?: string }>(`${dir}/ready.json`);
        if (ready?.pid === process.pid && ready.identity === processIdentity) unlinkSync(`${dir}/ready.json`);
      } catch {
        // Keep durable request/result records; a stale ready marker expires by age.
      }
    }
    dir = null;
  });
}
