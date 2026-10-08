import * as z from "zod";
import { BackendKind } from "./capabilities";
import { ExecutionState } from "./execution-state";
import {
  AbsolutePath,
  AttemptId,
  OperationalBaseId,
  SessionId,
  TaskId,
} from "./identity";
import { parseVersionedContract } from "./version";

export const HARNESS_KINDS = [
  "claude",
  "codex",
  "opencode",
  "pi",
  "pi-signed",
  "grok",
  "kimi",
  "muse",
  "unknown",
] as const;
export const HarnessKind = z.enum(HARNESS_KINDS);
export type HarnessKind = z.infer<typeof HarnessKind>;

export const SESSION_ORIGINS = [
  "interactive-primary",
  "squad-dispatch",
  "service-managed-pi-rpc",
  "diagnostic-attach",
  "unknown",
] as const;
export const SessionOrigin = z.enum(SESSION_ORIGINS);
export type SessionOrigin = z.infer<typeof SessionOrigin>;

export const LinkedTaskRef = z.object({
  taskId: TaskId,
  attemptId: AttemptId.nullable(),
});
export type LinkedTaskRef = z.infer<typeof LinkedTaskRef>;

export const SessionHealth = z.object({
  leafCount: z.number().int().nonnegative().nullable(),
});
export type SessionHealth = z.infer<typeof SessionHealth>;

export function hasForkDrift(health: SessionHealth): boolean {
  return health.leafCount !== null && health.leafCount > 1;
}

export const PiProcessConfig = z.object({
  cwd: AbsolutePath,
  sessionId: SessionId,
  sessionDir: AbsolutePath,
  extensions: z.array(AbsolutePath),
});
export type PiProcessConfig = z.infer<typeof PiProcessConfig>;

export const Session = z.object({
  schemaVersion: z.literal(1),
  sessionId: SessionId,
  baseId: OperationalBaseId,
  role: z.string().min(1),
  harness: HarnessKind,
  backend: BackendKind,
  origin: SessionOrigin,
  state: ExecutionState,
  linkedTask: LinkedTaskRef.nullable(),
  health: SessionHealth.nullable(),
  piProcess: PiProcessConfig.nullable(),
});
export type Session = z.infer<typeof Session>;

const SessionV0 = z.object({
  schemaVersion: z.literal(0),
  sessionId: SessionId,
  baseId: OperationalBaseId,
  role: z.string().min(1),
  harness: HarnessKind,
  backend: BackendKind,
  origin: SessionOrigin,
  state: ExecutionState,
  linkedTask: LinkedTaskRef.nullable(),
});

function migrateSessionV0ToV1(value: z.infer<typeof SessionV0>): Session {
  return { ...value, schemaVersion: 1, health: null, piProcess: null };
}

export function parseSession(input: unknown): Session {
  return parseVersionedContract(
    "Session",
    { version: 1, schema: Session },
    { version: 0, schema: SessionV0, migrate: migrateSessionV0ToV1 },
    input,
  );
}
