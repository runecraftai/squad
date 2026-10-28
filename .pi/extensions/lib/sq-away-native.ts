// Pi receiver for the backend-neutral native away protocol.
// Terminal bytes are never a message transport. Uncertain sends never replay.
import { randomBytes } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Endpoint = { backend: string; target: string; runtime: string; incarnation: string; worktree: string; path: string };
type Receiver = { pid: number; identity: string; session: string };
type Request = { version: number; id: string; provider: string; endpoint: Endpoint; receiver: Receiver; message: string };
const helper = resolve(dirname(fileURLToPath(import.meta.url)), "../../../bin/sq-supervisor-native.sh");
const marker = "[SQUAD_NATIVE_AWAY:";
const bind_timeout_ms = 5000;
const revalidate_ms = 30000;
const retry_ms = 5000;
const revalidate_timeout_ms = 2000;

function read<T>(path: string): T | null {
  try {
    if (!lstatSync(path).isFile() || lstatSync(path).isSymbolicLink()) return null;
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch { return null; }
}
function atomic(path: string, value: unknown): void {
  const tmp = `${path}.${process.pid}.${randomBytes(8).toString("hex")}`;
  const fd = openSync(tmp, "wx", 0o600);
  try { writeFileSync(fd, JSON.stringify(value)); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(tmp, path);
}
function identity(): string | null {
  try {
    const stat = readFileSync(`/proc/${process.pid}/stat`, "utf8");
    const start = stat.slice(stat.lastIndexOf(")") + 1).trim().split(/\s+/)[19];
    const cmd = readFileSync(`/proc/${process.pid}/cmdline`);
    return start && cmd.length ? `linux-starttime=${start} cmdline-hex=${cmd.toString("hex")}` : null;
  } catch {
    const ps = spawnSync("ps", ["-p", String(process.pid), "-o", "lstart=", "-o", "command="], { encoding: "utf8", env: { ...process.env, LC_ALL: "C" } });
    return ps.status === 0 ? ps.stdout.trim() || null : null;
  }
}
function command(timeout: number, ...args: string[]): string | null {
  const r = spawnSync("bash", [helper, ...args], { encoding: "utf8", timeout });
  return r.status === 0 ? r.stdout.trim() || null : null;
}
function physical(path: string): string {
  try { return realpathSync(path); } catch { return ""; }
}
function nativeSelection(home: string): { backend: "orca"; target: string } | null {
  const backend = process.env.SQUAD_SUPERVISOR_BACKEND;
  const target = process.env.SQUAD_SUPERVISOR_TARGET;
  if (backend !== undefined || target !== undefined) return backend === "orca" && target ? { backend: "orca", target } : null;
  const handle = process.env.ORCA_TERMINAL_HANDLE || "";
  const worktree = process.env.ORCA_WORKTREE_ID || "";
  const separator = worktree.lastIndexOf("::");
  if (!/^term[_-][A-Za-z0-9][A-Za-z0-9._-]*$/.test(handle) || separator < 0) return null;
  const worktreePath = worktree.slice(separator + 2);
  return worktreePath && physical(worktreePath) === physical(home) ? { backend: "orca", target: handle } : null;
}
function same(a: unknown, b: unknown): boolean { return JSON.stringify(a) === JSON.stringify(b); }
function messageText(message: unknown): string {
  if (typeof message === "string") return message;
  if (!message || typeof message !== "object") return "";
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => part && typeof part === "object" && "text" in part ? String(part.text) : "").join("\n");
}

export function installNativeAway(pi: ExtensionAPI): void {
  let ctx: ExtensionContext | null = null;
  let state = "", dir = "";
  let endpoint: Endpoint | null = null;
  let receiver: Receiver | null = null;
  let timer: ReturnType<typeof setInterval> | null = null;
  let prompts = 0, sending = false, bound_ok = false, next_check = 0;
  // Capture the generation across await: a session replacement cannot write an
  // acknowledgement or queued verdict into a different receiver incarnation.
  let generation = 0;
  const owner = (): boolean => {
    try { return readFileSync(`${state}/.lock`, "utf8").trim() === String(process.pid); } catch { return false; }
  };
  const safeDir = (create = false): boolean => {
    try {
      for (const path of [`${state}/.away-handoff`, dir]) {
        if (create) {
          try { lstatSync(path); } catch (error) {
            if ((error as NodeJS.ErrnoException)?.code !== "ENOENT") return false;
            mkdirSync(path, { mode: 0o700 });
          }
        }
        const s = lstatSync(path);
        if (!s.isDirectory() || s.isSymbolicLink() || (s.mode & 0o077) !== 0 || s.uid !== process.getuid?.()) return false;
      }
      return true;
    } catch { return false; }
  };
  const bound = (timeout: number): boolean => {
    const raw = endpoint && command(timeout, "endpoint", endpoint.backend, endpoint.target);
    if (!raw) return false;
    try { return same(JSON.parse(raw), endpoint); } catch { return false; }
  };
  const matches = (request: Request | null): request is Request => !!request && request.version === 1 && request.provider === "pi" && /^[a-f0-9]{64}$/.test(request.id) && same(request.endpoint, endpoint) && same(request.receiver, receiver) && typeof request.message === "string" && !!request.message;
  const result = (request: Request, status: string): void => atomic(`${dir}/result.json`, { id: request.id, status, endpoint, receiver });
  const pump = async (): Promise<void> => {
    try {
      if (!ctx || !endpoint || !receiver || !owner()) return;
      if (!safeDir(true)) return;
      // Revalidation is the only part of the heartbeat that spawns processes.
      // It runs on a slow cadence with a short timeout, and a failed probe keeps
      // readiness unpublished while retrying quickly, so a wedged Orca CLI can
      // never stall the interactive event loop on every tick or blank readiness
      // for the whole slow-probe window on one transient failure.
      const now = Date.now();
      if (now >= next_check) {
        bound_ok = bound(revalidate_timeout_ms);
        next_check = now + (bound_ok ? revalidate_ms : retry_ms);
      }
      if (!bound_ok) return;
      // Read actual native editor/modal state, not old terminal output.
      atomic(`${dir}/ready.json`, { version: 1, provider: "pi", endpoint, ...receiver, idle: ctx.isIdle(), draft: !!ctx.ui.getEditorText().trim(), prompts, sending, heartbeat: now });
      if (sending || !existsSync(`${state}/.afk`) || !ctx.isIdle() || ctx.ui.getEditorText().trim() || prompts > 0) return;
      const request = read<Request>(`${dir}/request.json`);
      if (!matches(request)) return;
      const prior = read<{ id: string }>(`${dir}/result.json`);
      if (existsSync(`${dir}/result.json`) && !prior) return;
      if (prior?.id === request.id) return; // includes submitting, queued, uncertain, handled
      const current = generation;
      result(request, "submitting"); // durable before the only send
      sending = true;
      try {
        await pi.sendUserMessage(`${request.message}\n\n${marker}${request.id}]`, { deliverAs: "followUp" });
        if (current !== generation) return;
        const after = read<{ id: string; status: string }>(`${dir}/result.json`);
        if (after?.id !== request.id || after.status !== "handled") result(request, "queued");
      } catch {
        if (current === generation) result(request, "uncertain");
      } finally {
        if (current === generation) sending = false;
      }
    } catch { /* No readiness refresh on unreadable state; never fall back to typing. */ }
  };
  pi.on("ui_prompt_start", () => { prompts += 1; });
  pi.on("ui_prompt_end", () => { prompts = Math.max(0, prompts - 1); });
  pi.on("session_start", (_event, context) => {
    generation += 1;
    if (timer) clearInterval(timer);
    timer = null; ctx = null; endpoint = null; receiver = null; dir = ""; prompts = 0; sending = false; bound_ok = false; next_check = 0;
    // Select only from an explicit override or the exact identity issued to this
    // primary by Orca, bound to the physical Squad base path.
    if (process.env.SQUAD_PI_HARNESS === "pi-signed") return;
    if (context.mode !== "tui" || !context.hasUI) return;
    const home = process.env.SQUAD_BASE || process.env.SQUAD_HOME || process.env.SQUAD_ROOT_OVERRIDE;
    if (!home) return;
    const selection = nativeSelection(home);
    if (!selection) return;
    state = resolve(home, process.env.SQUAD_STATE_OVERRIDE || "state");
    const raw = command(bind_timeout_ms, "endpoint", selection.backend, selection.target);
    const path = command(bind_timeout_ms, "dir", state, selection.target);
    const id = identity();
    if (!raw || !path || !id) return;
    try {
      endpoint = JSON.parse(raw) as Endpoint;
      // The launcher compares the same worktree against `pwd -P`, so the
      // receiver must use the physical path too or a symlinked SQUAD_BASE
      // would pass one gate and fail the other.
      const bound_path = physical(endpoint.path), home_path = physical(home);
      if (!bound_path || bound_path !== home_path) { endpoint = null; return; }
    } catch { return; }
    dir = path;
    receiver = { pid: process.pid, identity: id, session: randomBytes(32).toString("hex") };
    bound_ok = true;
    next_check = Date.now() + revalidate_ms;
    ctx = context;
    void pump();
    timer = setInterval(() => void pump(), 1000);
    timer.unref?.();
  });
  pi.on("before_agent_start", (event) => {
    if (!dir || !receiver || !owner() || !safeDir()) return;
    const request = read<Request>(`${dir}/request.json`);
    const prompt = typeof event.prompt === "string" ? event.prompt : messageText(event.prompt);
    if (!matches(request) || prompt !== `${request.message}\n\n${marker}${request.id}]`) return;
    const prior = read<{ id: string; status: string }>(`${dir}/result.json`);
    if (prior?.id === request.id && ["submitting", "queued", "uncertain"].includes(prior.status)) result(request, "handled");
  });
  pi.on("session_shutdown", () => {
    generation += 1;
    if (timer) clearInterval(timer);
    timer = null;
    if (dir && safeDir()) {
      const ready = read<{ pid: number; identity: string }>(`${dir}/ready.json`);
      if (ready?.pid === receiver?.pid && ready?.identity === receiver?.identity) {
        try { unlinkSync(`${dir}/ready.json`); } catch { /* retained readiness expires */ }
      }
    }
    ctx = null; receiver = null; endpoint = null;
  });
}
