import * as z from "zod";
import { CommandAcceptance, CommandEnvelope, EntityKind } from "./envelope.ts";

/** Version of this local-service wire surface, independent of the package version. */
export const LOCAL_SERVICE_SCHEMA_VERSION = 1;
/** Contract name and version of the Chord facet that carries this service. */
export const LOCAL_SERVICE_CONTRACT_NAME = "squad.local-service";
export const LOCAL_SERVICE_CONTRACT_VERSION = 1;
/** The one loopback upgrade route this first delivery serves. */
export const LOCAL_SERVICE_LINK_PATH = "/v1/link";

/**
 * Every bound this surface promises. The transport enforces them; they are
 * exported so clients and tests read the same numbers the service applies.
 */
export const LOCAL_SERVICE_LIMITS = {
  /** Serialized bytes allowed for one upgrade request's headers. */
  upgradeHeaderBytes: 8 * 1024,
  /** Milliseconds allowed to deliver the upgrade request's headers. */
  upgradeHeaderTimeoutMs: 5_000,
  /** Decoded bytes allowed for one RPC argument object. */
  rpcArgumentBytes: 64 * 1024,
  /** Bytes allowed for one WebSocket message before the socket is closed. */
  websocketMessageBytes: 1024 * 1024,
  /** Authenticated links one service accepts at a time. */
  links: 8,
  /** Concurrent calls one link may have in progress. */
  callsPerLink: 4,
  /** Unacknowledged bytes a link may hold before state waits. */
  flowWindowBytes: 256 * 1024,
  /** State ops a link may hold before the library replaces a stream with a reset. */
  flowPendingBytes: 4 * 256 * 1024,
  /** Bytes allowed for the credential file, including its trailing newline. */
  tokenFileBytes: 65,
  /** Bytes allowed for the endpoint descriptor file. */
  descriptorFileBytes: 1024,
} as const;

export const BASE_ID_PATTERN = /^[0-9a-f]{64}$/;
export const SERVICE_TOKEN_PATTERN = /^[0-9a-f]{64}$/;
export const BOUNDED_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

/**
 * `sha256` of the canonical absolute base directory, in lowercase hex.
 * This is the only base identity the wire carries; it never carries a path.
 */
export const ServiceBaseId = z.string().regex(BASE_ID_PATTERN);
export type ServiceBaseId = z.infer<typeof ServiceBaseId>;

export const ServiceInstanceId = z.uuid();
export type ServiceInstanceId = z.infer<typeof ServiceInstanceId>;

/** Request, target and correlation identifiers stay short and ASCII. */
export const BoundedId = z.string().regex(BOUNDED_ID_PATTERN);
export type BoundedId = z.infer<typeof BoundedId>;

/** The local credential value: 32 random bytes as 64 lowercase hex characters. */
export const ServiceToken = z.string().regex(SERVICE_TOKEN_PATTERN);
export type ServiceToken = z.infer<typeof ServiceToken>;

/**
 * Chord facet input. `schemaVersion` is bounded rather than literal so a newer
 * client reaches a fixed `unsupported-version` refusal instead of a schema error.
 */
export const ServiceSelector = z.strictObject({
  schemaVersion: z.number().int().min(1).max(65535),
  baseId: ServiceBaseId,
});
export type ServiceSelector = z.infer<typeof ServiceSelector>;

export const SERVICE_REFUSAL_CODES = [
  "unauthenticated",
  "base-mismatch",
  "unsupported-version",
  "invalid-request",
  "operation-unavailable",
  "limit-exceeded",
  "service-unavailable",
] as const;
export const ServiceRefusalCode = z.enum(SERVICE_REFUSAL_CODES);
export type ServiceRefusalCode = z.infer<typeof ServiceRefusalCode>;

/** A refusal carries its fixed code and nothing derived from untrusted input. */
export const ServiceRefusal = z.strictObject({ code: ServiceRefusalCode });
export type ServiceRefusal = z.infer<typeof ServiceRefusal>;

