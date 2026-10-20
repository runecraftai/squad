import { Type, type Static } from "typebox";
import {
  createHost,
  forbidden,
  hostNamed,
  method,
  remote,
  replicatedState,
  webSocketLink,
  type Host,
  type ReplicatedStateSource,
} from "@earendil-works/chord";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import {
  BOUNDED_ID_PATTERN,
  CapabilitiesResult,
  ExecuteRequest,
  ExecuteResult,
  LOCAL_SERVICE_CONTRACT_NAME,
  LOCAL_SERVICE_CONTRACT_VERSION,
  LOCAL_SERVICE_LIMITS,
  LOCAL_SERVICE_LINK_PATH,
  LocalServiceFailure,
  RESERVED_OPERATIONS,
  SERVICE_READS,
  SERVICE_UNAVAILABLE_REASON,
  ServiceSelector,
  ServiceView,
  serviceAvailability,
  operationUnavailableAcceptance,
  type ServiceToken,
} from "../contracts/local-service.ts";
import { verifyToken } from "./credentials.ts";

export const SERVICE_HOST_NAME = "squad-tui-service";

/** One complete service view revision; also the shape a test source publishes. */
export type ServiceViewState = Static<typeof ServiceViewSchema>;

export type ServicePrincipal =
  | { readonly kind: "service"; readonly baseId: string }
  | { readonly kind: "local-client"; readonly baseId: string };

const RefusalCodeSchema = Type.Union([
  Type.Literal("unauthenticated"),
  Type.Literal("base-mismatch"),
  Type.Literal("unsupported-version"),
  Type.Literal("invalid-request"),
  Type.Literal("operation-unavailable"),
  Type.Literal("limit-exceeded"),
  Type.Literal("service-unavailable"),
]);

const RefusalSchema = Type.Object(
  { code: RefusalCodeSchema },
  { additionalProperties: false },
);

const AvailabilitySchema = Type.Object(
  {
    projections: Type.Object(
      { available: Type.Literal(false), reason: Type.String() },
      { additionalProperties: false },
    ),
    commands: Type.Object(
      { available: Type.Literal(false), reason: Type.String() },
      { additionalProperties: false },
    ),
  },
  { additionalProperties: false },
);

const ServiceViewSchema = Type.Object(
  {
    schemaVersion: Type.Literal(1),
    baseId: Type.String({ pattern: "^[0-9a-f]{64}$" }),
    serviceInstanceId: Type.String({ minLength: 1, maxLength: 128 }),
    startedAt: Type.String({ minLength: 1, maxLength: 64 }),
    readiness: Type.Literal("ready"),
    availability: AvailabilitySchema,
  },
  { additionalProperties: false },
);

// Strict declaration plus the Zod boundary: Chord's argument cleaning drops
// fields it does not know, so an unknown field never reaches a handler or
// changes an object address, and the Zod schema refuses any divergence that
// does survive cleaning.
const SelectorSchema = Type.Object(
  {
    schemaVersion: Type.Integer({ minimum: 1, maximum: 65535 }),
    baseId: Type.String({ pattern: "^[0-9a-f]{64}$" }),
  },
  { additionalProperties: false },
);

