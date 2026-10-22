import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";

import { ensureServer, isPortAvailable, resolveServerEntry, shutdownServerOnPort, VERSION } from "../src/cli.js";
import { serve } from "../src/server.js";

const PACKAGE_ROOT = fileURLToPath(new URL("..", import.meta.url));
const HOST = "127.0.0.1";

async function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once("error", reject);
    probe.listen(0, HOST, () => {
      const { port } = /** @type {net.AddressInfo} */ (probe.address());
      probe.close(() => resolve(port));
    });
  });
}

async function health(port) {
  try {
    const response = await fetch(`http://${HOST}:${port}/health`);
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  }
}

async function waitFor(check, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await check();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return null;
}

describe("server entry", () => {
  it("a bundle inside a source checkout spawns itself, not the sibling source bin", () => {
    // The installed CLI can be a dist/cli.mjs built inside the source tree. Spawning the
    // sibling bin/sq-report.js there runs the source server, whose package.json version can
    // differ from the version baked into the bundle, so the CLI never accepts its own child.
    const bundle = path.join(PACKAGE_ROOT, "dist", "cli.mjs");
    assert.equal(resolveServerEntry(pathToFileURL(bundle).href), bundle);
  });

  it("the source module spawns the bin wrapper that runs it", () => {
    const sourceModule = path.join(PACKAGE_ROOT, "src", "cli.js");
    assert.equal(resolveServerEntry(pathToFileURL(sourceModule).href), path.join(PACKAGE_ROOT, "bin", "sq-report.js"));
  });

  it("a bundle in a src directory without a sibling bin still spawns itself", async () => {
    const root = await mkdtemp(path.join(tmpdir(), "sq-report-entry-"));
    try {
      const bundle = path.join(root, "src", "cli.mjs");
      await mkdir(path.dirname(bundle), { recursive: true });
      await writeFile(bundle, "", "utf8");
      assert.equal(resolveServerEntry(pathToFileURL(bundle).href), bundle);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("a source module with no bin wrapper fails loudly instead of spawning a non-program", async () => {
    const root = await mkdtemp(path.join(tmpdir(), "sq-report-entry-"));
    try {
      const sourceModule = path.join(root, "src", "cli.js");
      await mkdir(path.dirname(sourceModule), { recursive: true });
      await writeFile(sourceModule, "", "utf8");
      assert.throws(
        () => resolveServerEntry(pathToFileURL(sourceModule).href),
        (/** @type {any} */ error) => {
          assert.equal(error.code, "SERVER_ERROR");
          assert.match(error.message, /server entry is missing/);
          return true;
        },
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("server lifecycle", () => {
  const savedEnv = {};
  let stateDir;

  before(async () => {
    stateDir = await mkdtemp(path.join(tmpdir(), "sq-report-lifecycle-"));
    for (const key of ["SQ_REPORT_PORT", "SQ_REPORT_STATE_DIR", "SQ_REPORT_HOST"]) savedEnv[key] = process.env[key];
    process.env.SQ_REPORT_STATE_DIR = stateDir;
    delete process.env.SQ_REPORT_HOST;
  });

  after(async () => {
    for (const [key, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    await rm(stateDir, { recursive: true, force: true });
  });

  it("stop frees the port so a second start can bind it right away", async () => {
    const port = await freePort();
    const child = spawn(
      process.execPath,
      [path.join(PACKAGE_ROOT, "bin", "sq-report.js"), "server", "--port", String(port)],
      {
        env: { ...process.env, SQ_REPORT_NO_OPEN: "1" },
        stdio: "ignore",
      },
    );
    const exited = new Promise((resolve) => child.once("exit", resolve));
    try {
      assert.ok(await waitFor(() => health(port)), "spawned server must become healthy");

      const output = await shutdownServerOnPort(port);

      assert.equal(output.server.status, "stopped");
      assert.equal(await isPortAvailable(HOST, port), true, "stop must leave no listener on the port");
      const second = await serve({ port, stateFile: path.join(stateDir, "second.json") });
      await second.close();
    } finally {
      child.kill("SIGKILL");
      await exited;
    }
  });

  it("a server that never becomes healthy is reaped instead of left holding the port", async () => {
    const port = await freePort();
    process.env.SQ_REPORT_PORT = String(port);

    // The real child reports this package's version, so a client requiring another version
    // never accepts it - the same disagreement a stale bundle has with the source server.
    await assert.rejects(ensureServer({ version: "0.0.0-never-matches" }), (/** @type {any} */ error) => {
      assert.equal(error.code, "SERVER_ERROR");
      assert.match(error.message, /did not start/);
      return true;
    });

    assert.equal(await health(port), null, "no server may answer on the port after a failed start");
    assert.equal(await isPortAvailable(HOST, port), true, "a failed start must leave no listener behind");
    assert.equal(await health(port + 1), null, "a failed start must not move on and spawn on the next port");
  });

  it("starts on a clean port, starts again right after stop, and reuses a healthy server", async () => {
    const port = await freePort();
    process.env.SQ_REPORT_PORT = String(port);
    const baseUrl = `http://${HOST}:${port}`;
    try {
      assert.equal(await ensureServer(), baseUrl);
      assert.equal((await health(port))?.version, VERSION);

      assert.equal((await shutdownServerOnPort(port)).server.status, "stopped");
      assert.equal(await ensureServer(), baseUrl);
      assert.equal((await health(port))?.version, VERSION);
    } finally {
      await shutdownServerOnPort(port);
    }

    const running = await serve({ port, stateFile: path.join(stateDir, "reuse.json") });
    try {
      assert.equal(await ensureServer(), baseUrl);
      // Reuse means this in-process server is still the one answering, not a replacement.
      await running.close();
      assert.equal(await health(port), null);
    } finally {
      await running.close();
    }
  });
});
