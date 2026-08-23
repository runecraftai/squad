import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { serve } from "../src/server.js";
import { shouldRestartServer } from "../src/cli.js";

const packageJson = JSON.parse(
  await readFile(new URL("../package.json", import.meta.url), "utf8"),
);
const PACKAGE_VERSION = packageJson.version;

describe("version handshake", () => {
  it("same-version health check reuses the server (no respawn)", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "sq-report-vhs-"));
    const stateFile = path.join(dir, "state.json");
    const server = await serve({ port: 0, stateFile });
    try {
      const res = await fetch(
        `http://127.0.0.1:${server.port}/health`,
      );
      const health = await res.json();

      assert.equal(health.ok, true);
      assert.equal(health.version, PACKAGE_VERSION);
      assert.equal(
        shouldRestartServer(PACKAGE_VERSION, health),
        false,
        "same-version health must not trigger restart",
      );
    } finally {
      await server.close();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("mismatched version triggers the restart path", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "sq-report-vhs-"));
    const stateFile = path.join(dir, "state.json");
    const server = await serve({ port: 0, stateFile });
    try {
      const res = await fetch(
        `http://127.0.0.1:${server.port}/health`,
      );
      const health = await res.json();

      // Simulate a client bumped to a newer version than the running server.
      const newerVersion = "999.0.0";
      assert.notEqual(health.version, newerVersion);
      assert.equal(
        shouldRestartServer(newerVersion, health),
        true,
        "mismatched version must trigger restart",
      );
    } finally {
      await server.close();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("server always reports the package.json version (not a stale build constant)", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "sq-report-vhs-"));
    const stateFile = path.join(dir, "state.json");
    // Call serve() without passing version - it must read from package.json.
    const server = await serve({ port: 0, stateFile });
    try {
      const res = await fetch(
        `http://127.0.0.1:${server.port}/health`,
      );
      const health = await res.json();

      assert.equal(health.ok, true);
      assert.equal(
        health.version,
        PACKAGE_VERSION,
        "server must report package.json version, not a build-time constant",
      );
    } finally {
      await server.close();
      await rm(dir, { recursive: true, force: true });
    }
  });
});
