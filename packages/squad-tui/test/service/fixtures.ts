import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect } from "node:net";
import { fileURLToPath } from "node:url";
import { createHost, webSocketLink } from "@earendil-works/chord";
import { track, type Tracker } from "@earendil-works/chord/delta";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type {
  ReplicatedStateSource,
  ReplicatedStateSourceAttachment,
  ReplicatedStateSourceFrame,
} from "@earendil-works/chord";
import { WebSocket } from "ws";
import {
  EndpointDescriptor,
  LOCAL_SERVICE_LINK_PATH,
  type ServiceToken,
} from "../../src/contracts/local-service.ts";
import {
  credentialPath,
  descriptorPath,
  readDescriptor,
  readToken,
} from "../../src/service/credentials.ts";
import { canonicalBase } from "../../src/service/exclusivity.ts";
import { startService, READY_PREFIX } from "../../src/service/main.ts";
import {
  LocalServiceFacet,
  type ServicePrincipal,
  type ServiceViewState,
} from "../../src/service/transport.ts";

const HERE = fileURLToPath(new URL(".", import.meta.url));
export const FIXTURES_PATH = join(HERE, "fixtures.ts");
export const PACKAGE_ROOT = join(HERE, "..", "..");
export const SERVICE_ENTRY = join(PACKAGE_ROOT, "src", "service", "main.ts");

/**
 * Resolve a real Node binary. Bun prepends a `node` shim directory to PATH
 * inside its test runner, so `spawn("node")` would quietly start Bun instead.
 */
let cachedNodeBinary: string | undefined;

export function nodeBinary(): string {
  if (cachedNodeBinary !== undefined) return cachedNodeBinary;
  if (process.versions.bun === undefined) {
    cachedNodeBinary = process.execPath;
    return cachedNodeBinary;
  }
  const override = process.env.SQUAD_TUI_NODE_BINARY;
  const candidates = [
    ...(override === undefined ? [] : [override]),
    ...(process.env.PATH ?? "")
      .split(":")
      .filter((entry) => entry !== "" && !entry.includes("/bun-node-"))
      .map((entry) => join(entry, "node")),
  ];
  for (const candidate of candidates) {
    try {
      const runtime = execFileSync(
        candidate,
        ["-e", "process.stdout.write(process.versions.bun ?? '')"],
        { encoding: "utf8", timeout: 10_000 },
      );
      if (runtime === "") {
        cachedNodeBinary = candidate;
        return candidate;
      }
    } catch {
      // Not a runnable Node binary; try the next candidate.
    }
  }
  throw new Error("no Node runtime found for the T07 service tests");
}

const STRIPPED_ENV = [
  "SQUAD_BASE",
  "SQUAD_HOME",
  "SQUAD_DATA_OVERRIDE",
  "SQUAD_CONFIG_OVERRIDE",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "OPENAI_API_KEY",
  "OPENAI_CODEX_TOKEN",
  "GITHUB_TOKEN",
  "GH_TOKEN",
];

/** Child environments carry no live base, provider credential or Relay token. */
export function cleanEnv(
  extra: Record<string, string> = {},
): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const name of STRIPPED_ENV) delete env[name];
  for (const name of Object.keys(env)) {
    if (name.startsWith("PI_") || name.startsWith("SQX_")) delete env[name];
  }
  return { ...env, ...extra };
}

export async function temporaryBase(): Promise<string> {
  const base = await mkdtemp(join(tmpdir(), "squad-tui-t07-"));
  await mkdir(join(base, "state"), { mode: 0o700 });
  return base;
}

export async function removeBase(base: string): Promise<void> {
  await rm(base, { recursive: true, force: true });
}

export async function fileMode(path: string): Promise<number> {
  return (await stat(path)).mode & 0o777;
}

export async function readTokenFile(base: string): Promise<ServiceToken> {
  return readToken(base);
}

export { readDescriptor };

/** Text of this base's descriptor exactly as published. */
export async function descriptorText(base: string): Promise<string> {
  return readFile(descriptorPath(base), "utf8");
}

/** Text of this base's credential file exactly as published. */
export async function credentialText(base: string): Promise<string> {
  return readFile(credentialPath(base), "utf8");
}

