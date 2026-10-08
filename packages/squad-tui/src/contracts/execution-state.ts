import * as z from "zod";

export const EXECUTION_STATES = [
  "queued",
  "running",
  "blocked",
  "succeeded",
  "failed",
  "cancelling",
  "cancelled",
  "interrupted",
  "unknown",
] as const;

export const ExecutionState = z.enum(EXECUTION_STATES);
export type ExecutionState = z.infer<typeof ExecutionState>;

export function coerceExecutionState(raw: unknown): ExecutionState {
  const result = ExecutionState.safeParse(raw);
  if (result.success) {
    return result.data;
  }
  return "unknown";
}
