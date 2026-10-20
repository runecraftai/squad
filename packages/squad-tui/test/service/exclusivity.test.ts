import { spawn } from "node:child_process";
import { mkdir, readFile, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  cleanEnv,
  credentialText,
  descriptorText,
  nodeBinary,
  readTokenFile,
  removeBase,
  SERVICE_ENTRY,
  startServiceProcess,
  temporaryBase,
} from "./fixtures";
import { baseIdFor, canonicalBase } from "../../src/service/exclusivity";
import { credentialPath, descriptorPath } from "../../src/service/credentials";

type StartOutcome = {
  readonly ready: boolean;
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
};

type StartHandle = {
  readonly outcome: Promise<StartOutcome>;
  readonly child: ReturnType<typeof spawn>;
};

/**
 * Start one service CLI process and wait for readiness or exit. With
 * `keepAlive` a ready owner keeps running until the test stops it, so a
 * readiness kill cannot hand the lock to a second racer.
 */
function startOnce(
  base: string,
  options: { keepAlive?: boolean } = {},
): StartHandle {
  let child: ReturnType<typeof spawn>;
  const outcome = new Promise<StartOutcome>((resolve) => {
    child = spawn(nodeBinary(), [SERVICE_ENTRY, "serve", "--base", base], {
      env: cleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (ready: boolean, code: number | null): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (ready && options.keepAlive !== true) child.kill("SIGTERM");
      resolve({ ready, code, stdout, stderr });
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(false, null);
    }, 30_000);
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
      if (stdout.includes("ready: loopback ")) finish(true, null);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("exit", (code) => finish(false, code));
  });
  return { outcome, child: child! };
}

const readyIn = (handle: StartHandle): Promise<StartOutcome> => handle.outcome;