export type CommandResult = {
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
};

function collect(child: ChildProcess): {
  stdout: () => string;
  stderr: () => string;
} {
  let out = "";
  let err = "";
  child.stdout?.on("data", (chunk: Buffer) => {
    out += chunk.toString("utf8");
  });
  child.stderr?.on("data", (chunk: Buffer) => {
    err += chunk.toString("utf8");
  });
  return { stdout: () => out, stderr: () => err };
}

export async function runNode(
  args: readonly string[],
  options: { env?: Record<string, string>; timeoutMs?: number } = {},
): Promise<CommandResult> {
  const child = spawn(nodeBinary(), [...args], {
    cwd: PACKAGE_ROOT,
    env: cleanEnv(options.env),
    stdio: ["ignore", "pipe", "pipe"],
  });
  const capture = collect(child);
  const timer = setTimeout(
    () => child.kill("SIGKILL"),
    options.timeoutMs ?? 30_000,
  );
  const code = await new Promise<number | null>((resolve) => {
    child.on("exit", (status) => resolve(status));
  });
  clearTimeout(timer);
  return { code, stdout: capture.stdout(), stderr: capture.stderr() };
}

export async function runCliService(
  args: readonly string[],
  options: { env?: Record<string, string>; timeoutMs?: number } = {},
): Promise<CommandResult> {
  return runNode([SERVICE_ENTRY, ...args], options);
}

export async function runCliRotate(
  base: string,
  options: { env?: Record<string, string>; timeoutMs?: number } = {},
): Promise<CommandResult> {
  return runNode([SERVICE_ENTRY, "rotate-credential", "--base", base], options);
}

export type RunningServiceHandle = {
  readonly child: ChildProcess;
  readonly base: string;
  readonly baseId: string;
  readonly serviceInstanceId: string;
  readonly port: number;
  readonly pid: number;
  readonly token: ServiceToken;
  readonly descriptor: EndpointDescriptor;
  readonly readyLine: string;
  stdout(): string;
  stderr(): string;
  /** Kill only the child this helper created, waiting for its exit. */
  stop(signal?: NodeJS.Signals): Promise<number | null>;
};

export type StartServiceProcessOptions = {
  readonly base: string;
  readonly port?: number;
  readonly source?: "scripted" | "burst";
  readonly revisions?: number;
  readonly intervalMs?: number;
  readonly startDelayMs?: number;
  readonly reasonBytes?: number;
  readonly env?: Record<string, string>;
};

export async function startServiceProcess(
  options: StartServiceProcessOptions,
): Promise<RunningServiceHandle> {
  const args = [FIXTURES_PATH, "service", "--base", options.base];
  if (options.port !== undefined) args.push("--port", String(options.port));
  if (options.source !== undefined) args.push("--source", options.source);
  if (options.revisions !== undefined)
    args.push("--revisions", String(options.revisions));
  if (options.intervalMs !== undefined)
    args.push("--interval-ms", String(options.intervalMs));
  if (options.startDelayMs !== undefined)
    args.push("--start-delay-ms", String(options.startDelayMs));
  if (options.reasonBytes !== undefined)
    args.push("--reason-bytes", String(options.reasonBytes));
  const child = spawn(nodeBinary(), args, {
    cwd: PACKAGE_ROOT,
    env: cleanEnv(options.env),
    stdio: ["ignore", "pipe", "pipe"],
  });
  const capture = collect(child);
  const readyLine = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`service did not become ready: ${capture.stderr()}`));
    }, 25_000);
    const onData = (): void => {
      const line = capture
        .stdout()
        .split("\n")
        .find((entry) => entry.startsWith(READY_PREFIX));
      if (line !== undefined) {
        clearTimeout(timer);
        child.stdout?.off("data", onData);
        resolve(line);
      }
    };
    child.stdout?.on("data", onData);
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(
        new Error(`service exited before ready (${code}): ${capture.stderr()}`),
      );
    });
  });
  const descriptor = await readDescriptor(options.base);
  const token = await readToken(options.base);
  const stop = async (
    signal: NodeJS.Signals = "SIGTERM",
  ): Promise<number | null> => {
    if (child.exitCode !== null) return child.exitCode;
    child.kill(signal);
    const timer = setTimeout(() => child.kill("SIGKILL"), 8_000);
    const code = await new Promise<number | null>((resolve) => {
      child.on("exit", (status) => resolve(status));
    });
    clearTimeout(timer);
    return code;
  };
  return {
    child,
    base: options.base,
    baseId: descriptor.baseId,
    serviceInstanceId: descriptor.serviceInstanceId,
    port: descriptor.port,
    pid: descriptor.pid,
    token,
    descriptor,
    readyLine,
    stdout: capture.stdout,
    stderr: capture.stderr,
    stop,
  };
}

