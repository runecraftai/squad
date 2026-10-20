import { createHash } from "node:crypto";
import { realpath, stat } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { isChordError } from "@earendil-works/chord";
import {
  LocalServiceFailure,
  type ServiceBaseId,
} from "../contracts/local-service.ts";

/** Kernel-lock namespace owned by this service; never the primary `state/.lock`. */
export const SERVICE_LOCK_PREFIX = "squad-tui-service-v1-";

export type CanonicalBase = {
  /** `realpath` of the requested directory; every later path is built from it. */
  readonly path: string;
  /** `sha256(canonicalAbsoluteBase)`, lowercase hex. */
  readonly baseId: ServiceBaseId;
};

export function baseIdFor(canonicalPath: string): ServiceBaseId {
  return createHash("sha256").update(canonicalPath, "utf8").digest("hex");
}

/**
 * Resolve the explicit base once. Two spellings of one directory (a symlink and
 * its target) produce the same canonical path, so they contend for one lock.
 */
export async function canonicalBase(basePath: string): Promise<CanonicalBase> {
  if (!isAbsolute(basePath)) throw new LocalServiceFailure("invalid-base");
  let resolved: string;
  try {
    resolved = await realpath(basePath);
  } catch {
    throw new LocalServiceFailure("invalid-base");
  }
  try {
    const info = await stat(resolved);
    if (!info.isDirectory()) throw new LocalServiceFailure("invalid-base");
  } catch {
    throw new LocalServiceFailure("invalid-base");
  }
  return { path: resolved, baseId: baseIdFor(resolved) };
}

export function serviceLockName(baseId: string): string {
  return `${SERVICE_LOCK_PREFIX}${baseId}`;
}

export type ServiceLock = {
  /** Release kernel ownership. Idempotent; failure is reported, never retried. */
  release(): Promise<void>;
};

/**
 * Take the one-process kernel lock for this canonical base. This proves only
 * that one service owns the base; it grants no primary authority and never
 * touches `state/.lock`. An unavailable lock facility is a startup failure, not
 * a trigger for a PID-file fallback.
 */
export async function acquireServiceLock(baseId: string): Promise<ServiceLock> {
  let release: (() => Promise<void>) | undefined;
  try {
    // Loaded lazily so an unsupported runtime fails as an actionable startup
    // diagnostic instead of a module-load stack trace.
    const { processLock } = await import("@earendil-works/chord/node");
    if (typeof processLock !== "function") {
      throw new LocalServiceFailure("lock-unavailable");
    }
    release = await processLock(serviceLockName(baseId));
  } catch (error) {
    if (error instanceof LocalServiceFailure) throw error;
    if (isChordError(error) && error.code === "unavailable") {
      throw new LocalServiceFailure("service-already-running");
    }
    throw new LocalServiceFailure("lock-unavailable");
  }
  let released = false;
  return {
    async release() {
      if (released) return;
      released = true;
      await release?.();
    },
  };
}
