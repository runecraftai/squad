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
