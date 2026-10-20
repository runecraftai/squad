import { createServer } from "node:net";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  FIXTURES_PATH,
  readDescriptor,
  readTokenFile,
  removeBase,
  runClientProcess,
  runCliService,
  runNode,
  startServiceProcess,
  temporaryBase,
} from "./fixtures";

async function expectNoReadiness(stdout: string): Promise<void> {
  expect(stdout).not.toContain("ready: loopback ");
}

describe("local service lifecycle", () => {
  it("fails each enumerated startup case with a fixed, secret-free diagnostic", async () => {
    const base = await temporaryBase();
    try {
      const missing = await runCliService(["serve"]);
      expect(missing.code).toBe(2);
      expect(missing.stderr).toContain("error: usage:");
      await expectNoReadiness(missing.stdout);

      const relative = await runCliService([
        "serve",
        "--base",
        "relative/base",
      ]);
      expect(relative.code).toBe(1);
      expect(relative.stderr).toContain("error: invalid-base:");
      await expectNoReadiness(relative.stdout);

      const absent = await runCliService([
        "serve",
        "--base",
        join(base, "does-not-exist"),
      ]);
      expect(absent.code).toBe(1);
      expect(absent.stderr).toContain("error: invalid-base:");
      await expectNoReadiness(absent.stdout);

      const conflicting = await runCliService(["serve", "--base", base], {
        env: { SQUAD_BASE: "/tmp" },
      });
      expect(conflicting.code).toBe(1);
      expect(conflicting.stderr).toContain("error: base-mismatch:");
      await expectNoReadiness(conflicting.stdout);

      const invalidPort = await runCliService([
        "serve",
        "--base",
        base,
        "--port",
        "70000",
      ]);
      expect(invalidPort.code).toBe(1);
      expect(invalidPort.stderr).toContain("error: invalid-port:");
      await expectNoReadiness(invalidPort.stdout);

      const oldRuntime = await runNode([FIXTURES_PATH, "runtime-guard", base], {
        timeoutMs: 30_000,
      });
      expect(oldRuntime.code).toBe(0);
      expect(JSON.parse(oldRuntime.stdout.trim())).toEqual({
        kind: "runtime-guard",
        code: 1,
      });
      expect(oldRuntime.stderr).toContain("error: unsupported-runtime:");
      await expectNoReadiness(oldRuntime.stdout);

      const occupied = createServer();
      await new Promise<void>((resolve) =>
        occupied.listen(0, "127.0.0.1", () => resolve()),
      );
      try {
        const address = occupied.address();
        const port =
          typeof address === "object" && address !== null ? address.port : 0;
        const inUse = await runCliService([
          "serve",
          "--base",
          base,
          "--port",
          String(port),
        ]);
        expect(inUse.code).toBe(1);
        expect(inUse.stderr).toContain("error: listen-failed:");
        await expectNoReadiness(inUse.stdout);
      } finally {
        await new Promise<void>((resolve) => occupied.close(() => resolve()));
      }
    } finally {
      await removeBase(base);
    }
  }, 120_000);

  it("fails descriptor publication with no readiness and no descriptor", async () => {
    const base = await temporaryBase();
    try {
      await mkdir(join(base, "state"), { recursive: true });
      await writeFile(join(base, "state", "squad-tui"), "not a directory", {
        mode: 0o600,
      });
      const outcome = await runCliService(["serve", "--base", base]);
      expect(outcome.code).toBe(1);
      expect(outcome.stderr).toContain("error: descriptor-failed:");
      await expectNoReadiness(outcome.stdout);
      expect(outcome.stdout).not.toContain(base);
      await expect(readDescriptor(base)).rejects.toThrow();
      // The credential was created before publication and is left as-is; the
      // running process released its lock on exit.
      expect((await readTokenFile(base)).length).toBe(64);
    } finally {
      await removeBase(base);
    }
  }, 60_000);

  it("attaches two and then three concurrent clients to one service", async () => {
    const base = await temporaryBase();
    const service = await startServiceProcess({ base });
    try {
      const [first, second] = await Promise.all([
        runClientProcess(base, { mode: "attach", durationMs: 1_200 }),
        runClientProcess(base, { mode: "attach", durationMs: 1_200 }),
      ]);
      expect(first.code).toBe(0);
      expect(second.code).toBe(0);
      for (const run of [first, second]) {
        expect(run.records[0]).toMatchObject({ kind: "attached" });
        expect(run.records.some((entry) => entry.kind === "event-snap")).toBe(
          true,
        );
      }

      const [third, fourth] = await Promise.all([
        runClientProcess(base, { mode: "attach", durationMs: 1_000 }),
        runClientProcess(base, { mode: "attach", durationMs: 1_000 }),
      ]);
      expect(third.code).toBe(0);
      expect(fourth.code).toBe(0);
      expect(third.records[0]).toMatchObject({ kind: "attached" });
      expect(fourth.records.some((entry) => entry.kind === "event-snap")).toBe(
        true,
      );
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 90_000);

  it("keeps the service and other clients alive when one client leaves", async () => {
    const base = await temporaryBase();
    const service = await startServiceProcess({
      base,
      source: "scripted",
      revisions: 8,
      intervalMs: 200,
      startDelayMs: 350,
    });
    try {
      const descriptorBefore = await readDescriptor(base);
      const [leaving, staying] = await Promise.all([
        runClientProcess(base, { mode: "attach", durationMs: 400 }),
        runClientProcess(base, { mode: "attach", durationMs: 2_000 }),
      ]);
      expect(leaving.code).toBe(0);
      expect(staying.code).toBe(0);
      const kinds = staying.records.map((entry) => entry.kind);
      expect(kinds).toContain("event-snap");
      expect(
        kinds.some((kind) => kind === "event-ops" || kind === "event-reset"),
      ).toBe(true);

      // The service is still ready and a new client still gets a snapshot.
      expect(await readDescriptor(base)).toEqual(descriptorBefore);
      const later = await runClientProcess(base, {
        mode: "attach",
        durationMs: 500,
      });
      expect(later.code).toBe(0);
      expect(later.records[0]).toMatchObject({ kind: "attached" });
      expect(later.records.some((entry) => entry.kind === "event-snap")).toBe(
        true,
      );
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 90_000);

  it("survives every client leaving and serves a fresh snapshot afterwards", async () => {
    const base = await temporaryBase();
    const service = await startServiceProcess({ base });
    try {
      const first = await runClientProcess(base, {
        mode: "attach",
        durationMs: 300,
      });
      expect(first.code).toBe(0);
      const second = await runClientProcess(base, {
        mode: "attach",
        durationMs: 300,
      });
      expect(second.code).toBe(0);
      expect(second.records.some((entry) => entry.kind === "event-snap")).toBe(
        true,
      );
      expect(service.child.exitCode).toBeNull();
      expect(service.readyLine).toContain("ready: loopback ");
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 60_000);

  it("restarts with a new identity and a fresh snapshot after the owner stops", async () => {
    const base = await temporaryBase();
    try {
      const first = await startServiceProcess({ base });
      const firstId = first.serviceInstanceId;
      const token = await readTokenFile(base);
      await first.stop();

      const second = await startServiceProcess({ base });
      try {
        expect(second.serviceInstanceId).not.toBe(firstId);
        expect(second.port).not.toBe(first.port);
        expect(await readTokenFile(base)).toBe(token);
        const descriptor = await readDescriptor(base);
        expect(descriptor.serviceInstanceId).toBe(second.serviceInstanceId);

        const client = await runClientProcess(base, {
          mode: "attach",
          durationMs: 400,
        });
        expect(client.code).toBe(0);
        expect(client.records[0]).toMatchObject({ kind: "attached" });
        const snap = client.records.find(
          (entry) => entry.kind === "event-snap",
        );
        expect(snap).toBeDefined();
      } finally {
        await second.stop();
      }
      // A clean stop removes only its own descriptor.
      await expect(readDescriptor(base)).rejects.toThrow();
    } finally {
      await removeBase(base);
    }
  }, 90_000);

  it("keeps a clean, token-free terminal surface", async () => {
    const base = await temporaryBase();
    const service = await startServiceProcess({ base });
    try {
      expect(service.stderr()).toBe("");
      expect(service.readyLine).not.toContain(service.token);
      expect(service.stdout()).not.toContain(service.token);
      const descriptor = await readDescriptor(base);
      expect(descriptor.baseId).toBe(service.baseId);
      expect(descriptor.pid).toBe(service.pid);
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 60_000);

  it("rejects a base environment that points somewhere else for rotation too", async () => {
    const base = await temporaryBase();
    try {
      const outcome = await runCliService(
        ["rotate-credential", "--base", base],
        { env: { SQUAD_BASE: "/tmp" } },
      );
      expect(outcome.code).toBe(1);
      expect(outcome.stderr).toContain("error: base-mismatch:");
      expect(outcome.stdout).toBe("");
    } finally {
      await removeBase(base);
    }
  });
});
