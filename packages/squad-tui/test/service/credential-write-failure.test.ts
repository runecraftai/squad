import { readFile } from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import type { Mode, PathLike } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { credentialPath, ensureToken } from "../../src/service/credentials";
import { removeBase, temporaryBase } from "./fixtures";

const state = vi.hoisted(() => ({ failNextWrite: false }));

/**
 * Fail the first write that follows a successful exclusive create, the way a
 * full disk or a failing sync does. Only that one descriptor is affected.
 */
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    open: async (
      path: PathLike,
      flags: string | number,
      mode?: Mode,
    ): Promise<FileHandle> => {
      const handle = await actual.open(path, flags, mode);
      if (!state.failNextWrite) return handle;
      state.failNextWrite = false;
      return new Proxy(handle, {
        get(target, property, receiver) {
          if (property === "write") {
            return async (): Promise<never> => {
              const error = new Error("no space left on device");
              Object.assign(error, { code: "ENOSPC" });
              throw error;
            };
          }
          const value = Reflect.get(target, property, receiver);
          return typeof value === "function" ? value.bind(target) : value;
        },
      }) as FileHandle;
    },
  };
});

describe("local service credential writes", () => {
  it("removes its own partial credential when the write fails", async () => {
    const base = await temporaryBase();
    try {
      state.failNextWrite = true;
      await expect(ensureToken(base)).rejects.toMatchObject({
        code: "unsafe-credential",
      });
      await expect(readFile(credentialPath(base), "utf8")).rejects.toThrow();

      // The next start creates a usable token instead of refusing forever.
      const token = await ensureToken(base);
      expect(token).toMatch(/^[0-9a-f]{64}$/);
      expect(await readFile(credentialPath(base), "utf8")).toBe(`${token}\n`);
    } finally {
      state.failNextWrite = false;
      await removeBase(base);
    }
  });
});
