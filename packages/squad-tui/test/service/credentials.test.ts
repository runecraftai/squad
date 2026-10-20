import { link, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { LocalServiceFailure } from "../../src/contracts/local-service";
import {
  credentialPath,
  descriptorPath,
  ensurePrivateDirectory,
  ensureToken,
  readDescriptor,
  readToken,
  rotateToken,
  verifyToken,
} from "../../src/service/credentials";
import {
  cleanEnv,
  credentialText,
  descriptorText,
  fileMode,
  nodeBinary,
  removeBase,
  SERVICE_ENTRY,
  startServiceProcess,
  temporaryBase,
} from "./fixtures";
import { spawnSync } from "node:child_process";

async function failureCode(
  operation: Promise<unknown>,
): Promise<string | undefined> {
  try {
    await operation;
    return undefined;
  } catch (error) {
    return error instanceof LocalServiceFailure ? error.code : "not-a-failure";
  }
}

async function writeTokenFile(base: string, contents: string): Promise<string> {
  await ensurePrivateDirectory(base, "config/squad-tui");
  const path = credentialPath(base);
  await writeFile(path, contents, { mode: 0o600 });
  return path;
}

async function tokenFile(
  base: string,
): Promise<{ text: string; mode: number }> {
  return {
    text: await readFile(credentialPath(base), "utf8"),
    mode: await fileMode(credentialPath(base)),
  };
}

describe("local service credentials", () => {
  it("creates one random owner-only token and reuses it on the next start", async () => {
    const base = await temporaryBase();
    try {
      const first = await ensureToken(base);
      expect(first).toMatch(/^[0-9a-f]{64}$/);
      expect(await fileMode(join(base, "config/squad-tui"))).toBe(0o700);
      expect(await fileMode(credentialPath(base))).toBe(0o600);
      expect((await tokenFile(base)).text).toBe(`${first}\n`);
      const second = await ensureToken(base);
      expect(second).toBe(first);
      expect((await tokenFile(base)).text).toBe(`${first}\n`);
    } finally {
      await removeBase(base);
    }
  });

  it("refuses a symlinked credential instead of following it", async () => {
    const base = await temporaryBase();
    try {
      const target = join(base, "outside-token");
      await writeFile(target, `${"a".repeat(64)}\n`, { mode: 0o600 });
      await ensurePrivateDirectory(base, "config/squad-tui");
      await symlink(target, credentialPath(base));
      expect(await failureCode(readToken(base))).toBe("unsafe-credential");
      expect(await failureCode(ensureToken(base))).toBe("unsafe-credential");
      expect(await readFile(target, "utf8")).toBe(`${"a".repeat(64)}\n`);
    } finally {
      await removeBase(base);
    }
  });

  it("refuses a hard-linked credential and leaves it untouched", async () => {
    const base = await temporaryBase();
    try {
      const original = `${"b".repeat(64)}\n`;
      await writeTokenFile(base, original);
      await link(credentialPath(base), join(base, "state", "token-copy"));
      expect(await failureCode(readToken(base))).toBe("unsafe-credential");
      expect(await readFile(credentialPath(base), "utf8")).toBe(original);
    } finally {
      await removeBase(base);
    }
  });

  it("refuses a wrong mode and a wrong-owner-shaped directory without fixing them", async () => {
    const base = await temporaryBase();
    try {
      await writeTokenFile(base, `${"c".repeat(64)}\n`);
      const { chmod } = await import("node:fs/promises");
      await chmod(credentialPath(base), 0o644);
      expect(await failureCode(readToken(base))).toBe("unsafe-credential");
      expect(await fileMode(credentialPath(base))).toBe(0o644);

      const other = await temporaryBase();
      try {
        await mkdir(join(other, "config/squad-tui"), {
          recursive: true,
          mode: 0o755,
        });
        expect(
          await failureCode(ensurePrivateDirectory(other, "config/squad-tui")),
        ).toBe("unsafe-credential");
        expect(await fileMode(join(other, "config/squad-tui"))).toBe(0o755);
      } finally {
        await removeBase(other);
      }
    } finally {
      await removeBase(base);
    }
  });

  it("refuses malformed or oversized tokens without regenerating them", async () => {
    const cases = [
      `${"d".repeat(63)}\n`,
      `${"d".repeat(64)}`,
      `${"D".repeat(64)}\n`,
      `${"d".repeat(64)}\n\n`,
      `${"z".repeat(64)}\n`,
    ];
    for (const contents of cases) {
      const base = await temporaryBase();
      try {
        await writeTokenFile(base, contents);
        expect(await failureCode(readToken(base))).toBe(
          "credential-unreadable",
        );
        expect(await failureCode(ensureToken(base))).toBe(
          "credential-unreadable",
        );
        expect(await readFile(credentialPath(base), "utf8")).toBe(contents);
      } finally {
        await removeBase(base);
      }
    }
  });

  it("rotates offline to a fresh token that invalidates the old one", async () => {
    const base = await temporaryBase();
    try {
      const before = await ensureToken(base);
      const path = await rotateToken(base);
      expect(path).toBe(credentialPath(base));
      const after = await readToken(base);
      expect(after).not.toBe(before);
      expect(after).toMatch(/^[0-9a-f]{64}$/);
      expect(await fileMode(path)).toBe(0o600);
      expect(verifyToken(after, before)).toBe(false);
      expect(verifyToken(after, after)).toBe(true);
      expect(verifyToken(after, `${"0".repeat(64)}`)).toBe(false);
      expect(verifyToken(after, "not-a-token")).toBe(false);
    } finally {
      await removeBase(base);
    }
  });

  it("refuses rotation while a service owner holds the lock, changing nothing", async () => {
    const base = await temporaryBase();
    try {
      const running = await startServiceProcess({ base });
      try {
        const before = await tokenFile(base);
        const env = cleanEnv();
        const child = spawnSync(
          nodeBinary(),
          [SERVICE_ENTRY, "rotate-credential", "--base", base],
          { env, encoding: "utf8", timeout: 30_000 },
        );
        expect(child.status).not.toBe(0);
        expect(child.stderr).toContain("service-already-running");
        expect(await tokenFile(base)).toEqual(before);
        expect(await readToken(base)).toBe(running.token);
      } finally {
        await running.stop();
      }

      const rotated = spawnSync(
        nodeBinary(),
        [SERVICE_ENTRY, "rotate-credential", "--base", base],
        { env: cleanEnv(), encoding: "utf8", timeout: 30_000 },
      );
      expect(rotated.status).toBe(0);
      expect(rotated.stdout).toContain(credentialPath(base));
      expect(await readToken(base)).not.toBe(running.token);
    } finally {
      await removeBase(base);
    }
  });

  it("never prints the token and keeps it out of the descriptor", async () => {
    const base = await temporaryBase();
    try {
      const running = await startServiceProcess({ base });
      try {
        const token = running.token;
        expect(running.readyLine).not.toContain(token);
        expect(running.stdout()).not.toContain(token);
        expect(running.stderr()).not.toContain(token);
        const descriptor = await descriptorText(base);
        expect(descriptor).not.toContain(token);
        expect(Object.keys(JSON.parse(descriptor)).sort()).toEqual([
          "baseId",
          "pid",
          "port",
          "schemaVersion",
          "serviceInstanceId",
          "startedAt",
        ]);
        expect(await credentialText(base)).toBe(`${token}\n`);
        expect((await readDescriptor(base)).serviceInstanceId).toBe(
          running.serviceInstanceId,
        );
        expect(await fileMode(descriptorPath(base))).toBe(0o600);
      } finally {
        await running.stop();
      }
    } finally {
      await removeBase(base);
    }
  });

  it("keeps two bases' tokens independent", async () => {
    const first = await temporaryBase();
    const second = await temporaryBase();
    try {
      const firstToken = await ensureToken(first);
      const secondToken = await ensureToken(second);
      expect(firstToken).not.toBe(secondToken);
      expect(verifyToken(await readToken(first), secondToken)).toBe(false);
    } finally {
      await removeBase(first);
      await removeBase(second);
    }
  });
});
