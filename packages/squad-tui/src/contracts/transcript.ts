import * as z from "zod";
import { parseContract } from "./errors";
import { SessionId } from "./identity";

export const MESSAGE_ROLES = ["user", "assistant", "system"] as const;
export const MessageRole = z.enum(MESSAGE_ROLES);
export type MessageRole = z.infer<typeof MessageRole>;

const MessageDeltaEvent = z.object({
  type: z.literal("message_delta"),
  role: MessageRole,
  text: z.string(),
});

const MessageCompleteEvent = z.object({
  type: z.literal("message_complete"),
  role: MessageRole,
  text: z.string(),
});

const ToolExecutionStartEvent = z.object({
  type: z.literal("tool_execution_start"),
  toolName: z.string().min(1),
  input: z.unknown(),
});

const ToolExecutionEndEvent = z.object({
  type: z.literal("tool_execution_end"),
  toolName: z.string().min(1),
  output: z.unknown(),
  exitCode: z.number().int().nullable(),
});

const AgentStartEvent = z.object({ type: z.literal("agent_start") });
const AgentEndEvent = z.object({ type: z.literal("agent_end") });
const AgentSettledEvent = z.object({ type: z.literal("agent_settled") });

const QueueUpdateEvent = z.object({
  type: z.literal("queue_update"),
  steering: z.array(z.string()),
  followUp: z.array(z.string()),
});

const CompactionStartEvent = z.object({
  type: z.literal("compaction_start"),
  reason: z.string().min(1),
});

const CompactionEndEvent = z.object({
  type: z.literal("compaction_end"),
  errorMessage: z.string().min(1).nullable(),
});

const AutoRetryStartEvent = z.object({
  type: z.literal("auto_retry_start"),
  attempt: z.number().int().nonnegative(),
});

const AutoRetryEndEvent = z.object({
  type: z.literal("auto_retry_end"),
  attempt: z.number().int().nonnegative(),
  succeeded: z.boolean(),
});

const ExtensionUIRequestEvent = z.object({
  type: z.literal("extension_ui_request"),
  requestPayload: z.unknown(),
});

const KnownTranscriptEventPayload = z.discriminatedUnion("type", [
  MessageDeltaEvent,
  MessageCompleteEvent,
  ToolExecutionStartEvent,
  ToolExecutionEndEvent,
  AgentStartEvent,
  AgentEndEvent,
  AgentSettledEvent,
  QueueUpdateEvent,
  CompactionStartEvent,
  CompactionEndEvent,
  AutoRetryStartEvent,
  AutoRetryEndEvent,
  ExtensionUIRequestEvent,
]);
export type KnownTranscriptEventPayload = z.infer<
  typeof KnownTranscriptEventPayload
>;

const RawTranscriptEventPayload = z
  .object({
    type: z.string().min(1),
  })
  .loose();

export type UnknownTranscriptEventPayload = {
  type: "unknown";
  rawType: string;
  raw: Record<string, unknown>;
};

export type TranscriptEventPayload =
  KnownTranscriptEventPayload | UnknownTranscriptEventPayload;

export function parseTranscriptEventPayload(
  input: unknown,
): TranscriptEventPayload {
  const known = KnownTranscriptEventPayload.safeParse(input);
  if (known.success) {
    return known.data;
  }
  const raw = parseContract(
    "TranscriptEventPayload",
    RawTranscriptEventPayload,
    input,
  );
  return { type: "unknown", rawType: raw.type, raw };
}

const TranscriptEventEnvelopeShape = z.object({
  schemaVersion: z.literal(1),
  sessionId: SessionId,
  sequence: z.number().int().nonnegative(),
  timestamp: z.iso.datetime(),
  payload: z.unknown(),
});

export type TranscriptEvent = Omit<
  z.infer<typeof TranscriptEventEnvelopeShape>,
  "payload"
> & {
  payload: TranscriptEventPayload;
};

export function parseTranscriptEvent(input: unknown): TranscriptEvent {
  const envelope = parseContract(
    "TranscriptEventEnvelope",
    TranscriptEventEnvelopeShape,
    input,
  );
  return {
    ...envelope,
    payload: parseTranscriptEventPayload(envelope.payload),
  };
}
