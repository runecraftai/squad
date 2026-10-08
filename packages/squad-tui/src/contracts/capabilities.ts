import * as z from "zod";

export const BACKEND_KINDS = [
  "tmux",
  "tuios",
  "herdr",
  "orca",
  "cmux",
  "unknown",
] as const;
export const BackendKind = z.enum(BACKEND_KINDS);
export type BackendKind = z.infer<typeof BackendKind>;

export const CAPABILITY_IDS = [
  "launch",
  "sendText",
  "sendKeyEscape",
  "sendKeyEnter",
  "sendKeyCtrlC",
  "diagnosticAttach",
  "liveness",
  "resumeAfterDisconnect",
  "structuredAgentReport",
  "sendQueueStalledDetection",
  "workspaceLeasing",
] as const;
export const CapabilityId = z.enum(CAPABILITY_IDS);
export type CapabilityId = z.infer<typeof CapabilityId>;

export const CAPABILITY_SUPPORT_LEVELS = [
  "supported",
  "unsupported",
  "unknown",
] as const;
export const CapabilitySupportLevel = z.enum(CAPABILITY_SUPPORT_LEVELS);
export type CapabilitySupportLevel = z.infer<typeof CapabilitySupportLevel>;

export const CapabilitySupport = z.object({
  level: CapabilitySupportLevel,
  note: z.string().min(1).optional(),
});
export type CapabilitySupport = z.infer<typeof CapabilitySupport>;

export const AdapterCapabilityDescriptor = z.object({
  schemaVersion: z.literal(1),
  backend: BackendKind,
  backendVersion: z.string().min(1),
  capabilities: z.partialRecord(CapabilityId, CapabilitySupport),
});
export type AdapterCapabilityDescriptor = z.infer<
  typeof AdapterCapabilityDescriptor
>;

export function resolveCapabilitySupport(
  descriptor: AdapterCapabilityDescriptor,
  capability: CapabilityId,
): CapabilitySupportLevel {
  const entry = descriptor.capabilities[capability];
  if (entry === undefined) {
    return "unknown";
  }
  return entry.level;
}
