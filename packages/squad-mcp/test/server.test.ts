import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = join(import.meta.dirname, "..", "..", "..");
async function clientFor(base: string) {
  const transport = new StdioClientTransport({ command: process.execPath, args: [join(root, "packages/squad-mcp/dist/bin/squad-mcp.js")], cwd: root, env: { ...process.env, SQUAD_ROOT: root, SQUAD_BASE: base } });
  const client = new Client({ name: "squad-mcp-test", version: "1" });
  await client.connect(transport);
  return { client, transport };
}
function payload(result: any): any { return JSON.parse(result.content[0].text); }

test("stdio startup discovers exactly the V1 tools", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try { assert.deepEqual((await client.listTools()).tools.map((tool) => tool.name), ["squad_start", "squad_status", "squad_stop"]); } finally { await transport.close(); }
});

test("repository allowlisting and malformed task IDs are typed", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  const { client, transport } = await clientFor(base);
  try {
    assert.equal(payload(await client.callTool({ name: "squad_start", arguments: { project: "/etc", objective: "x" } })).code, "PROJECT_NOT_ALLOWED");
    assert.equal(payload(await client.callTool({ name: "squad_status", arguments: { taskId: "../secret" } })).code, "INVALID_INPUT");
  } finally { await transport.close(); }
});

test("status and safe stop recover from durable records after a new process", async () => {
  const base = await mkdtemp(join(tmpdir(), "squad-mcp-"));
  await mkdir(join(base, "data"));
  await mkdir(join(base, "state"));
  await writeFile(join(base, "state", "task-123.meta"), "worktree=/missing\nkind=strike\n");
  const first = await clientFor(base);
  try { assert.equal(payload(await first.client.callTool({ name: "squad_status", arguments: { taskId: "task-123" } })).state, "unknown"); } finally { await first.transport.close(); }
  const second = await clientFor(base);
  try { assert.equal(payload(await second.client.callTool({ name: "squad_stop", arguments: { taskId: "task-123" } })).code, "STOP_REFUSED"); } finally { await second.transport.close(); }
});