/** Fixed, secret-free startup failures. `main` maps each to one exit path. */
export const SERVICE_FAILURE_CODES = [
  "usage",
  "invalid-base",
  "base-mismatch",
  "unsupported-runtime",
  "lock-unavailable",
  "service-already-running",
  "unsafe-credential",
  "credential-unreadable",
  "invalid-port",
  "listen-failed",
  "descriptor-failed",
  "internal",
] as const;
export const ServiceFailureCode = z.enum(SERVICE_FAILURE_CODES);
export type ServiceFailureCode = z.infer<typeof ServiceFailureCode>;

/** Fixed remedies keyed by failure code; no library text or request value is forwarded. */
export const SERVICE_FAILURE_DIAGNOSTICS: Record<ServiceFailureCode, string> = {
  usage:
    "pass serve --base <absolute-path> [--port <1-65535>] or rotate-credential --base <absolute-path>",
  "invalid-base": "pass an existing absolute directory with --base",
  "base-mismatch": "SQUAD_BASE conflicts with --base; pass one explicit base",
  "unsupported-runtime":
    "run this service with Node 22.19 or newer; Bun is not a supported service runtime",
  "lock-unavailable":
    "the kernel lock facility is unavailable; no PID-file fallback exists",
  "service-already-running":
    "another service owns this base; attach using this base's endpoint descriptor",
  "unsafe-credential":
    "check ownership, mode and file type of the credential directory and token; no file was replaced",
  "credential-unreadable":
    "read the credential file as the owning user; it must be 64 hex characters plus a newline",
  "invalid-port":
    "pass an integer port between 1 and 65535, or omit --port for an OS-assigned port",
  "listen-failed":
    "check the explicitly requested loopback port and bind address",
  "descriptor-failed":
    "check ownership, mode and file type of this base's state/squad-tui directory",
  internal: "the service stopped on an unexpected error; no secret was logged",
};

export class LocalServiceFailure extends Error {
  readonly code: ServiceFailureCode;
  readonly diagnostic: string;

  constructor(code: ServiceFailureCode) {
    const diagnostic = SERVICE_FAILURE_DIAGNOSTICS[code];
    super(diagnostic);
    this.name = "LocalServiceFailure";
    this.code = code;
    this.diagnostic = diagnostic;
  }
}

export function isLocalServiceFailure(
  error: unknown,
): error is LocalServiceFailure {
  return error instanceof LocalServiceFailure;
}

/**
 * What the service may currently promise. Projections and operational commands
 * belong to later tasks; this delivery reports them as unavailable explicitly
 * instead of publishing empty missions, sessions or commands.
 */
export const ServiceAvailability = z.strictObject({
  projections: z.strictObject({
    available: z.literal(false),
    reason: z.string().min(1).max(200),
  }),
  commands: z.strictObject({
    available: z.literal(false),
    reason: z.string().min(1).max(200),
  }),
});
export type ServiceAvailability = z.infer<typeof ServiceAvailability>;

export const SERVICE_UNAVAILABLE_REASON =
  "not implemented in this service version; no operational store or agent owner exists here";

export const serviceAvailability = (): ServiceAvailability => ({
  projections: { available: false, reason: SERVICE_UNAVAILABLE_REASON },
  commands: { available: false, reason: SERVICE_UNAVAILABLE_REASON },
});

/** The replicated service view every authenticated matching-base client receives. */
export const ServiceView = z.strictObject({
  schemaVersion: z.literal(LOCAL_SERVICE_SCHEMA_VERSION),
  baseId: ServiceBaseId,
  serviceInstanceId: ServiceInstanceId,
  startedAt: z.iso.datetime(),
  readiness: z.literal("ready"),
  availability: ServiceAvailability,
});
export type ServiceView = z.infer<typeof ServiceView>;

export const SERVICE_READS = ["view", "capabilities"] as const;
export const ServiceRead = z.enum(SERVICE_READS);
export type ServiceRead = z.infer<typeof ServiceRead>;

export const SERVICE_FEATURES = [
  "projections",
  "sessions",
  "missions",
  "tasks",
  "decisions",
  "commands",
] as const;
export const ServiceFeature = z.enum(SERVICE_FEATURES);
export type ServiceFeature = z.infer<typeof ServiceFeature>;

export const UnavailableFeature = z.strictObject({
  feature: ServiceFeature,
  reason: z.string().min(1).max(200),
});
export type UnavailableFeature = z.infer<typeof UnavailableFeature>;

