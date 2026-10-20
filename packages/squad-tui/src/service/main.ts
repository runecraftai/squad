import { randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";
import {
  EndpointDescriptor,
  LocalServiceFailure,
  SERVICE_FAILURE_DIAGNOSTICS,
  isLocalServiceFailure,
  type ServiceFailureCode,
} from "../contracts/local-service.ts";
import {
  ensureToken,
  publishDescriptor,
  removeOwnDescriptor,
  rotateToken,
} from "./credentials.ts";
import { acquireServiceLock, canonicalBase } from "./exclusivity.ts";
import {
  attachServiceListener,
  createServiceHost,
  createServiceHttpServer,
  serviceView,
  type ServiceViewState,
} from "./transport.ts";

export const READY_PREFIX = "ready: loopback ";

export type StartServiceOptions = {
  /** Explicit absolute base directory; never derived from the current directory. */
  readonly base: string;
  /** 0 (default) asks the OS for a free port; 1-65535 pins one. */
  readonly port?: number;
  /** Ambient `SQUAD_BASE`, if any, must resolve to the same canonical base. */
  readonly envBase?: string;
  /**
   * Test-only injection: build a replicated source from the service's own
   * initial view. Production starts without one, so the shipped service has no
   * fixture route and no second source of truth.
   */
  readonly viewSource?: (
    initial: ServiceViewState,
  ) => import("@earendil-works/chord").ReplicatedStateSource<ServiceViewState>;
  /** Fixed-line diagnostics only; never receives or forwards secret material. */
  readonly onBackgroundError?: (error: unknown) => void;
};

export type RunningService = {
  readonly baseId: string;
  readonly serviceInstanceId: string;
  readonly port: number;
  readonly descriptorPath: string;
  close(): Promise<void>;
};

function assertSupportedRuntime(): void {
  if (process.versions.bun !== undefined) {
    throw new LocalServiceFailure("unsupported-runtime");
  }
  const version = process.versions.node;
  const [major = 0, minor = 0] = version.split(".").map(Number);
  if (major < 22 || (major === 22 && minor < 19)) {
    throw new LocalServiceFailure("unsupported-runtime");
  }
}

function assertValidPort(port: number): void {
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new LocalServiceFailure("invalid-port");
  }
}

async function sameBase(basePath: string, envBase: string): Promise<boolean> {
  try {
    const env = await canonicalBase(envBase);
    return env.path === basePath;
  } catch {
    return false;
  }
}

/**
 * Run the whole startup sequence and publish readiness only after every step
 * succeeded. A failure closes only this instance's listener, host, descriptor
 * and kernel lock; it never touches the primary lock or any other process.
 */
export async function startService(
  options: StartServiceOptions,
): Promise<RunningService> {
  assertSupportedRuntime();
  const base = await canonicalBase(options.base);
  if (
    options.envBase !== undefined &&
    !(await sameBase(base.path, options.envBase))
  ) {
    throw new LocalServiceFailure("base-mismatch");
  }
  const port = options.port ?? 0;
  assertValidPort(port);

  const lock = await acquireServiceLock(base.baseId);
  const serviceInstanceId = randomUUID();
  const startedAt = new Date().toISOString();

  let server: ReturnType<typeof createServiceHttpServer> | undefined;
  let listener: Awaited<ReturnType<typeof attachServiceListener>> | undefined;
  let host: Awaited<ReturnType<typeof createServiceHost>>["host"] | undefined;
  let closed = false;

  const close = async (): Promise<void> => {
    if (closed) return;
    closed = true;
    await listener?.close().catch(() => undefined);
    await host?.close().catch(() => undefined);
    await new Promise<void>((resolve) => {
      if (server === undefined) {
        resolve();
        return;
      }
      server.close(() => resolve());
      server.closeAllConnections?.();
    });
    await removeOwnDescriptor(base.path, serviceInstanceId).catch(
      () => undefined,
    );
    await lock.release().catch(() => undefined);
  };

  try {
    const token = await ensureToken(base.path);
    const initialView = serviceView(base.baseId, serviceInstanceId, startedAt);
    const serviceHost = createServiceHost({
      baseId: base.baseId,
      serviceInstanceId,
      startedAt,
      viewSource: options.viewSource?.(initialView),
      onError: options.onBackgroundError,
    });
    host = serviceHost.host;
    server = createServiceHttpServer();
    await new Promise<void>((resolve, reject) => {
      const fail = () => reject(new LocalServiceFailure("listen-failed"));
      server?.once("error", fail);
      server?.listen(port, "127.0.0.1", () => {
        server?.off("error", fail);
        resolve();
      });
    });
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new LocalServiceFailure("listen-failed");
    }
    listener = await attachServiceListener({
      server,
      host,
      baseId: base.baseId,
      expectedToken: token,
      port: address.port,
    });
    await host.ready();
    const descriptor: EndpointDescriptor = {
      schemaVersion: 1,
      baseId: base.baseId,
      serviceInstanceId,
      pid: process.pid,
      port: address.port,
      startedAt,
    };
    const descriptorPath = await publishDescriptor(base.path, descriptor);
    return {
      baseId: base.baseId,
      serviceInstanceId,
      port: address.port,
      descriptorPath,
      close,
    };
  } catch (error) {
    await close();
    throw error;
  }
}

