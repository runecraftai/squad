import * as z from "zod";
import { OperationalBaseId, SessionId } from "./identity";

export const SESSION_LOCK_MODES = ["create", "attach"] as const;
export const SessionLockMode = z.enum(SESSION_LOCK_MODES);
export type SessionLockMode = z.infer<typeof SessionLockMode>;

export const SessionLockRequest = z.object({
  schemaVersion: z.literal(1),
  baseId: OperationalBaseId,
  sessionId: SessionId,
  mode: SessionLockMode,
  requesterId: z.string().min(1),
});
export type SessionLockRequest = z.infer<typeof SessionLockRequest>;

export const SessionLockGrant = z.object({
  outcome: z.literal("granted"),
  sessionId: SessionId,
  holderId: z.string().min(1),
  acquiredAt: z.iso.datetime(),
});
export type SessionLockGrant = z.infer<typeof SessionLockGrant>;

export const SESSION_LOCK_REJECTION_REASONS = [
  "already-held",
  "create-race-lost",
  "attach-race-fork-detected",
  "unknown-session",
] as const;
export const SessionLockRejectionReason = z.enum(
  SESSION_LOCK_REJECTION_REASONS,
);
export type SessionLockRejectionReason = z.infer<
  typeof SessionLockRejectionReason
>;

export const SessionLockRejection = z.object({
  outcome: z.literal("rejected"),
  reason: SessionLockRejectionReason,
  heldBy: z.string().min(1).nullable(),
});
export type SessionLockRejection = z.infer<typeof SessionLockRejection>;

export const SessionLockResult = z.discriminatedUnion("outcome", [
  SessionLockGrant,
  SessionLockRejection,
]);
export type SessionLockResult = z.infer<typeof SessionLockResult>;
