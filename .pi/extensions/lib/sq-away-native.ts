// Pi receiver for the backend-neutral native away protocol.
// Terminal bytes are never a message transport. Uncertain sends never replay.
import { randomBytes } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Endpoint = { backend: string; target: string; runtime: string; incarnation: string; worktree: string; path: string };
type Receiver = { pid: number; identity: string; session: string };
type Request = { version: number; id: string; provider: string; endpoint: Endpoint; receiver: Receiver; message: string };
const helper = resolve(dirname(fileURLToPath(import.meta.url)), "../../../bin/sq-supervisor-native.sh");
const marker = "[SQUAD_NATIVE_AWAY:";

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
function command(...args: string[]): string | null {
  const r = spawnSync("bash", [helper, ...args], { encoding: "utf8", timeout: 5000 });
  return r.status === 0 ? r.stdout.trim() || null : null;
}
function same(a: unknown, b: unknown): boolean { return JSON.stringify(a) === JSON.stringify(b); }

export function installNativeAway(pi: ExtensionAPI): void {
  let ctx: ExtensionContext | null = null;
  let state = "", dir = "";
  let endpoint: Endpoint | null = null;
  let receiver: Receiver | null = null;
  let timer: ReturnType<typeof setInterval> | null = null;
  let prompts = 0, sending = false;
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
  const bound = (): boolean => {
    const raw = endpoint && command("endpoint", endpoint.backend, endpoint.target);
    if (!raw) return false;
    try { return same(JSON.parse(raw), endpoint); } catch { return false; }
  };
  const matches = (request: Request | null): request is Request => !!request && request.version === 1 && request.provider === "pi" && /^[a-f0-9]{64}$/.test(request.id) && same(request.endpoint, endpoint) && same(request.receiver, receiver) && typeof request.message === "string" && !!request.message;
  const result = (request: Request, status: string): void => atomic(`${dir}/result.json`, { id: request.id, status, endpoint, receiver });
  const pump = async (): Promise<void> => {
    try {
      if (!ctx || !endpoint || !receiver || !owner()) return;
      if (!safeDir(true) || !bound()) return;
      // Read actual native editor/modal state, not old terminal output.
      atomic(`${dir}/ready.json`, { version: 1, provider: "pi", endpoint, ...receiver, idle: ctx.isIdle(), draft: !!ctx.ui.getEditorText().trim(), prompts, sending, heartbeat: Date.now() });
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
    timer = null; ctx = null; endpoint = null; receiver = null; dir = ""; prompts = 0; sending = false;
    // Deliberate selection only. The exact handle is supplied by the primary
    // launch, never inferred from an active tab or the daemon's own terminal.
    if (process.env.SQUAD_SUPERVISOR_BACKEND !== "orca" || !process.env.SQUAD_SUPERVISOR_TARGET || process.env.SQUAD_PI_HARNESS === "pi-signed") return;
    if (context.mode !== "tui" || !context.hasUI) return;
    const home = process.env.SQUAD_BASE || process.env.SQUAD_HOME || process.env.SQUAD_ROOT_OVERRIDE;
    if (!home) return;
    state = resolve(home, process.env.SQUAD_STATE_OVERRIDE || "state");
    const raw = command("endpoint", "orca", process.env.SQUAD_SUPERVISOR_TARGET);
    const path = command("dir", state, process.env.SQUAD_SUPERVISOR_TARGET);
    const id = identity();
    if (!raw || !path || !id) return;
    try {
      endpoint = JSON.parse(raw) as Endpoint;
      if (resolve(endpoint.path) !== resolve(home)) { endpoint = null; return; }
    } catch { return; }
    dir = path;
    receiver = { pid: process.pid, identity: id, session: randomBytes(32).toString("hex") };
    ctx = context;
    void pump();
    timer = setInterval(() => void pump(), 1000);
    timer.unref?.();
  });
  pi.on("before_agent_start", (event) => {
    if (!dir || !receiver || !owner() || !safeDir()) return;
    const request = read<Request>(`${dir}/request.json`);
    if (!matches(request) || event.prompt !== `${request.message}\n\n${marker}${request.id}]`) return;
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