export type ClientRunOptions = {
  readonly mode: "attach" | "call" | "slow";
  readonly durationMs?: number;
  readonly blockMs?: number;
  readonly capabilities?: Record<string, unknown>;
  readonly execute?: Record<string, unknown>;
  readonly env?: Record<string, string>;
};

export type ClientRecord = Record<string, unknown>;

export type ClientRun = {
  readonly code: number | null;
  readonly records: readonly ClientRecord[];
  readonly stderr: string;
};

/** Run one real Node client process against a running service. */
export async function runClientProcess(
  base: string,
  options: ClientRunOptions,
): Promise<ClientRun> {
  const child = spawn(
    nodeBinary(),
    [FIXTURES_PATH, "client", options.mode, base, JSON.stringify(options)],
    {
      cwd: PACKAGE_ROOT,
      env: cleanEnv(options.env),
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const capture = collect(child);
  const timer = setTimeout(() => child.kill("SIGKILL"), 40_000);
  const code = await new Promise<number | null>((resolve) => {
    child.on("exit", (status) => resolve(status));
  });
  clearTimeout(timer);
  const records: ClientRecord[] = [];
  for (const line of capture.stdout().split("\n")) {
    if (line.trim() === "") continue;
    try {
      const parsed: unknown = JSON.parse(line);
      if (parsed !== null && typeof parsed === "object") {
        records.push(parsed as ClientRecord);
      }
    } catch {
      // Non-JSON stdout is not a client record.
    }
  }
  return { code, records, stderr: capture.stderr() };
}

export type UpgradeProbeOptions = {
  readonly token?: string;
  readonly baseId?: string;
  readonly origin?: string;
  readonly query?: string;
  readonly path?: string;
  readonly omitHost?: boolean;
  readonly rawHeaders?: readonly string[];
};

export type UpgradeProbe = { readonly outcome: string };

/**
 * A raw loopback upgrade attempt. Refusals are HTTP statuses before any
 * WebSocket exists; a success is reported as `open` and closed at once.
 */
export function probeUpgrade(
  port: number,
  options: UpgradeProbeOptions,
): Promise<UpgradeProbe> {
  const path = options.path ?? LOCAL_SERVICE_LINK_PATH;
  const query = options.query === undefined ? "" : `?${options.query}`;
  const headers: Record<string, string> = {};
  if (options.baseId !== undefined) headers["x-squad-base-id"] = options.baseId;
  if (options.token !== undefined)
    headers.authorization = `Bearer ${options.token}`;
  if (options.origin !== undefined) headers.origin = options.origin;
  if (options.omitHost !== true) headers.host = `127.0.0.1:${port}`;
  for (let index = 0; index < (options.rawHeaders ?? []).length; index += 2) {
    headers[(options.rawHeaders ?? [])[index]] = (options.rawHeaders ?? [])[
      index + 1
    ];
  }
  return new Promise<UpgradeProbe>((resolve) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}${path}${query}`, {
      headers,
    });
    const done = (outcome: string): void => {
      socket.removeAllListeners();
      socket.on("error", () => undefined);
      socket.close();
      resolve({ outcome });
    };
    socket.on("open", () => done("open"));
    socket.on("unexpected-response", (_request, response) =>
      done(`http-${response.statusCode ?? 0}`),
    );
    socket.on("error", () => done("error"));
  });
}

/**
 * Raw loopback upgrade over a plain TCP socket, for header shapes the `ws`
 * client will not send (Host overrides, oversized header blocks).
 */
export function probeRawUpgrade(
  port: number,
  options: {
    readonly path?: string;
    readonly headers?: readonly string[];
    readonly method?: string;
    readonly host?: string;
  } = {},
): Promise<{ readonly status: number; readonly text: string }> {
  const path = options.path ?? LOCAL_SERVICE_LINK_PATH;
  const headers = options.headers ?? [];
  return new Promise((resolve) => {
    const socket = connect(port, "127.0.0.1", () => {
      socket.write(
        [
          `${options.method ?? "GET"} ${path} HTTP/1.1`,
          `Host: ${options.host ?? `127.0.0.1:${port}`}`,
          "Upgrade: websocket",
          "Connection: Upgrade",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
          "Sec-WebSocket-Version: 13",
          ...headers,
          "",
          "",
        ].join("\r\n"),
      );
    });
    let text = "";
    socket.on("data", (chunk) => {
      text += chunk.toString("utf8");
      if (text.includes("\r\n\r\n")) {
        socket.destroy();
      }
    });
    socket.on("close", () => {
      const status = Number(/^HTTP\/1\.1 (\d{3})/.exec(text)?.[1] ?? 0);
      resolve({ status, text });
    });
    socket.on("error", () => resolve({ status: 0, text }));
  });
}

/** Recursive listing of one base, for no-side-effect assertions. */
export async function listBase(base: string, prefix = ""): Promise<string[]> {
  const entries = await readdir(join(base, prefix), { withFileTypes: true });
  const names: string[] = [];
  for (const entry of entries) {
    const relative = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
    names.push(relative);
    if (entry.isDirectory()) names.push(...(await listBase(base, relative)));
  }
  return names.sort();
}

/** Plain HTTP status for a non-upgrade request. */
export async function httpStatus(
  port: number,
  path: string,
  method = "GET",
): Promise<number> {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    method,
    redirect: "manual",
  });
  await response.arrayBuffer();
  return response.status;
}

export type ScriptedSource = {
  readonly factory: (
    initial: ServiceViewState,
  ) => ReplicatedStateSource<ServiceViewState>;
  readonly publish: (mutate: (value: ServiceViewState) => void) => void;
  readonly cursor: () => number;
};

/**
 * A real `ReplicatedStateSource`: one atomic snapshot at attach, then every
 * committed frame in cursor order with its exact operation batch.
 */
export function scriptedSource(): ScriptedSource {
  let tracker: Tracker<ServiceViewState> | undefined;
  let cursor = 0;
  const frames: ReplicatedStateSourceFrame<ServiceViewState>[] = [];
  let listener:
    ((frame: ReplicatedStateSourceFrame<ServiceViewState>) => void) | undefined;
  return {
    factory(initial) {
      const local = track(initial);
      tracker = local;
      cursor = 0;
      return {
        attach(): ReplicatedStateSourceAttachment<ServiceViewState> {
          // Only frames committed after this snapshot's cursor belong to the
          // attachment; earlier frames are already represented by the snapshot.
          const pending = frames.filter((frame) => frame.cursor > cursor);
          return {
            snapshot: { value: local.value, cursor },
            activate(next) {
              listener = next;
              for (const frame of pending) next(frame);
            },
            dispose() {
              listener = undefined;
            },
          };
        },
      };
    },
    publish(mutate) {
      if (tracker === undefined) throw new Error("source is not attached");
      const change = tracker.beginChange();
      mutate(change.state as ServiceViewState);
      const prepared = change.prepare();
      tracker.adopt(prepared);
      cursor += 1;
      const frame: ReplicatedStateSourceFrame<ServiceViewState> = {
        cursor,
        value: prepared.value,
        ops: prepared.ops,
        context: BACKGROUND_CONTEXT,
      };
      frames.push(frame);
      listener?.(frame);
    },
    cursor() {
      return cursor;
    },
  };
}

export function paddedReason(index: number, bytes: number): string {
  const prefix = `revision-${index}-`;
  return prefix + "x".repeat(Math.max(0, bytes - prefix.length));
}

/**
 * Compatibility probe, run by a Node child: exact Chord imports, typed
 * method/state registration, node:http plus ws, custom upgrade headers,
 * compression disabled, message bounds, and cross-process kernel-lock refusal.
 */
async function runCompatibilityProbe(): Promise<void> {
  const { processLock } = await import("@earendil-works/chord/node");
  const { createServiceHost, createServiceHttpServer, attachServiceListener } =
    await import("../../src/service/transport.ts");
  const base = await temporaryBase();
  const canonical = await canonicalBase(base);
  const serviceInstanceId = randomUUID();
  const startedAt = new Date().toISOString();
  const host = createServiceHost({
    baseId: canonical.baseId,
    serviceInstanceId,
    startedAt,
  });
  const server = createServiceHttpServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string")
    throw new Error("no port");
  const token = "a".repeat(64);
  const listener = await attachServiceListener({
    server,
    host: host.host,
    baseId: canonical.baseId,
    expectedToken: token,
    port: address.port,
  });

  // Raw upgrade: inspect the 101 response headers for compression.
  const { connect } = await import("node:net");
  const rawHeaders = await new Promise<string>((resolve) => {
    const socket = connect(address.port, "127.0.0.1", () => {
      socket.write(
        [
          "GET /v1/link HTTP/1.1",
          `Host: 127.0.0.1:${address.port}`,
          "Upgrade: websocket",
          "Connection: Upgrade",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
          "Sec-WebSocket-Version: 13",
          "Sec-WebSocket-Extensions: permessage-deflate",
          `Authorization: Bearer ${token}`,
          `X-Squad-Base-Id: ${canonical.baseId}`,
          "",
          "",
        ].join("\r\n"),
      );
    });
    let text = "";
    socket.on("data", (chunk) => {
      text += chunk.toString("utf8");
      if (text.includes("\r\n\r\n")) {
        socket.destroy();
        resolve(text);
      }
    });
    socket.on("error", () => resolve(text));
  });
  console.log(
    JSON.stringify({
      kind: "upgrade",
      status: rawHeaders.split("\r\n")[0],
      negotiatedExtensions: /sec-websocket-extensions:/i.test(rawHeaders),
    }),
  );

  // A separate Node client process attaches with the custom headers.
  const client = await runNode(
    [
      FIXTURES_PATH,
      "client",
      "extract",
      base,
      JSON.stringify({ token, port: address.port, baseId: canonical.baseId }),
    ],
    { timeoutMs: 20_000 },
  );
  console.log(
    JSON.stringify({
      kind: "client",
      code: client.code,
      stdout: client.stdout.trim().split("\n").filter(Boolean),
      stderr: client.stderr.trim(),
    }),
  );

  // A > 1 MiB message closes the socket instead of reaching Chord.
  const oversized = await new Promise<string>((resolve) => {
    const socket = new WebSocket(`ws://127.0.0.1:${address.port}/v1/link`, {
      headers: {
        host: `127.0.0.1:${address.port}`,
        authorization: `Bearer ${token}`,
        "x-squad-base-id": canonical.baseId,
      },
    });
    socket.on("open", () => socket.send("x".repeat(1024 * 1024 + 16)));
    socket.on("close", (code) => resolve(`close-${code}`));
    socket.on("error", () => resolve("error"));
  });
  console.log(JSON.stringify({ kind: "oversized", outcome: oversized }));

  // Cross-process kernel-lock refusal through the production path.
  const lock = await processLock(`squad-tui-service-v1-${canonical.baseId}`);
  const contender = await runNode([FIXTURES_PATH, "lock", canonical.baseId], {
    timeoutMs: 20_000,
  });
  await lock();
  console.log(
    JSON.stringify({
      kind: "lock",
      contender: contender.stdout.trim(),
      stderr: contender.stderr.trim(),
    }),
  );

  await listener.close();
  await host.host.close();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await removeBase(base);
}

