import { execFile } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { promisify } from "node:util";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const run = promisify(execFile);
const root = resolve(process.env.SQUAD_ROOT ?? process.cwd());
const base = resolve(process.env.SQUAD_BASE ?? process.env.SQUAD_HOME ?? root);
const data = resolve(process.env.SQUAD_DATA_OVERRIDE ?? `${base}/data`);
const state = resolve(process.env.SQUAD_STATE_OVERRIDE ?? `${base}/state`);
const scripts = resolve(`${root}/bin`);
const MAX_OBJECTIVE = 4000;
const ID = /^[a-z0-9][a-z0-9-]{2,63}$/;

type ErrorCode = "INVALID_INPUT" | "PROJECT_NOT_ALLOWED" | "SPAWN_FAILED" | "TASK_NOT_FOUND" | "STOP_REFUSED" | "INTERNAL_ERROR";
type Result = Record<string, unknown>;

function ok(value: Result): { content: [{ type: "text"; text: string }] } {
  return { content: [{ type: "text", text: JSON.stringify({ ok: true, ...value }) }] };
}
function fail(code: ErrorCode, error: string): { content: [{ type: "text"; text: string }]; isError: true } {
  return { content: [{ type: "text", text: JSON.stringify({ ok: false, error, code }) }], isError: true };
}
function taskId(value: unknown): string | undefined {
  return typeof value === "string" && ID.test(value) ? value : undefined;
}
function safeProject(name: string): string | undefined {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name)) return;
  const registry = `${data}/projects.md`;
  if (!existsSync(registry)) return;
  const registered = readFileSync(registry, "utf8").split("\n").some((line) => /^-\s+([^\s]+)/.exec(line)?.[1] === name);
  if (!registered) return;
  const project = resolve(`${base}/projects/${name}`);
  if (!project.startsWith(resolve(`${base}/projects/`) + "/") || !existsSync(`${project}/.git`)) return;
  return project;
}
function bounded(value: string, limit = 240): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, limit);
}
function parseState(line: string): { state: string; source: string; summary: string } {
  const parts = line.split(" · ");
  return { state: parts[0]?.replace(/^state:\s*/, "") || "unknown", source: parts[1]?.replace(/^source:\s*/, "") || "none", summary: bounded(parts.slice(2).join(" · ")) };
}
async function command(name: string, args: string[], timeout = 30000): Promise<{ stdout: string; stderr: string }> {
  return run(`${scripts}/${name}`, args, { cwd: root, env: { ...process.env, SQUAD_BASE: base }, timeout, maxBuffer: 256 * 1024 });
}
function makeId(): string {
  return `personal-os-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
}

export function createServer(): McpServer {
  const server = new McpServer({ name: "squad-mcp", version: "0.1.0" });
  server.tool("squad_start", "Start a Squad engineering task in a registered project.", {
    project: z.string().describe("Registered project name"),
    objective: z.string().min(1).max(MAX_OBJECTIVE).describe("Bounded engineering objective"),
  }, async ({ project, objective }) => {
    const projectPath = safeProject(project);
    if (!projectPath) return fail("PROJECT_NOT_ALLOWED", "project is not registered or unavailable");
    const id = makeId();
    try {
      await command("sq-brief.sh", [id, `projects/${project}`, "--mode", "drill"]);
      const brief = `${data}/${id}/brief.md`;
      const text = readFileSync(brief, "utf8").replaceAll("{TASK}", objective);
      writeFileSync(brief, text);
      await command("sq-spawn.sh", [id, projectPath, "--mode", "drill", "--yolo", "off"]);
      return ok({ taskId: id, status: "created", summary: "Task started" });
    } catch {
      return fail("SPAWN_FAILED", "Squad could not start the task");
    }
  });
  server.tool("squad_status", "Read the reconciled status of a Squad task.", {
    taskId: z.string().describe("Durable Squad task identity"),
  }, async ({ taskId: input }) => {
    const id = taskId(input);
    if (!id) return fail("INVALID_INPUT", "taskId is malformed");
    if (!existsSync(`${state}/${id}.meta`)) return fail("TASK_NOT_FOUND", "taskId is unknown");
    try {
      const result = await command("sq-crew-state.sh", [id]);
      const status = parseState(result.stdout.trim());
      return ok({ taskId: id, state: status.state, source: status.source, summary: status.summary });
    } catch {
      return fail("INTERNAL_ERROR", "Squad status is temporarily unavailable");
    }
  });
  server.tool("squad_stop", "Safely clean up a completed Squad task when existing protections permit it.", {
    taskId: z.string().describe("Durable Squad task identity"),
  }, async ({ taskId: input }) => {
    const id = taskId(input);
    if (!id) return fail("INVALID_INPUT", "taskId is malformed");
    if (!existsSync(`${state}/${id}.meta`)) return fail("TASK_NOT_FOUND", "taskId is unknown");
    try {
      await command("sq-teardown.sh", [id]);
      return ok({ taskId: id, status: "stopped", summary: "Task cleanup completed safely" });
    } catch {
      return fail("STOP_REFUSED", "Task cannot be stopped safely; existing work or approval protections remain");
    }
  });
  return server;
}

export async function startServer(): Promise<void> {
  if (!existsSync(scripts) || !existsSync(data) || !existsSync(state)) throw new Error("Squad MCP base is not initialized");
  const server = createServer();
  await server.connect(new StdioServerTransport());
}
