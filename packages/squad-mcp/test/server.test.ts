import { mkdtemp, mkdir, writeFile, readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = join(import.meta.dirname, "..", "..", "..");
async function clientFor(base: string) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(root, "packages/squad-mcp/dist/bin/squad-mcp.js")],
    cwd: root,
    env: { ...process.env, SQUAD_ROOT: root, SQUAD_BASE: base },
  });
  const client = new Client({ name: "squad-mcp-test", version: "1" });
  await client.connect(transport);
  return { client, transport };
}
function payload(result: any): any {
  return JSON.parse(result.content[0].text);
}

test("stdio startup discovers exactly the V2 tools", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const tools = (await client.listTools()).tools.map((tool) => tool.name);
    assert.deepEqual(tools, [
      "squad_status",
      "squad_situation",
      "squad_backlog",
      "squad_decisions",
      "squad_reports",
      "squad_report_read",
      "squad_history",
      "squad_task_create",
      "squad_task_update",
      "squad_task_hold",
      "squad_task_block",
      "squad_task_unblock",
      "squad_request",
      "squad_replies",
    ]);
  } finally {
    await transport.close();
  }
});

test("repository allowlisting and malformed IDs are typed", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    // Unregistered project is refused.
    assert.equal(
      (
        await client.callTool({
          name: "squad_request",
          arguments: { project: "/etc", objective: "x" },
        })
      ).content[0].text.includes('"PROJECT_NOT_ALLOWED"'),
      true,
    );
    // Malformed task ID is rejected.
    assert.equal(
      (
        await client.callTool({
          name: "squad_status",
          arguments: { taskId: "../secret" },
        })
      ).content[0].text.includes('"INVALID_INPUT"'),
      true,
    );
  } finally {
    await transport.close();
  }
});

test("no tool can spawn an operator, merge, or tear down", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const tools = (await client.listTools()).tools;
    const forbiddenNames = ["squad_start", "squad_stop", "squad_spawn", "squad_teardown", "squad_merge"];
    for (const name of forbiddenNames) {
      assert.equal(
        tools.some((t) => t.name === name),
        false,
        `forbidden tool ${name} must not exist`,
      );
    }
  } finally {
    await transport.close();
  }
});

test("read tools perform no writes (squad_status with missing id)", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    // Status with a nonexistent task returns TASK_NOT_FOUND.
    const result = payload(
      await client.callTool({
        name: "squad_status",
        arguments: { taskId: "nonexistent-001" },
      }),
    );
    assert.equal(result.code, "TASK_NOT_FOUND");
    // No new files should have been created in state/.
    const entries = await readdir(join(base, "state"));
    assert.deepEqual(entries, []);
  } finally {
    await transport.close();
  }
});

test("squad_situation returns empty tasks when no state exists", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const result = payload(
      await client.callTool({ name: "squad_situation", arguments: {} }),
    );
    assert.equal(result.ok, true);
    assert.deepEqual(result.tasks, []);
    assert.equal(result.afk, false);
  } finally {
    await transport.close();
  }
});

test("squad_request enqueues and returns a request identifier", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  // Create a minimal projects.md so safeProject can find a registered project.
  await writeFile(join(base, "data", "projects.md"), "- test-project\n");
  // Create a fake project directory with .git to pass the clone check.
  await mkdir(join(base, "projects", "test-project", ".git"), { recursive: true });

  const { client, transport } = await clientFor(base);
  try {
    const result = payload(
      await client.callTool({
        name: "squad_request",
        arguments: { project: "test-project", objective: "fix the thing" },
      }),
    );
    assert.equal(result.ok, true);
    assert.equal(result.status, "enqueued");
    assert.match(result.requestId, /^mcp-/);
    // The stand-to queue file should have been created with the wake record.
    const queueFile = join(base, "state", ".stand-to-queue");
    assert.ok(existsSync(queueFile), "wake queue was created");
    const queueContent = await readFile(queueFile, "utf8");
    assert.ok(
      queueContent.includes(result.requestId),
      "queue contains the request id",
    );
    assert.ok(
      queueContent.includes("launch-brief"),
      "queue contains launch-brief kind",
    );
    assert.ok(
      queueContent.includes("test-project"),
      "queue contains the project name",
    );
  } finally {
    await transport.close();
  }
});

test("squad_request rejects unregistered projects", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const result = payload(
      await client.callTool({
        name: "squad_request",
        arguments: { project: "nope", objective: "x" },
      }),
    );
    assert.equal(result.code, "PROJECT_NOT_ALLOWED");
  } finally {
    await transport.close();
  }
});

test("squad_replies returns empty when no outbox exists", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const result = payload(
      await client.callTool({
        name: "squad_replies",
        arguments: { requestId: "mcp-test-001" },
      }),
    );
    assert.equal(result.ok, true);
    assert.deepEqual(result.replies, []);
  } finally {
    await transport.close();
  }
});

test("squad_reports lists reports from data directories", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  const dataDir = join(base, "data");
  await mkdir(join(dataDir, "test-recon"), { recursive: true });
  await writeFile(join(dataDir, "test-recon", "report.md"), "# Report\nLine 1\nLine 2\n");
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const result = payload(
      await client.callTool({ name: "squad_reports", arguments: {} }),
    );
    assert.equal(result.ok, true);
    assert.equal(result.count, 1);
    assert.equal(result.reports[0].taskId, "test-recon");
    assert.equal(result.reports[0].lines, 3);
  } finally {
    await transport.close();
  }
});