describe("local service exclusivity", () => {
  it("derives one identity per canonical base, including symlink aliases", async () => {
    const base = await temporaryBase();
    try {
      const canonical = await canonicalBase(base);
      expect(canonical.baseId).toBe(baseIdFor(canonical.path));
      expect(canonical.baseId).toMatch(/^[0-9a-f]{64}$/);
      const alias = join(base, "..", `${base.split("/").pop()}-alias`);
      await symlink(base, alias);
      try {
        const aliased = await canonicalBase(alias);
        expect(aliased.path).toBe(canonical.path);
        expect(aliased.baseId).toBe(canonical.baseId);
      } finally {
        const { unlink } = await import("node:fs/promises");
        await unlink(alias);
      }
    } finally {
      await removeBase(base);
    }
  });

  it("lets exactly one of three concurrent starts own the base", async () => {
    const base = await temporaryBase();
    try {
      // A prior run leaves a token behind: losers must not rewrite it.
      const seeded = await startServiceProcess({ base });
      const seededToken = await credentialText(base);
      await seeded.stop();

      const handles = [
        startOnce(base, { keepAlive: true }),
        startOnce(base, { keepAlive: true }),
        startOnce(base, { keepAlive: true }),
      ];
      const outcomes = await Promise.all(handles.map(readyIn));
      const winners = outcomes.filter((outcome) => outcome.ready);
      const losers = outcomes.filter((outcome) => !outcome.ready);
      expect(winners).toHaveLength(1);
      expect(losers).toHaveLength(2);
      for (const loser of losers) {
        expect(loser.code).not.toBe(0);
        expect(loser.stderr).toContain("error: service-already-running");
        expect(loser.stdout).not.toContain("ready: loopback ");
      }
      const winnerIndex = outcomes.findIndex((outcome) => outcome.ready);
      handles[winnerIndex]?.child.kill("SIGTERM");
      expect(await credentialText(base)).toBe(seededToken);
      const descriptor = JSON.parse(await descriptorText(base)) as {
        pid: number;
      };
      expect(typeof descriptor.pid).toBe("number");
    } finally {
      await removeBase(base);
    }
  }, 90_000);

  it("makes a symlink alias contend for the same lock", async () => {
    const base = await temporaryBase();
    const alias = join(base, "..", `${base.split("/").pop()}-alias`);
    try {
      await symlink(base, alias);
      const running = await startServiceProcess({ base });
      const second = await startOnce(alias).outcome;
      expect(second.ready).toBe(false);
      expect(second.stderr).toContain("service-already-running");
      expect((await readTokenFile(base)).length).toBe(64);
      await running.stop();
    } finally {
      const { unlink } = await import("node:fs/promises");
      await unlink(alias).catch(() => undefined);
      await removeBase(base);
    }
  }, 60_000);

  it("runs independent bases independently", async () => {
    const first = await temporaryBase();
    const second = await temporaryBase();
    try {
      const [one, two] = await Promise.all([
        startServiceProcess({ base: first }),
        startServiceProcess({ base: second }),
      ]);
      try {
        expect(one.port).not.toBe(two.port);
        expect(one.baseId).not.toBe(two.baseId);
        expect(one.readyLine).not.toBe(two.readyLine);
      } finally {
        await one.stop();
        await two.stop();
      }
    } finally {
      await removeBase(first);
      await removeBase(second);
    }
  }, 60_000);

  it("releases the lock when the owner crashes, allowing a later start", async () => {
    const base = await temporaryBase();
    try {
      const crashed = await startServiceProcess({ base });
      const crashedId = crashed.serviceInstanceId;
      await crashed.stop("SIGKILL");
      // The stale descriptor survives the crash; it must not be signalled.
      const stale = JSON.parse(await descriptorText(base)) as {
        serviceInstanceId: string;
        pid: number;
      };
      expect(stale.serviceInstanceId).toBe(crashedId);
      expect(stale.pid).toBe(crashed.pid);

      const replacement = await startServiceProcess({ base });
      try {
        expect(replacement.serviceInstanceId).not.toBe(crashedId);
        const current = JSON.parse(await descriptorText(base)) as {
          serviceInstanceId: string;
        };
        expect(current.serviceInstanceId).toBe(replacement.serviceInstanceId);
      } finally {
        await replacement.stop();
      }
    } finally {
      await removeBase(base);
    }
  }, 60_000);

  it("never reads, writes or removes the primary state/.lock", async () => {
    const base = await temporaryBase();
    const primaryLock = join(base, "state", ".lock");
    const contents = "primary-owner:pid-4242\n";
    try {
      await writeFile(primaryLock, contents, { mode: 0o600 });
      const before = await stat(primaryLock);

      const running = await startServiceProcess({ base });
      const descriptorBeforeStop = await readFile(descriptorPath(base), "utf8");
      const alias = join(base, "..", `${base.split("/").pop()}-lock-alias`);
      await symlink(base, alias);
      try {
        const second = await startOnce(alias).outcome;
        expect(second.ready).toBe(false);
        await running.stop();
      } finally {
        const { unlink } = await import("node:fs/promises");
        await unlink(alias).catch(() => undefined);
      }

      const after = await stat(primaryLock);
      expect(await readFile(primaryLock, "utf8")).toBe(contents);
      expect(after.mode).toBe(before.mode);
      expect(after.uid).toBe(before.uid);
      expect(after.ino).toBe(before.ino);
      expect(after.mtimeMs).toBe(before.mtimeMs);
      expect(await readFile(credentialPath(base), "utf8")).toMatch(
        /^[0-9a-f]{64}\n$/,
      );
      expect(descriptorBeforeStop).toContain(running.serviceInstanceId);
    } finally {
      await removeBase(base);
    }
  }, 90_000);

  it("reports a base that does not exist instead of creating it", async () => {
    const base = join("/tmp", `squad-tui-missing-${Date.now()}`);
    const outcome = await startOnce(base).outcome;
    expect(outcome.ready).toBe(false);
    expect(outcome.stderr).toContain("error: invalid-base");
    await expect(mkdir(base)).resolves.toBeUndefined();
    await removeBase(base);
  });
});
