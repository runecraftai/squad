import { randomBytes, timingSafeEqual } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { lstat, mkdir, open, rename, stat, unlink } from "node:fs/promises";
import { join } from "node:path";
import {
  EndpointDescriptor,
  LOCAL_SERVICE_LIMITS,
  LocalServiceFailure,
  SERVICE_CREDENTIAL_DIRECTORY,
  SERVICE_CREDENTIAL_FILE,
  SERVICE_ENDPOINT_DIRECTORY,
  SERVICE_ENDPOINT_FILE,
  SERVICE_TOKEN_PATTERN,
  type ServiceToken,
} from "../contracts/local-service.ts";

const OWNER_ONLY_DIRECTORY = 0o700;
const OWNER_ONLY_FILE = 0o600;

function ownerUid(): number {
  const uid = process.getuid?.();
  if (uid === undefined) throw new LocalServiceFailure("unsafe-credential");
  return uid;
}

function modeOf(mode: number): number {
  return mode & 0o777;
}

/** Byte size of the JSON the service compares before it accepts an upgrade token. */
export function tokenFileBytes(token: ServiceToken): number {
  return Buffer.byteLength(`${token}\n`, "utf8");
}

function newToken(): ServiceToken {
  return randomBytes(32).toString("hex");
}

async function syncDirectory(directory: string): Promise<void> {
  const handle = await open(directory, fsConstants.O_RDONLY);
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

/**
 * Refuse a preexisting ancestor inside the base that other users could write
 * to. Nothing above the base is inspected: the commander chooses the base.
 */
async function assertSafeBaseAncestors(
  base: string,
  directory: string,
  failure: "unsafe-credential" | "descriptor-failed",
): Promise<void> {
  const relative = directory.slice(base.length).split("/").filter(Boolean);
  let current = base;
  for (const segment of relative) {
    current = join(current, segment);
    try {
      const info = await lstat(current);
      if (info.isSymbolicLink()) throw new LocalServiceFailure(failure);
      if (!info.isDirectory()) throw new LocalServiceFailure(failure);
      if ((info.mode & 0o022) !== 0) throw new LocalServiceFailure(failure);
      if (info.uid !== ownerUid()) throw new LocalServiceFailure(failure);
    } catch (error) {
      if (error instanceof LocalServiceFailure) throw error;
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw new LocalServiceFailure(failure);
    }
  }
}

/**
 * Validate or create an owner-only directory inside the base. A preexisting
 * directory is validated, never chmod'ed or chown'ed.
 */
export async function ensurePrivateDirectory(
  base: string,
  relative: string,
  failure: "unsafe-credential" | "descriptor-failed" = "unsafe-credential",
): Promise<string> {
  const directory = join(base, relative);
  await assertSafeBaseAncestors(base, directory, failure);
  try {
    await mkdir(directory, { recursive: true, mode: OWNER_ONLY_DIRECTORY });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
      throw new LocalServiceFailure(failure);
    }
  }
  let info;
  try {
    info = await lstat(directory);
  } catch {
    throw new LocalServiceFailure(failure);
  }
  if (info.isSymbolicLink() || !info.isDirectory()) {
    throw new LocalServiceFailure(failure);
  }
  if (info.uid !== ownerUid() || modeOf(info.mode) !== OWNER_ONLY_DIRECTORY) {
    throw new LocalServiceFailure(failure);
  }
  return directory;
}

type PrivateFileOptions = {
  readonly base: string;
  readonly relative: string;
  readonly maxBytes: number;
  /** Used for a wrong owner, mode, type or link count. */
  readonly unsafe: "unsafe-credential" | "descriptor-failed";
  /** Used for absent, oversize or unparsable content. */
  readonly unreadable: "credential-unreadable" | "descriptor-failed";
};

/**
 * Read one private file through an opened descriptor: no-follow open, then
 * fstat for type, owner, mode and hard-link count, then a bounded read. The
 * checks apply to the descriptor actually read, not to a preceding `stat`.
 */