async function runLockAttempt(baseId: string): Promise<void> {
  const { acquireServiceLock } =
    await import("../../src/service/exclusivity.ts");
  try {
    const lock = await acquireServiceLock(baseId);
    await lock.release();
    console.log(JSON.stringify({ kind: "lock", outcome: "acquired" }));
  } catch (error) {
    const code =
      error !== null && typeof error === "object" && "code" in error
        ? String((error as { code: unknown }).code)
        : "unknown";
    console.log(JSON.stringify({ kind: "lock", outcome: "refused", code }));
  }
}

async function runExtractClient(
  base: string,
  options: { token?: string; port?: number; baseId?: string },
): Promise<void> {
  const descriptor =
    options.port !== undefined && options.baseId !== undefined
      ? { port: options.port, baseId: options.baseId }
      : await readDescriptor(base);
  const token = options.token ?? (await readToken(base));
  const client = createHost<ServicePrincipal>({
    name: "client",
    kind: "client",
    self: { kind: "local-client", baseId: descriptor.baseId },
    principalKey: (principal) => `${principal.kind}:${principal.baseId}`,
  });
  const socket = new WebSocket(`ws://127.0.0.1:${descriptor.port}/v1/link`, {
    headers: {
      host: `127.0.0.1:${descriptor.port}`,
      authorization: `Bearer ${token}`,
      "x-squad-base-id": descriptor.baseId,
    },
  });
  const binary: boolean[] = [];
  socket.on("message", (_data, isBinary) => binary.push(isBinary));
  client.connect(
    webSocketLink(socket as never, { compress: false, acceptPacked: false }),
    { principal: { kind: "local-client", baseId: descriptor.baseId } },
  );
  const view = await client.get(LocalServiceFacet, {
    schemaVersion: 1,
    baseId: descriptor.baseId,
  });
  const call = view.capabilities as unknown as (args: unknown) => Promise<{
    ok: boolean;
  }>;
  const capabilities = await call({
    schemaVersion: 1,
    baseId: descriptor.baseId,
  });
  console.log(
    JSON.stringify({
      kind: "extract",
      readiness: view.view.value?.readiness,
      capabilities: capabilities.ok,
    }),
  );
  view.release();
  socket.close();
  await client.close();
  if (binary.some((flag) => flag)) {
    console.log(
      JSON.stringify({ kind: "binary-frames", count: binary.length }),
    );
  }
}

