import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
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
const MAX_TEXT = 4000;
const ID = /^[a-z0-9][a-z0-9-]{2,63}$/;
const PROJECT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

type ErrorCode =
  | "INVALID_INPUT"
  | "PROJECT_NOT_ALLOWED"
  | "TASK_NOT_FOUND"
  | "ENQUEUE_FAILED"
  | "INTERNAL_ERROR";
type Result = Record<string, unknown>;

function ok(value: Result): { content: [{ type: "text"; text: string }] } {
  return { content: [{ type: "text", text: JSON.stringify({ ok: true, ...value }) }] };
}
function fail(
  code: ErrorCode,
  error: string,
): { content: [{ type: "text"; text: string }]; isError: true } {
  return {
    content: [{ type: "text", text: JSON.stringify({ ok: false, error, code }) }],
    isError: true,
  };
}
function taskId(value: unknown): string | undefined {
  return typeof value === "string" && ID.test(value) ? value : undefined;
}
function safeProject(name: string): string | undefined {
  if (!PROJECT_RE.test(name)) return undefined;
  const registry = `${data}/projects.md`;
  if (!existsSync(registry)) return undefined;
  const registered = readFileSync(registry, "utf8")
    .split("\n")
    .some((line) => /^-\s+([^\s]+)/.exec(line)?.[1] === name);
  if (!registered) return undefined;
  const project = resolve(`${base}/projects/${name}`);
  if (
    !project.startsWith(resolve(`${base}/projects/`) + "/") ||
    !existsSync(`${project}/.git`)
  )
    return undefined;
  return project;
}
function bounded(value: string, limit = 240): string {
  return value
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, limit);
}
function parseState(line: string): {
  state: string;
  source: string;
  summary: string;
} {
  const parts = line.split(" · ");
  return {
    state: parts[0]?.replace(/^state:\s*/, "") || "unknown",
    source: parts[1]?.replace(/^source:\s*/, "") || "none",
    summary: bounded(parts.slice(2).join(" · ")),
  };
}
async function command(
  name: string,
  args: string[],
  stdin?: string,
  timeout = 30000,
): Promise<{ stdout: string; stderr: string }> {
  const result = await run(`${scripts}/${name}`, args, {
    cwd: root,
    env: { ...process.env, SQUAD_BASE: base },
    timeout,
    maxBuffer: 256 * 1024,
    ...(stdin !== undefined ? { input: stdin } : {}),
  });
  return { stdout: result.stdout, stderr: result.stderr };
}
function makeRequestId(): string {
  return `mcp-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
}

/**
 * Encode a launch-brief operational input in the canonical wire form:
 *   U+2063 SQUAD_OP: v1 launch-brief: <body>
 *
 * This mirrors sq-operational-input.sh's fm_operational_input_encode exactly.
 */
function encodeLaunchBrief(body: string): string {
  const mark = "\u2063";
  return `${mark}SQUAD_OP: v1 launch-brief: ${body}`;
}

/** Read the last N lines of a file, returning empty string if missing. */
function tailLines(filePath: string, n: number): string {
  try {
    if (!existsSync(filePath)) return "";
    const content = readFileSync(filePath, "utf8");
    const lines = content.trimEnd().split("\n");
    return lines.slice(-n).join("\n");
  } catch {
    return "";
  }
}

/** Parse a sq-tasks --json list output into structured items. */
function parseTaskList(json: string): Result[] {
  try {
    const parsed = JSON.parse(json);
    if (parsed && typeof parsed === "object" && Array.isArray(parsed.tasks)) {
      return parsed.tasks.map((t: Record<string, unknown>) => ({
        id: t.id,
        title: t.title,
        state: t.state,
        kind: t.kind,
        repo: t.repo,
        blockedBy: t["blocked-by"],
        holdReason: t["hold-reason"],
      }));
    }
  } catch {
    // fall through
  }
  return [];
}

export function createServer(): McpServer {
  const server = new McpServer({ name: "squad-mcp", version: "0.2.0" });

  // ── Read tools (never write) ──────────────────────────────────────────

  server.tool(
    "squad_status",
    "Read the reconciled status of a single Squad task.",
    {
      taskId: z.string().describe("Durable Squad task identity"),
    },
    async ({ taskId: input }) => {
      const id = taskId(input);
      if (!id) return fail("INVALID_INPUT", "taskId is malformed");
      if (!existsSync(`${state}/${id}.meta`))
        return fail("TASK_NOT_FOUND", "taskId is unknown");
      try {
        const result = await command("sq-crew-state.sh", [id]);
        const status = parseState(result.stdout.trim());
        return ok({
          taskId: id,
          state: status.state,
          source: status.source,
          summary: status.summary,
        });
      } catch {
        return fail("INTERNAL_ERROR", "Squad status is temporarily unavailable");
      }
    },
  );

  server.tool(
    "squad_situation",
    "Read the current unit situation: active tasks, their states, and the afk flag.",
    {},
    async () => {
      try {
        const metas: Result[] = [];
        const stateDir = state;
        if (!existsSync(stateDir))
          return ok({ tasks: [], afk: false });
        const entries = readdirSync(stateDir, { withFileTypes: true });
        for (const entry of entries) {
          if (!entry.isFile() || !entry.name.endsWith(".meta")) continue;
          const id = entry.name.replace(/\.meta$/, "");
          const metaPath = `${stateDir}/${entry.name}`;
          try {
            const meta = readFileSync(metaPath, "utf8");
            const fields: Record<string, string> = {};
            for (const line of meta.split("\n")) {
              const eq = line.indexOf("=");
              if (eq > 0) fields[line.slice(0, eq)] = line.slice(eq + 1);
            }
            // Read the last status line for a quick state hint.
            const statusFile = `${stateDir}/${id}.status`;
            let lastStatus = "";
            if (existsSync(statusFile)) {
              lastStatus = tailLines(statusFile, 1);
            }
            metas.push({
              id,
              kind: fields.kind || "unknown",
              project: fields.project || "",
              harness: fields.harness || "",
              mode: fields.mode || "",
              lastStatus: bounded(lastStatus),
            });
          } catch {
            // skip unreadable meta
          }
        }
        const afk = existsSync(`${stateDir}/.afk`);
        return ok({ tasks: metas, afk });
      } catch {
        return fail("INTERNAL_ERROR", "Could not read unit state");
      }
    },
  );

  server.tool(
    "squad_backlog",
    "Read the task backlog, optionally filtered by state. Returns id, title, state, kind, and dependencies.",
    {
      state: z
        .enum(["queued", "in-flight", "done", "held", "all"])
        .optional()
        .describe("Filter by task state (default: all)"),
      limit: z
        .number()
        .int()
        .min(1)
        .max(100)
        .optional()
        .describe("Max items to return (default: 50)"),
    },
    async ({ state: filterState, limit: filterLimit }) => {
      try {
        const args = ["list", "--json"];
        if (filterState && filterState !== "all") {
          args.push("--state", filterState);
        }
        if (filterLimit) {
          args.push("--limit", String(filterLimit));
        }
        const result = await command("sq-tasks", args);
        const items = parseTaskList(result.stdout);
        return ok({ tasks: items, count: items.length });
      } catch {
        return fail(
          "INTERNAL_ERROR",
          "Backlog read failed; sq-tasks may not be installed",
        );
      }
    },
  );

  server.tool(
    "squad_decisions",
    "Read pending commander decisions (needs-decision and blocked states) from the durable status logs.",
    {},
    async () => {
      try {
        // Use the classify-lib's open-decisions scan via the drain script's logic.
        // We run a lightweight grep-based scan of status files for needs-decision/blocked lines.
        const decisions: Result[] = [];
        if (!existsSync(state)) return ok({ decisions: [] });
        const entries = readdirSync(state, { withFileTypes: true });
        for (const entry of entries) {
          if (!entry.isFile() || !entry.name.endsWith(".status")) continue;
          const id = entry.name.replace(/\.status$/, "");
          try {
            const content = readFileSync(`${state}/${entry.name}`, "utf8");
            const lines = content.trimEnd().split("\n");
            // Walk backwards for the latest decision-bearing line per key.
            const seen = new Set<string>();
            for (let i = lines.length - 1; i >= 0 && seen.size < 3; i--) {
              const line = lines[i];
              // Match needs-decision: or blocked: lines.
              const m =
                /^(needs-decision|blocked)\s*(?:\[key=([^\]]+)\])?\s*:\s*(.+)$/.exec(
                  line,
                );
              if (!m) continue;
              const verb = m[1];
              const key = m[2] || "default";
              if (seen.has(key)) continue;
              seen.add(key);
              // Check if there's a resolved line for this key after it.
              const resolvedPattern = new RegExp(
                `^resolved\\s*\\[key=${key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\]`,
              );
              const after = lines.slice(i + 1);
              if (after.some((l) => resolvedPattern.test(l))) continue;
              decisions.push({
                taskId: id,
                key,
                verb,
                note: bounded(m[3]),
              });
            }
          } catch {
            // skip unreadable
          }
        }
        return ok({ decisions });
      } catch {
        return fail("INTERNAL_ERROR", "Decision scan failed");
      }
    },
  );

  // ── Task writes via sanctioned sq-tasks CLI ───────────────────────────

  server.tool(
    "squad_task_create",
    "Create a new task in the backlog via the sanctioned sq-tasks CLI. Returns the task id.",
    {
      id: z
        .string()
        .optional()
        .describe(
          "Task id (caller-supplied). Omit to auto-generate a slug-xx id.",
        ),
      title: z.string().min(1).max(MAX_TEXT).describe("Task title"),
      kind: z
        .enum(["strike", "recon", "commander", "xo"])
        .optional()
        .describe("Task kind (default: strike)"),
      project: z
        .string()
        .optional()
        .describe("Project name (must be registered)"),
    },
    async ({ id, title, kind, project }) => {
      if (!title.trim())
        return fail("INVALID_INPUT", "title must not be empty");
      // Validate project if provided.
      if (project && !safeProject(project))
        return fail("PROJECT_NOT_ALLOWED", "project is not registered");
      try {
        const args = ["add", "--json"];
        if (id) args.push(id);
        args.push(title);
        if (kind) args.push("--kind", kind);
        if (project) args.push("--repo", project);
        const result = await command("sq-tasks", args);
        let parsed: Record<string, unknown> = {};
        try {
          parsed = JSON.parse(result.stdout);
        } catch {
          // Fall back to extracting id from TOON output.
        }
        const taskId =
          (parsed.task as Record<string, unknown>)?.id ||
          (typeof parsed.id === "string" ? parsed.id : undefined);
        return ok({ taskId: taskId || "created", raw: bounded(result.stdout) });
      } catch {
        return fail("INTERNAL_ERROR", "sq-tasks add failed");
      }
    },
  );

  server.tool(
    "squad_task_update",
    "Update a task's title or body via the sanctioned sq-tasks CLI.",
    {
      taskId: z.string().describe("Task id to update"),
      title: z
        .string()
        .max(MAX_TEXT)
        .optional()
        .describe("New title (omit to keep current)"),
      body: z
        .string()
        .max(MAX_TEXT * 4)
        .optional()
        .describe("New body text (omit to keep current)"),
    },
    async ({ taskId: input, title, body }) => {
      const id = taskId(input);
      if (!id) return fail("INVALID_INPUT", "taskId is malformed");
      if (!title && !body)
        return fail("INVALID_INPUT", "provide at least title or body");
      try {
        const args = ["update", id, "--json"];
        if (title) args.push("--title", title);
        if (body) args.push("--body", body);
        const result = await command("sq-tasks", args);
        return ok({ taskId: id, raw: bounded(result.stdout) });
      } catch {
        return fail("INTERNAL_ERROR", "sq-tasks update failed");
      }
    },
  );

  server.tool(
    "squad_task_hold",
    "Place a structured hold on a task via the sanctioned sq-tasks CLI, pausing dispatch.",
    {
      taskId: z.string().describe("Task id to hold"),
      reason: z
        .string()
        .min(1)
        .max(MAX_TEXT)
        .describe("Reason for the hold"),
      until: z
        .string()
        .optional()
        .describe("Optional date gate (YYYY-MM-DD)"),
    },
    async ({ taskId: input, reason, until }) => {
      const id = taskId(input);
      if (!id) return fail("INVALID_INPUT", "taskId is malformed");
      if (!reason.trim())
        return fail("INVALID_INPUT", "reason must not be empty");
      try {
        const args = ["hold", id, "--reason", reason, "--json"];
        if (until) args.push("--until", until);
        const result = await command("sq-tasks", args);
        return ok({ taskId: id, held: true, raw: bounded(result.stdout) });
      } catch {
        return fail("INTERNAL_ERROR", "sq-tasks hold failed");
      }
    },
  );

  server.tool(
    "squad_task_block",
    "Declare a dependency blocking this task via the sanctioned sq-tasks CLI.",
    {
      taskId: z.string().describe("Task id to block"),
      by: z.string().describe("Task id that blocks this one"),
    },
    async ({ taskId: input, by }) => {
      const id = taskId(input);
      if (!id) return fail("INVALID_INPUT", "taskId is malformed");
      const blocker = taskId(by);
      if (!blocker) return fail("INVALID_INPUT", "blocking task id is malformed");
      try {
        const result = await command("sq-tasks", [
          "block",
          id,
          "--by",
          blocker,
          "--json",
        ]);
        return ok({ taskId: id, blockedBy: blocker, raw: bounded(result.stdout) });
      } catch {
        return fail("INTERNAL_ERROR", "sq-tasks block failed");
      }
    },
  );

  server.tool(
    "squad_task_unblock",
    "Remove a dependency from a task via the sanctioned sq-tasks CLI.",
    {
      taskId: z.string().describe("Task id to unblock"),
      by: z.string().describe("Blocking task id to remove"),
    },
    async ({ taskId: input, by }) => {
      const id = taskId(input);
      if (!id) return fail("INVALID_INPUT", "taskId is malformed");
      const blocker = taskId(by);
      if (!blocker) return fail("INVALID_INPUT", "blocking task id is malformed");
      try {
        const result = await command("sq-tasks", [
          "unblock",
          id,
          "--by",
          blocker,
          "--json",
        ]);
        return ok({ taskId: id, unblocked: blocker, raw: bounded(result.stdout) });
      } catch {
        return fail("INTERNAL_ERROR", "sq-tasks unblock failed");
      }
    },
  );

  // ── Request tool (replaces squad_start / squad_stop) ──────────────────

  server.tool(
    "squad_request",
    "Enqueue a durable request for the running Squad session. This does NOT spawn or start anything directly - it enqueues a launch-brief operational input via the sanctioned wake-queue path. Squad will process it on its next wake cycle and may dispatch work as it sees fit. Returns a stable request identifier for tracking.",
    {
      project: z.string().describe("Registered project name"),
      objective: z
        .string()
        .min(1)
        .max(MAX_TEXT)
        .describe("Bounded engineering objective"),
      kind: z
        .enum(["launch-brief", "handoff-request"])
        .optional()
        .describe("Request kind (default: launch-brief)"),
    },
    async ({ project, objective, kind }) => {
      const projectPath = safeProject(project);
      if (!projectPath)
        return fail("PROJECT_NOT_ALLOWED", "project is not registered or unavailable");
      const requestId = makeRequestId();
      const requestKind = kind || "launch-brief";
      try {
        // Build the operational-input-encoded body.
        const body = `${requestId} project=${project} objective=${objective}`;
        const encoded = encodeLaunchBrief(body);

        // Enqueue via the sanctioned wake-queue path.
        await command(
          "sq-mcp-wake-append.sh",
          [`${requestId}.status`, encoded],
        );

        return ok({
          requestId,
          status: "enqueued",
          project,
          summary: `Request ${requestId} enqueued for Squad processing`,
        });
      } catch {
        return fail("ENQUEUE_FAILED", "Could not enqueue request to Squad wake queue");
      }
    },
  );

  // ── Reply channel ─────────────────────────────────────────────────────

  server.tool(
    "squad_replies",
    "Read unread replies from the MCP outbox for a given request id. Each reply is a JSON object with the reply body and timestamp.",
    {
      requestId: z.string().describe("Request id to read replies for"),
    },
    async ({ requestId: input }) => {
      const id = taskId(input);
      if (!id) return fail("INVALID_INPUT", "requestId is malformed");
      const outboxDir = `${state}/mcp-outbox`;
      if (!existsSync(outboxDir))
        return ok({ requestId: id, replies: [] });
      try {
        const replyFile = `${outboxDir}/${id}.reply`;
        if (!existsSync(replyFile))
          return ok({ requestId: id, replies: [] });
        const body = readFileSync(replyFile, "utf8");
        // Mark as read by renaming.
        const readDir = `${outboxDir}/.read`;
        mkdirSync(readDir, { recursive: true });
        const readPath = `${readDir}/${id}.reply`;
        // Append to read log (supports multiple replies over time).
        const { renameSync, appendFileSync } = await import("node:fs");
        appendFileSync(readPath, body);
        renameSync(replyFile, `${readPath}.delivered`);
        return ok({
          requestId: id,
          replies: [{ body: bounded(body, 4000) }],
        });
      } catch {
        return fail("INTERNAL_ERROR", "Could not read outbox");
      }
    },
  );

  return server;
}

export async function startServer(): Promise<void> {
  if (!existsSync(scripts) || !existsSync(data) || !existsSync(state))
    throw new Error("Squad MCP base is not initialized");
  const server = createServer();
  await server.connect(new StdioServerTransport());
}