test("squad_report_read pages a large report with bounded output", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  const dataDir = join(base, "data");
  await mkdir(join(dataDir, "big-report"), { recursive: true });
  // Create a 1500-line report.
  const bigLines = Array.from({ length: 1500 }, (_, i) => `Line ${i + 1}`);
  await writeFile(join(dataDir, "big-report", "report.md"), bigLines.join("\n"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    // Page 1: lines 0-199 (default).
    const p1 = payload(
      await client.callTool({
        name: "squad_report_read",
        arguments: { taskId: "big-report" },
      }),
    );
    assert.equal(p1.ok, true);
    assert.equal(p1.totalLines, 1500);
    assert.equal(p1.returned, 200);
    assert.equal(p1.offset, 0);
    assert.equal(p1.truncated, true);
    assert.ok(p1.content.includes("Line 1"));
    assert.ok(p1.content.includes("Line 200"));
    assert.ok(!p1.content.includes("Line 201"));
    // Page 2: lines 200-399.
    const p2 = payload(
      await client.callTool({
        name: "squad_report_read",
        arguments: { taskId: "big-report", offset: 200, limit: 200 },
      }),
    );
    assert.equal(p2.offset, 200);
    assert.equal(p2.returned, 200);
    assert.ok(p2.content.includes("Line 201"));
    assert.ok(!p2.content.includes("Line 1"));
    // Last page: lines 1400-1499.
    const pLast = payload(
      await client.callTool({
        name: "squad_report_read",
        arguments: { taskId: "big-report", offset: 1400, limit: 200 },
      }),
    );
    assert.equal(pLast.returned, 100);
    assert.equal(pLast.truncated, false);
    assert.ok(pLast.content.includes("Line 1500"));
    // Section index.
    const idx = payload(
      await client.callTool({
        name: "squad_report_read",
        arguments: { taskId: "big-report", section: "index" },
      }),
    );
    assert.equal(idx.totalLines, 1500);
    // No headers in this report.
    assert.equal(idx.sections.length, 0);
  } finally {
    await transport.close();
  }
});

test("squad_report_read returns TASK_NOT_FOUND for missing report", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const result = payload(
      await client.callTool({
        name: "squad_report_read",
        arguments: { taskId: "nonexistent" },
      }),
    );
    assert.equal(result.code, "TASK_NOT_FOUND");
  } finally {
    await transport.close();
  }
});

test("squad_history returns done items from backlog", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  const dataDir = join(base, "data");
  await mkdir(dataDir);
  await writeFile(
    join(dataDir, "backlog.md"),
    "- [x] my-task - Fix the thing https://github.com/test/repo/pull/1 (repo: test) (kind: strike) (done 2026-09-01)\n- [ ] other-task - In progress\n",
  );
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    const result = payload(
      await client.callTool({ name: "squad_history", arguments: {} }),
    );
    assert.equal(result.ok, true);
    assert.equal(result.count, 1);
    assert.equal(result.items[0].taskId, "my-task");
    assert.equal(result.items[0].date, "2026-09-01");
    assert.equal(result.items[0].prUrl, "https://github.com/test/repo/pull/1");
    assert.equal(result.items[0].kind, "strike");
  } finally {
    await transport.close();
  }
});

test("squad_decisions returns pending by default, resolved with flag", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  const stateDir = join(base, "state");
  await mkdir(join(base, "data"));
  await mkdir(stateDir);
  await writeFile(
    join(stateDir, "task-a.status"),
    "needs-decision [key=design]: Which approach?\nresolved [key=design]: Use approach A\n",
  );
  const { client, transport } = await clientFor(base);
  try {
    // Default: pending only.
    const pending = payload(
      await client.callTool({ name: "squad_decisions", arguments: {} }),
    );
    assert.equal(pending.ok, true);
    assert.equal(pending.count, 0);
    // With resolved.
    const all = payload(
      await client.callTool({
        name: "squad_decisions",
        arguments: { includeResolved: true },
      }),
    );
    assert.equal(all.count, 1);
    assert.equal(all.decisions[0].verb, "resolved");
    assert.equal(all.decisions[0].key, "design");
    assert.ok(all.decisions[0].answer.includes("approach A"));
  } finally {
    await transport.close();
  }
});

test("squad_history bounds output on a large backlog", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  const dataDir = join(base, "data");
  await mkdir(dataDir);
  // Generate 150 done items to exceed any default limit.
  const doneLines = Array.from({ length: 150 }, (_, i) =>
    `- [x] task-${String(i).padStart(3, "0")} - Done item ${i} https://github.com/test/repo/pull/${i + 1} (repo: test) (kind: strike) (done 2026-09-${String((i % 28) + 1).padStart(2, "0")})`,
  );
  await writeFile(join(dataDir, "backlog.md"), doneLines.join("\n"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    // Default limit (20): should return exactly 20 items.
    const defaulted = payload(
      await client.callTool({ name: "squad_history", arguments: {} }),
    );
    assert.equal(defaulted.ok, true);
    assert.equal(defaulted.count, 20);
    // Explicit small limit.
    const limited = payload(
      await client.callTool({
        name: "squad_history",
        arguments: { limit: 5 },
      }),
    );
    assert.equal(limited.count, 5);
    // First and last returned IDs should match the top and bottom of the slice.
    assert.equal(limited.items[0].taskId, "task-000");
    assert.equal(limited.items[4].taskId, "task-004");
    // Cap at max (100).
    const capped = payload(
      await client.callTool({
        name: "squad_history",
        arguments: { limit: 100 },
      }),
    );
    assert.equal(capped.count, 100);
  } finally {
    await transport.close();
  }
});