function parseFlags(argv: readonly string[]): Record<string, string> {
  const flags: Record<string, string> = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (name !== undefined && name.startsWith("--") && value !== undefined) {
      flags[name.slice(2)] = value;
    }
  }
  return flags;
}

async function runServiceMode(argv: readonly string[]): Promise<void> {
  const flags = parseFlags(argv);
  const base = flags.base;
  if (base === undefined) throw new Error("service mode needs --base");
  const flagsPort = flags.port === undefined ? 0 : Number(flags.port);
  const sourceMode = flags.source;
  const revisions = flags.revisions === undefined ? 6 : Number(flags.revisions);
  const intervalMs =
    flags["interval-ms"] === undefined ? 40 : Number(flags["interval-ms"]);
  const startDelayMs =
    flags["start-delay-ms"] === undefined
      ? 250
      : Number(flags["start-delay-ms"]);
  const reasonBytes =
    flags["reason-bytes"] === undefined ? 40 : Number(flags["reason-bytes"]);

  let scripted: ScriptedSource | undefined;
  let viewSource:
    | ((initial: ServiceViewState) => ReplicatedStateSource<ServiceViewState>)
    | undefined;
  if (sourceMode === "scripted" || sourceMode === "burst") {
    scripted = scriptedSource();
    viewSource = scripted.factory;
  }

  const running = await startService({
    base,
    port: flagsPort,
    viewSource,
    onBackgroundError: (error) => {
      process.stderr.write(
        `background-error: ${error instanceof Error ? error.message : "unknown"}\n`,
      );
    },
  });
  process.stdout.write(
    `${READY_PREFIX}127.0.0.1:${running.port} instance ${running.serviceInstanceId}\n`,
  );

  if (scripted !== undefined && sourceMode !== undefined) {
    const source = scripted;
    setTimeout(() => {
      let index = 0;
      const publishNext = (): void => {
        index += 1;
        source.publish((value) => {
          value.availability = {
            ...value.availability,
            commands: {
              available: false,
              reason: paddedReason(index, reasonBytes),
            },
          };
        });
        if (index < revisions) {
          if (sourceMode === "scripted") {
            setTimeout(publishNext, intervalMs);
          } else {
            setImmediate(publishNext);
          }
        }
      };
      publishNext();
    }, startDelayMs).unref();
  }

  const stop = (): void => {
    void running.close().finally(() => process.exit(0));
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

async function runClientMode(
  mode: string,
  base: string,
  rawOptions: string,
): Promise<void> {
  const options = JSON.parse(rawOptions) as ClientRunOptions;
  if (mode === "extract") {
    await runExtractClient(
      base,
      JSON.parse(rawOptions) as {
        token?: string;
        port?: number;
        baseId?: string;
      },
    );
    return;
  }
  const descriptor = await readDescriptor(base);
  const token = await readToken(base);
  const client = createHost<ServicePrincipal>({
    name: "client",
    kind: "client",
    self: { kind: "local-client", baseId: descriptor.baseId },
    principalKey: (principal) => `${principal.kind}:${principal.baseId}`,
  });
  const socket = new WebSocket(`ws://127.0.0.1:${descriptor.port}/v1/link`, {
    headers: {
      host: `127.0.0.1:${descriptor.port}`,
      authorization: `Bearer ${token}`,
      "x-squad-base-id": descriptor.baseId,
    },
  });
  client.connect(
    webSocketLink(socket as never, { compress: false, acceptPacked: false }),
    { principal: { kind: "local-client", baseId: descriptor.baseId } },
  );
  const view = await client.get(LocalServiceFacet, {
    schemaVersion: 1,
    baseId: descriptor.baseId,
  });
  const reason = (): unknown =>
    view.view.value?.availability.commands.reason ?? null;
  console.log(JSON.stringify({ kind: "attached", reason: reason() }));

  if (mode === "call") {
    const invoke = async (
      name: "capabilities" | "execute",
      args: unknown,
    ): Promise<void> => {
      try {
        const result = await (
          view[name] as unknown as (input: unknown) => Promise<unknown>
        )(args);
        console.log(JSON.stringify({ kind: name, result }));
      } catch (error) {
        const code =
          error !== null && typeof error === "object" && "code" in error
            ? String((error as { code: unknown }).code)
            : "unknown";
        console.log(JSON.stringify({ kind: `${name}-error`, code }));
      }
    };
    if (options.capabilities !== undefined) {
      await invoke("capabilities", options.capabilities);
    }
    if (options.execute !== undefined) {
      await invoke("execute", options.execute);
    }
    view.release();
    socket.close();
    await client.close();
    return;
  }

  const started = Date.now();
  let blocked = false;
  const unsubscribe = view.view.events((event) => {
    if (event.type === "snap" || event.type === "reset") {
      console.log(
        JSON.stringify({
          kind: `event-${event.type}`,
          reason: event.value.availability.commands.reason,
        }),
      );
    } else {
      console.log(
        JSON.stringify({
          kind: "event-ops",
          ops: event.ops.length,
          reason: event.value.availability.commands.reason,
        }),
      );
    }
    if (mode === "slow" && !blocked && options.blockMs !== undefined) {
      blocked = true;
      const until = Date.now() + options.blockMs;
      while (Date.now() < until) {
        // Deliberately stall this client's event loop so acknowledgements stop.
      }
      console.log(JSON.stringify({ kind: "unblocked" }));
    }
  });
  const durationMs = options.durationMs ?? 2_500;
  const timer = setInterval(() => {
    if (Date.now() - started >= durationMs) {
      clearInterval(timer);
      unsubscribe();
      console.log(JSON.stringify({ kind: "done", reason: reason() }));
      view.release();
      socket.close();
      void client.close().then(() => process.exit(0));
    }
  }, 50);
}

async function main(): Promise<void> {
  const [, , mode, ...rest] = process.argv;
  if (mode === "compatibility") {
    await runCompatibilityProbe();
    return;
  }
  if (mode === "lock") {
    await runLockAttempt(rest[0]);
    return;
  }
  if (mode === "service") {
    await runServiceMode(rest);
    return;
  }
  if (mode === "client") {
    await runClientMode(rest[0], rest[1], rest[2] ?? "{}");
    return;
  }
  throw new Error(`unknown fixture mode ${String(mode)}`);
}

const entry =
  process.argv[1] === undefined ? undefined : fileURLToPath(import.meta.url);
if (entry !== undefined && process.argv[1] === entry) {
  void main().catch((error: unknown) => {
    process.stderr.write(
      `fixture-error: ${error instanceof Error ? error.message : "unknown"}\n`,
    );
    process.exit(1);
  });
}