async function readPrivateFile(options: PrivateFileOptions): Promise<string> {
  const path = join(options.base, options.relative);
  let handle;
  try {
    handle = await open(path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch (error) {
    if (error instanceof LocalServiceFailure) throw error;
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") throw new LocalServiceFailure(options.unreadable);
    throw new LocalServiceFailure(options.unsafe);
  }
  try {
    const info = await handle.stat();
    if (!info.isFile()) throw new LocalServiceFailure(options.unsafe);
    if (info.uid !== ownerUid()) throw new LocalServiceFailure(options.unsafe);
    if (modeOf(info.mode) !== OWNER_ONLY_FILE) {
      throw new LocalServiceFailure(options.unsafe);
    }
    if (info.nlink !== 1) throw new LocalServiceFailure(options.unsafe);
    if (info.size === 0 || info.size > options.maxBytes) {
      throw new LocalServiceFailure(options.unreadable);
    }
    const buffer = Buffer.alloc(options.maxBytes);
    const { bytesRead } = await handle.read(buffer, 0, options.maxBytes, 0);
    if (bytesRead === 0 || bytesRead > options.maxBytes) {
      throw new LocalServiceFailure(options.unreadable);
    }
    return buffer.subarray(0, bytesRead).toString("utf8");
  } finally {
    await handle.close();
  }
}

function parseToken(text: string): ServiceToken {
  if (!/^[0-9a-f]{64}\n$/.test(text)) {
    throw new LocalServiceFailure("credential-unreadable");
  }
  return text.slice(0, 64);
}

export function credentialPath(base: string): string {
  return join(base, SERVICE_CREDENTIAL_DIRECTORY, SERVICE_CREDENTIAL_FILE);
}

export function descriptorPath(base: string): string {
  return join(base, SERVICE_ENDPOINT_DIRECTORY, SERVICE_ENDPOINT_FILE);
}

/** Read the existing token; absent, malformed or unsafe files all refuse. */
export async function readToken(base: string): Promise<ServiceToken> {
  const text = await readPrivateFile({
    base,
    relative: `${SERVICE_CREDENTIAL_DIRECTORY}/${SERVICE_CREDENTIAL_FILE}`,
    maxBytes: LOCAL_SERVICE_LIMITS.tokenFileBytes,
    unsafe: "unsafe-credential",
    unreadable: "credential-unreadable",
  });
  return parseToken(text);
}

async function tryReadExistingToken(
  base: string,
): Promise<ServiceToken | undefined> {
  try {
    return await readToken(base);
  } catch (error) {
    if (
      error instanceof LocalServiceFailure &&
      error.code === "credential-unreadable"
    ) {
      const info = await lstat(credentialPath(base)).catch(() => undefined);
      if (info === undefined) return undefined;
    }
    throw error;
  }
}

async function writeNewFile(
  path: string,
  contents: string,
  failure: "unsafe-credential" | "descriptor-failed",
): Promise<void> {
  let handle;
  try {
    handle = await open(
      path,
      fsConstants.O_WRONLY |
        fsConstants.O_CREAT |
        fsConstants.O_EXCL |
        fsConstants.O_NOFOLLOW,
      OWNER_ONLY_FILE,
    );
  } catch {
    throw new LocalServiceFailure(failure);
  }
  try {
    await handle.write(contents, 0, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
}

/**
 * Reuse an existing token or create one exclusively. A malformed, unsafe or
 * unreadable preexisting token is never truncated and never regenerated.
 */
export async function ensureToken(base: string): Promise<ServiceToken> {
  await ensurePrivateDirectory(base, SERVICE_CREDENTIAL_DIRECTORY);
  const existing = await tryReadExistingToken(base);
  if (existing !== undefined) return existing;
  const path = credentialPath(base);
  const token = newToken();
  try {
    await writeNewFile(path, `${token}\n`, "unsafe-credential");
  } catch (error) {
    if (
      (error as NodeJS.ErrnoException).code === "EEXIST" ||
      (await lstat(path).catch(() => undefined)) !== undefined
    ) {
      return readToken(base);
    }
    throw error;
  }
  await syncDirectory(join(base, SERVICE_CREDENTIAL_DIRECTORY));
  return parseToken(
    await readPrivateFile({
      base,
      relative: `${SERVICE_CREDENTIAL_DIRECTORY}/${SERVICE_CREDENTIAL_FILE}`,
      maxBytes: LOCAL_SERVICE_LIMITS.tokenFileBytes,
      unsafe: "unsafe-credential",
      unreadable: "credential-unreadable",
    }),
  );
}

/**
 * Offline rotation: publish a new owner-only token by synced temporary file and
 * atomic rename. The caller must already hold the service kernel lock, so a
 * live service can never see its credential replaced underneath it.
 */
export async function rotateToken(base: string): Promise<string> {
  const directory = await ensurePrivateDirectory(
    base,
    SERVICE_CREDENTIAL_DIRECTORY,
  );
  const token = newToken();
  const temporary = join(
    directory,
    `.${SERVICE_CREDENTIAL_FILE}.${randomBytes(8).toString("hex")}.tmp`,
  );
  try {
    await writeNewFile(temporary, `${token}\n`, "unsafe-credential");
    await rename(temporary, credentialPath(base));
    await syncDirectory(directory);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    if (error instanceof LocalServiceFailure) throw error;
    throw new LocalServiceFailure("unsafe-credential");
  }
  await readToken(base);
  return credentialPath(base);
}

/** Constant-time comparison of a well-formed presented token with the expected one. */
export function verifyToken(
  expected: ServiceToken,
  presented: string,
): boolean {
  if (!SERVICE_TOKEN_PATTERN.test(presented)) return false;
  const left = Buffer.from(expected, "utf8");
  const right = Buffer.from(presented, "utf8");
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

/**
 * Publish discovery information atomically. The descriptor never contains a
 * token and is never the exclusivity lock or a claim of primary authority.
 */
export async function publishDescriptor(
  base: string,
  descriptor: EndpointDescriptor,
): Promise<string> {
  const directory = await ensurePrivateDirectory(
    base,
    SERVICE_ENDPOINT_DIRECTORY,
    "descriptor-failed",
  );
  const parsed = EndpointDescriptor.safeParse(descriptor);
  if (!parsed.success) throw new LocalServiceFailure("descriptor-failed");
  const temporary = join(
    directory,
    `.${SERVICE_ENDPOINT_FILE}.${randomBytes(8).toString("hex")}.tmp`,
  );
  try {
    await writeNewFile(
      temporary,
      `${JSON.stringify(parsed.data)}\n`,
      "descriptor-failed",
    );
    await rename(temporary, descriptorPath(base));
    await syncDirectory(directory);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    if (error instanceof LocalServiceFailure) throw error;
    throw new LocalServiceFailure("descriptor-failed");
  }
  return descriptorPath(base);
}

export async function readDescriptor(
  base: string,
): Promise<EndpointDescriptor> {
  const text = await readPrivateFile({
    base,
    relative: `${SERVICE_ENDPOINT_DIRECTORY}/${SERVICE_ENDPOINT_FILE}`,
    maxBytes: LOCAL_SERVICE_LIMITS.descriptorFileBytes,
    unsafe: "descriptor-failed",
    unreadable: "descriptor-failed",
  });
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new LocalServiceFailure("descriptor-failed");
  }
  const parsed = EndpointDescriptor.safeParse(value);
  if (!parsed.success) throw new LocalServiceFailure("descriptor-failed");
  return parsed.data;
}

/** Remove only this instance's descriptor; another instance's file is left alone. */
export async function removeOwnDescriptor(
  base: string,
  serviceInstanceId: string,
): Promise<boolean> {
  try {
    const current = await readDescriptor(base);
    if (current.serviceInstanceId !== serviceInstanceId) return false;
    await unlink(descriptorPath(base));
    await syncDirectory(join(base, SERVICE_ENDPOINT_DIRECTORY));
    return true;
  } catch {
    return false;
  }
}

/** Whether a directory exists at all; used for startup validation only. */
export async function directoryExists(path: string): Promise<boolean> {
  try {
    const info = await stat(path);
    return info.isDirectory();
  } catch {
    return false;
  }
}