const CapabilitiesResultSchema = Type.Union([
  Type.Object(
    {
      ok: Type.Literal(true),
      capabilities: Type.Object(
        {
          schemaVersion: Type.Literal(1),
          baseId: Type.String({ pattern: "^[0-9a-f]{64}$" }),
          serviceInstanceId: Type.String({ minLength: 1, maxLength: 128 }),
          reads: Type.Array(
            Type.Union([Type.Literal("view"), Type.Literal("capabilities")]),
            { minItems: 1, maxItems: SERVICE_READS.length },
          ),
          commands: Type.Object(
            { available: Type.Literal(false), reason: Type.String() },
            { additionalProperties: false },
          ),
          unavailable: Type.Array(
            Type.Object(
              {
                feature: Type.Union([
                  Type.Literal("projections"),
                  Type.Literal("sessions"),
                  Type.Literal("missions"),
                  Type.Literal("tasks"),
                  Type.Literal("decisions"),
                  Type.Literal("commands"),
                ]),
                reason: Type.String(),
              },
              { additionalProperties: false },
            ),
            { maxItems: 8 },
          ),
        },
        { additionalProperties: false },
      ),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    { ok: Type.Literal(false), refusal: RefusalSchema },
    { additionalProperties: false },
  ),
]);

const CommandTargetSchema = Type.Object(
  {
    kind: Type.Union([
      Type.Literal("session"),
      Type.Literal("mission"),
      Type.Literal("task"),
      Type.Literal("stage"),
      Type.Literal("run"),
      Type.Literal("decision"),
      Type.Literal("artifact"),
    ]),
    id: Type.String({ pattern: BOUNDED_ID_PATTERN.source }),
  },
  { additionalProperties: false },
);

const ExecuteArgsSchema = Type.Object(
  {
    schemaVersion: Type.Integer({ minimum: 1, maximum: 65535 }),
    baseId: Type.String({ pattern: "^[0-9a-f]{64}$" }),
    command: Type.Object(
      {
        schemaVersion: Type.Literal(1),
        requestId: Type.String({ pattern: BOUNDED_ID_PATTERN.source }),
        target: CommandTargetSchema,
        payload: Type.Object(
          { operation: Type.String({ minLength: 1, maxLength: 128 }) },
          { additionalProperties: false },
        ),
      },
      { additionalProperties: false },
    ),
  },
  { additionalProperties: false },
);

const ExecuteResultSchema = Type.Union([
  Type.Object(
    {
      ok: Type.Literal(true),
      acceptance: Type.Object(
        {
          requestId: Type.String({ pattern: BOUNDED_ID_PATTERN.source }),
          accepted: Type.Literal(false),
          revision: Type.Null(),
          error: RefusalCodeSchema,
        },
        { additionalProperties: false },
      ),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    { ok: Type.Literal(false), refusal: RefusalSchema },
    { additionalProperties: false },
  ),
]);

/**
 * The one Chord facet this delivery serves. Its selector is a bounded base
 * identity, never a filesystem path or an agent conversation id.
 */
export const LocalServiceFacet = remote(LOCAL_SERVICE_CONTRACT_NAME, {
  version: LOCAL_SERVICE_CONTRACT_VERSION,
  input: SelectorSchema,
  host: hostNamed(SERVICE_HOST_NAME),
  variants: {
    viewer: {
      state: { view: ServiceViewSchema },
      methods: {
        capabilities: method(SelectorSchema, CapabilitiesResultSchema),
        execute: method(ExecuteArgsSchema, ExecuteResultSchema),
      },
    },
  },
});

export type ServiceHostOptions = {
  readonly baseId: string;
  readonly serviceInstanceId: string;
  readonly startedAt: string;
  /**
   * Test-supplied replicated source. Production passes nothing; this is how a
   * real snapshot/ops/reset stream is exercised without adding a fixture route.
   */
  readonly viewSource?: ReplicatedStateSource<ServiceViewState>;
  readonly onError?: (error: unknown) => void;
};

export type ServiceHost = {
  readonly host: Host<ServicePrincipal>;
  readonly view: ServiceViewState;
};

export const SERVICE_COMMANDS_REASON =
  "T07 accepts no operational command; dispatch, agent input and human decisions belong to later tasks";

export const SERVICE_UNAVAILABLE_FEATURES = [
  { feature: "projections" as const, reason: SERVICE_UNAVAILABLE_REASON },
  { feature: "sessions" as const, reason: SERVICE_UNAVAILABLE_REASON },
  { feature: "missions" as const, reason: SERVICE_UNAVAILABLE_REASON },
  { feature: "tasks" as const, reason: SERVICE_UNAVAILABLE_REASON },
  { feature: "decisions" as const, reason: SERVICE_UNAVAILABLE_REASON },
  { feature: "commands" as const, reason: SERVICE_COMMANDS_REASON },
];

export function serviceView(
  baseId: string,
  serviceInstanceId: string,
  startedAt: string,
): ServiceViewState {
  return {
    schemaVersion: 1,
    baseId,
    serviceInstanceId,
    startedAt,
    readiness: "ready",
    availability: serviceAvailability(),
  };
}

/**
 * Build the service host. Every method validates its own arguments again with
 * the Zod boundary schema before doing anything, and no method has a side
 * effect beyond returning a value.
 */
export function createServiceHost(options: ServiceHostOptions): ServiceHost {
  const initialView = serviceView(
    options.baseId,
    options.serviceInstanceId,
    options.startedAt,
  );
  const host = createHost<ServicePrincipal>({
    name: SERVICE_HOST_NAME,
    self: { kind: "service", baseId: options.baseId },
    principalKey: (principal) => `${principal.kind}:${principal.baseId}`,
    onError: options.onError,
  });

  host.serve(LocalServiceFacet, (input, _principal, self) => {
    if (input.schemaVersion !== 1 || input.baseId !== options.baseId) {
      // A foreign selector never reaches the view or a method.
      throw forbidden();
    }
    const attached =
      options.viewSource === undefined
        ? undefined
        : replicatedState(options.viewSource, { onError: options.onError });
    const view = self.state(
      "view",
      ServiceViewSchema,
      attached === undefined ? initialView : { init: () => attached.value },
    );
    if (attached !== undefined) {
      const source = attached;
      let first = true;
      self.task(async (ctx) => {
        const unsubscribe = source.subscribe((value) => {
          if (first) {
            first = false;
            return;
          }
          if (ctx.signal.aborted) return;
          const parsed = ServiceView.safeParse(value);
          if (!parsed.success) {
            options.onError?.(new LocalServiceFailure("internal"));
            return;
          }
          view.replace(ctx, parsed.data);
        });
        await new Promise<void>((resolve) => {
          if (ctx.signal.aborted) {
            resolve();
            return;
          }
          ctx.signal.addEventListener("abort", () => resolve(), { once: true });
        });
        unsubscribe();
        source.dispose();
      });
    }

    const capabilities = (
      selector: Static<typeof SelectorSchema>,
    ): CapabilitiesResult => {
      const parsed = ServiceSelector.safeParse(selector);
      if (!parsed.success) {
        return { ok: false, refusal: { code: "invalid-request" } };
      }
      if (parsed.data.schemaVersion !== 1) {
        return { ok: false, refusal: { code: "unsupported-version" } };
      }
      if (parsed.data.baseId !== options.baseId) {
        return { ok: false, refusal: { code: "base-mismatch" } };
      }
      return {
        ok: true,
        capabilities: {
          schemaVersion: 1,
          baseId: options.baseId,
          serviceInstanceId: options.serviceInstanceId,
          reads: ["view", "capabilities"],
          commands: {
            available: false,
            reason: SERVICE_COMMANDS_REASON,
          },
          unavailable: SERVICE_UNAVAILABLE_FEATURES,
        },
      };
    };

    const execute = (args: Static<typeof ExecuteArgsSchema>): ExecuteResult => {
      if (
        Buffer.byteLength(JSON.stringify(args), "utf8") >
        LOCAL_SERVICE_LIMITS.rpcArgumentBytes
      ) {
        return { ok: false, refusal: { code: "limit-exceeded" } };
      }
      const parsed = ExecuteRequest.safeParse(args);
      if (!parsed.success) {
        return { ok: false, refusal: { code: "invalid-request" } };
      }
      if (parsed.data.schemaVersion !== 1) {
        return { ok: false, refusal: { code: "unsupported-version" } };
      }
      if (parsed.data.baseId !== options.baseId) {
        return { ok: false, refusal: { code: "base-mismatch" } };
      }
      const operation = parsed.data.command.payload.operation;
      if (!(RESERVED_OPERATIONS as readonly string[]).includes(operation)) {
        return { ok: false, refusal: { code: "invalid-request" } };
      }
      return {
        ok: true,
        acceptance: operationUnavailableAcceptance(
          parsed.data.command.requestId,
        ),
      };
    };

    return { variant: "viewer" as const, view, capabilities, execute };
  });

  return { host, view: initialView };
}

/**
 * The fixed, data-free HTTP surface. Only the upgrade route is meaningful;
 * every other path or method gets a fixed status with no base or private data.
 */
export function createServiceHttpServer(): Server {
  const server = createServer((request, response) => {
    const path = (request.url ?? "").split("?")[0];
    response.setHeader("connection", "close");
    if (path === LOCAL_SERVICE_LINK_PATH) {
      if (request.method !== "GET") {
        response.writeHead(405, { "content-type": "text/plain" });
        response.end("method not allowed\n");
        return;
      }
      response.writeHead(426, { "content-type": "text/plain" });
      response.end("upgrade required\n");
      return;
    }
    response.writeHead(404, { "content-type": "text/plain" });
    response.end("not found\n");
  });
  // Bound header receipt for the upgrade path as well as ordinary requests.
  server.headersTimeout = LOCAL_SERVICE_LIMITS.upgradeHeaderTimeoutMs;
  server.requestTimeout = LOCAL_SERVICE_LIMITS.upgradeHeaderTimeoutMs;
  server.keepAliveTimeout = LOCAL_SERVICE_LIMITS.upgradeHeaderTimeoutMs;
  const checking = server as Server & {
    connectionsCheckingInterval?: number;
  };
  checking.connectionsCheckingInterval = Math.min(
    1_000,
    LOCAL_SERVICE_LIMITS.upgradeHeaderTimeoutMs,
  );
  return server;
}

export type ServiceListenerOptions = {
  readonly server: Server;
  readonly host: Host<ServicePrincipal>;
  readonly baseId: string;
  readonly expectedToken: ServiceToken;
  /** The port the server actually listens on; validates the Host header. */
  readonly port: number;
  readonly links?: number;
  readonly callsPerLink?: number;
  readonly flowWindowBytes?: number;
  readonly flowPendingBytes?: number;
  readonly messageBytes?: number;
};

export type ServiceListener = {
  readonly linkCount: number;
  close(): Promise<void>;
};

type UpgradeRefusal = 400 | 401 | 403 | 404 | 405 | 431 | 503;

function headerBytes(request: IncomingMessage): number {
  let total = 0;
  for (const value of request.rawHeaders) {
    total += Buffer.byteLength(value, "utf8") + 4;
  }
  return total;
}

function singleHeader(
  request: IncomingMessage,
  name: string,
): string | undefined {
  const value = request.headers[name];
  return typeof value === "string" ? value : undefined;
}

/** Every refusal happens before a WebSocket or a Chord resource exists. */
export function upgradeRefusal(
  request: IncomingMessage,
  options: {
    baseId: string;
    expectedToken: ServiceToken;
    expectedHost: string;
    links: number;
    maxLinks: number;
  },
): UpgradeRefusal | undefined {
  if (headerBytes(request) > LOCAL_SERVICE_LIMITS.upgradeHeaderBytes) {
    return 431;
  }
  if (request.method !== "GET") return 405;
  if (request.url !== LOCAL_SERVICE_LINK_PATH) return 404;
  if (request.headers.origin !== undefined) return 403;
  if (singleHeader(request, "host") !== options.expectedHost) return 400;
  const base = singleHeader(request, "x-squad-base-id");
  if (base === undefined || base !== options.baseId) return 401;
  const authorization = singleHeader(request, "authorization");
  if (authorization === undefined) return 401;
  const match = /^Bearer ([0-9a-f]{64})$/.exec(authorization);
  if (match === null) return 401;
  if (!verifyToken(options.expectedToken, match[1])) return 401;
  if (options.links >= options.maxLinks) return 503;
  return undefined;
}

const REFUSAL_TEXT: Record<UpgradeRefusal, string> = {
  400: "Bad Request",
  401: "Unauthorized",
  403: "Forbidden",
  404: "Not Found",
  405: "Method Not Allowed",
  431: "Request Header Fields Too Large",
  503: "Service Unavailable",
};

function refuse(socket: Duplex, status: UpgradeRefusal): void {
  if (!socket.writable) {
    socket.destroy();
    return;
  }
  socket.end(
    `HTTP/1.1 ${status} ${REFUSAL_TEXT[status]}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n`,
  );
  socket.destroy();
}

/**
 * Attach the authenticated upgrade route and Chord client links to a listening
 * loopback server. Closing a link, or all of them, never stops the host.
 *
 * `acceptWebSockets` is deliberately not used: it hardcodes outgoing
 * compression, and this delivery disables optional compression.
 */
export async function attachServiceListener(
  options: ServiceListenerOptions,
): Promise<ServiceListener> {
  const maxLinks = options.links ?? LOCAL_SERVICE_LIMITS.links;
  const callsPerLink =
    options.callsPerLink ?? LOCAL_SERVICE_LIMITS.callsPerLink;
  const window =
    options.flowWindowBytes ?? LOCAL_SERVICE_LIMITS.flowWindowBytes;
  const pendingCap =
    options.flowPendingBytes ?? LOCAL_SERVICE_LIMITS.flowPendingBytes;
  const expectedHost = `127.0.0.1:${options.port}`;
  const sockets = new Set<WebSocket>();
  const principals = new WeakMap<IncomingMessage, ServicePrincipal>();
  let closed = false;

  const wss = new WebSocketServer({
    noServer: true,
    perMessageDeflate: false,
    maxPayload:
      options.messageBytes ?? LOCAL_SERVICE_LIMITS.websocketMessageBytes,
    clientTracking: false,
  });
  // A rejected frame is that link's problem: it closes, and the host survives.
  wss.on("error", () => undefined);

  const onUpgrade = (
    request: IncomingMessage,
    socket: Duplex,
    head: Buffer,
  ) => {
    socket.on("error", () => socket.destroy());
    const refusal = upgradeRefusal(request, {
      baseId: options.baseId,
      expectedToken: options.expectedToken,
      expectedHost,
      links: sockets.size,
      maxLinks,
    });
    if (refusal !== undefined) {
      refuse(socket, refusal);
      return;
    }
    const principal: ServicePrincipal = {
      kind: "local-client",
      baseId: options.baseId,
    };
    principals.set(request, principal);
    wss.handleUpgrade(request, socket, head, (ws) => {
      if (closed) {
        ws.close(1001, "service closing");
        return;
      }
      sockets.add(ws);
      ws.on("close", () => sockets.delete(ws));
      ws.on("error", () => {
        try {
          ws.terminate();
        } catch {
          // The socket is already gone.
        }
      });
      options.host.accept(
        webSocketLink(ws, { compress: false, acceptPacked: false }),
        {
          principal,
          kind: "client",
          maxCalls: callsPerLink,
          window,
          pendingCap,
        },
      );
    });
  };

  options.server.on("upgrade", onUpgrade);

  return {
    get linkCount() {
      return sockets.size;
    },
    async close() {
      if (closed) return;
      closed = true;
      options.server.off("upgrade", onUpgrade);
      for (const socket of sockets) {
        socket.close(1001, "service closing");
      }
      sockets.clear();
      await new Promise<void>((resolve) => {
        wss.close(() => resolve());
      });
    },
  };
}