export const ServiceCapabilities = z.strictObject({
  schemaVersion: z.literal(LOCAL_SERVICE_SCHEMA_VERSION),
  baseId: ServiceBaseId,
  serviceInstanceId: ServiceInstanceId,
  reads: z.array(ServiceRead).min(1).max(SERVICE_READS.length),
  commands: z.strictObject({
    available: z.literal(false),
    reason: z.string().min(1).max(200),
  }),
  unavailable: z.array(UnavailableFeature).max(SERVICE_FEATURES.length),
});
export type ServiceCapabilities = z.infer<typeof ServiceCapabilities>;

export const CapabilitiesRequest = ServiceSelector;
export type CapabilitiesRequest = z.infer<typeof CapabilitiesRequest>;

export const CapabilitiesResult = z.discriminatedUnion("ok", [
  z.strictObject({
    ok: z.literal(true),
    capabilities: ServiceCapabilities,
  }),
  z.strictObject({ ok: z.literal(false), refusal: ServiceRefusal }),
]);
export type CapabilitiesResult = z.infer<typeof CapabilitiesResult>;

/**
 * Reserved operation names T08/T11/T20 will own. T07 accepts the name and then
 * refuses it: no transport callback may execute a project command here.
 */
export const RESERVED_OPERATIONS = [
  "prompt",
  "steer",
  "cancel",
  "requestMission",
  "answerDecision",
] as const;
export const ReservedOperation = z.enum(RESERVED_OPERATIONS);
export type ReservedOperation = z.infer<typeof ReservedOperation>;

/** T07's reserved payload: an operation name, never text, files or a revision claim. */
export const ExecutePayload = z.strictObject({
  operation: z.string().min(1).max(128),
});
export type ExecutePayload = z.infer<typeof ExecutePayload>;

/** The existing command envelope with the strict bounds this transport requires. */
export const ServiceCommand = z.strictObject({
  ...CommandEnvelope.shape,
  requestId: BoundedId,
  target: z.strictObject({ kind: EntityKind, id: BoundedId }),
  payload: ExecutePayload,
});
export type ServiceCommand = z.infer<typeof ServiceCommand>;

export const ExecuteRequest = z.strictObject({
  schemaVersion: z.number().int().min(1).max(65535),
  baseId: ServiceBaseId,
  command: ServiceCommand,
});
export type ExecuteRequest = z.infer<typeof ExecuteRequest>;

export const ExecuteResult = z.discriminatedUnion("ok", [
  z.strictObject({
    ok: z.literal(true),
    acceptance: z.strictObject({
      ...CommandAcceptance.shape,
      requestId: BoundedId,
      accepted: z.literal(false),
      revision: z.literal(null),
      error: ServiceRefusalCode,
    }),
  }),
  z.strictObject({ ok: z.literal(false), refusal: ServiceRefusal }),
]);
export type ExecuteResult = z.infer<typeof ExecuteResult>;

/** Discovery information only: never the exclusivity lock, token or authority claim. */
/**
 * T07's only execute outcome: the command is understood, and every reserved
 * operation is explicitly unavailable. No acceptance implies execution.
 */
export function operationUnavailableAcceptance(
  requestId: string,
): Extract<ExecuteResult, { ok: true }>["acceptance"] {
  return {
    requestId,
    accepted: false,
    revision: null,
    error: "operation-unavailable",
  };
}

export const EndpointDescriptor = z.strictObject({
  schemaVersion: z.literal(LOCAL_SERVICE_SCHEMA_VERSION),
  baseId: ServiceBaseId,
  serviceInstanceId: ServiceInstanceId,
  pid: z.number().int().positive(),
  port: z.number().int().min(1).max(65535),
  startedAt: z.iso.datetime(),
});
export type EndpointDescriptor = z.infer<typeof EndpointDescriptor>;

/** Private location of the credential and descriptor inside one canonical base. */
export const SERVICE_CREDENTIAL_DIRECTORY = "config/squad-tui";
export const SERVICE_CREDENTIAL_FILE = "service-token";
export const SERVICE_ENDPOINT_DIRECTORY = "state/squad-tui";
export const SERVICE_ENDPOINT_FILE = "endpoint.json";