export type ParsedArguments =
  | { readonly command: "serve"; readonly base: string; readonly port?: number }
  | { readonly command: "rotate-credential"; readonly base: string }
  | { readonly command: "usage" };

function parseInteger(value: string): number | undefined {
  if (!/^[0-9]{1,5}$/.test(value)) return undefined;
  return Number(value);
}

export function parseArguments(argv: readonly string[]): ParsedArguments {
  const [command, ...rest] = argv;
  if (command !== "serve" && command !== "rotate-credential") {
    return { command: "usage" };
  }
  let base: string | undefined;
  let port: number | undefined;
  for (let index = 0; index < rest.length; index += 1) {
    const flag = rest[index];
    const value = rest[index + 1];
    if (value === undefined) return { command: "usage" };
    if (flag === "--base" && base === undefined) {
      base = value;
    } else if (flag === "--port" && command === "serve" && port === undefined) {
      port = parseInteger(value);
      if (port === undefined) return { command: "usage" };
    } else {
      return { command: "usage" };
    }
    index += 1;
  }
  if (base === undefined) return { command: "usage" };
  return command === "serve" ? { command, base, port } : { command, base };
}

function writeFailure(code: ServiceFailureCode): void {
  process.stderr.write(
    `error: ${code}: ${SERVICE_FAILURE_DIAGNOSTICS[code]}\n`,
  );
}

function ignoreStreamErrors(stream: NodeJS.WriteStream): void {
  stream.on("error", () => undefined);
}

/**
 * CLI entry. Returns an exit code for terminating paths and `undefined` while a
 * successfully started service keeps running.
 */
export async function runCli(
  argv: readonly string[],
): Promise<number | undefined> {
  ignoreStreamErrors(process.stdout);
  ignoreStreamErrors(process.stderr);
  const parsed = parseArguments(argv);
  if (parsed.command === "usage") {
    writeFailure("usage");
    return 2;
  }
  try {
    if (parsed.command === "rotate-credential") {
      assertSupportedRuntime();
      const base = await canonicalBase(parsed.base);
      if (
        process.env.SQUAD_BASE !== undefined &&
        !(await sameBase(base.path, process.env.SQUAD_BASE))
      ) {
        throw new LocalServiceFailure("base-mismatch");
      }
      const lock = await acquireServiceLock(base.baseId);
      try {
        const path = await rotateToken(base.path);
        process.stdout.write(`rotated: ${path}\n`);
      } finally {
        await lock.release().catch(() => undefined);
      }
      return 0;
    }
    const running = await startService({
      base: parsed.base,
      port: parsed.port,
      envBase: process.env.SQUAD_BASE,
      onBackgroundError: () => {
        process.stderr.write("warn: background-error observed\n");
      },
    });
    process.stdout.write(
      `${READY_PREFIX}127.0.0.1:${running.port} instance ${running.serviceInstanceId}\n`,
    );
    let stopping = false;
    const stop = (): void => {
      if (stopping) return;
      stopping = true;
      void running.close().finally(() => process.exit(0));
    };
    process.on("SIGTERM", stop);
    process.on("SIGINT", stop);
    process.on("SIGHUP", stop);
    return undefined;
  } catch (error) {
    writeFailure(
      isLocalServiceFailure(error)
        ? error.code
        : ("internal" as ServiceFailureCode),
    );
    return 1;
  }
}

const entry =
  process.argv[1] === undefined
    ? undefined
    : pathToFileURL(process.argv[1]).href;
if (entry !== undefined && entry === import.meta.url) {
  void runCli(process.argv.slice(2)).then((code) => {
    if (code !== undefined) process.exit(code);
  });
}
