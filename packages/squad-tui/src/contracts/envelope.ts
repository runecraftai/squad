import * as z from "zod";

export const ENTITY_KINDS = [
  "session",
  "mission",
  "stage",
  "decision",
  "artifact",
] as const;
export const EntityKind = z.enum(ENTITY_KINDS);
export type EntityKind = z.infer<typeof EntityKind>;

export const EntityRef = z.object({
  kind: EntityKind,
  id: z.string().min(1),
});
export type EntityRef = z.infer<typeof EntityRef>;

export const CommandEnvelope = z.object({
  schemaVersion: z.literal(1),
  requestId: z.string().min(1),
  target: EntityRef,
  payload: z.unknown(),
});
export type CommandEnvelope = z.infer<typeof CommandEnvelope>;

export const CommandAcceptance = z.object({
  requestId: z.string().min(1),
  accepted: z.boolean(),
  revision: z.string().min(1).nullable(),
  error: z.string().min(1).nullable(),
});
export type CommandAcceptance = z.infer<typeof CommandAcceptance>;

export const EVENT_TYPES = [
  "mission.updated",
  "task.updated",
  "stage.updated",
  "session.updated",
  "decision.requested",
  "decision.resolved",
  "artifact.created",
  "run.usage",
] as const;
export const EventType = z.enum(EVENT_TYPES);
export type EventType = z.infer<typeof EventType>;

export const EventEnvelope = z.object({
  schemaVersion: z.literal(1),
  eventId: z.string().min(1),
  sequence: z.number().int().nonnegative(),
  timestamp: z.iso.datetime(),
  entity: EntityRef,
  type: EventType,
  payload: z.unknown(),
});
export type EventEnvelope = z.infer<typeof EventEnvelope>;
