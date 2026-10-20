import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  FIXTURES_PATH,
  nodeBinary,
  PACKAGE_ROOT,
  removeBase,
  runNode,
  runUnderBun,
  SERVICE_ENTRY,
  temporaryBase,
} from "./fixtures";

const packageJson = JSON.parse(
  readFileSync(join(PACKAGE_ROOT, "package.json"), "utf8"),
) as {
  dependencies: Record<string, string>;
  devDependencies: Record<string, string>;
};

function records(text: string): Array<Record<string, unknown>> {
  return text
    .split("\n")
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

describe("T07 service runtime compatibility", () => {
  it("pins the approved dependency set exactly", () => {
    expect(packageJson.dependencies["@earendil-works/chord"]).toBe("1.3.0");
    expect(packageJson.dependencies.typebox).toBe("1.3.27");
    expect(packageJson.dependencies.ws).toBe("8.18.3");
    expect(packageJson.devDependencies["@types/ws"]).toBe("8.18.1");
    expect(packageJson.dependencies.zod).toBe("4.6.5");
  });

  it("refuses to serve on Bun, the package toolchain runtime", async () => {
    const base = await temporaryBase();
    try {
      const child = await runUnderBun([SERVICE_ENTRY, "serve", "--base", base]);
      expect(child.code).not.toBe(0);
      expect(child.stderr).toContain("error: unsupported-runtime:");
      expect(child.stdout).not.toContain("ready: loopback ");
    } finally {
      await removeBase(base);
    }
  }, 60_000);

  it("loads Chord, serves it over node:http + ws, and refuses a second kernel-lock owner", async () => {
    const version = await runNode([
      "-e",
      "process.stdout.write(process.versions.node)",
    ]);
    expect(version.code).toBe(0);
    const [major, minor] = version.stdout.split(".").map(Number);
    expect(major >= 22 && (major > 22 || minor >= 19)).toBe(true);

    const probe = await runNode([FIXTURES_PATH, "compatibility"], {
      timeoutMs: 120_000,
    });
    expect(probe.stderr).toBe("");
    expect(probe.code).toBe(0);
    const parsed = records(probe.stdout);
    const upgrade = parsed.find((entry) => entry.kind === "upgrade");
    expect(upgrade).toEqual({
      kind: "upgrade",
      status: "HTTP/1.1 101 Switching Protocols",
      negotiatedExtensions: false,
    });

    const client = parsed.find((entry) => entry.kind === "client");
    expect(client?.code).toBe(0);
    const clientStdout = client?.stdout;
    expect(Array.isArray(clientStdout)).toBe(true);
    const clientLines = Array.isArray(clientStdout)
      ? clientStdout.map((line) => String(line))
      : [];
    const clientRecords = records(clientLines.join("\n"));
    expect(clientRecords[0]).toMatchObject({
      kind: "extract",
      readiness: "ready",
      capabilities: true,
    });
    expect(parsed.some((entry) => entry.kind === "binary-frames")).toBe(false);

    const oversized = parsed.find((entry) => entry.kind === "oversized");
    expect(oversized?.outcome).toBe("close-1009");

    const lock = parsed.find((entry) => entry.kind === "lock");
    expect(lock?.contender).toContain('"outcome":"refused"');
    expect(lock?.contender).toContain('"code":"service-already-running"');
  }, 150_000);

  it("resolves a real Node runtime, never Bun's node shim", () => {
    const binary = nodeBinary();
    expect(binary.endsWith("/node")).toBe(true);
    expect(binary.includes("/bun-node-")).toBe(false);
  });
});
