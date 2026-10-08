import * as z from "zod";
import { DrillIdentity } from "./drill-identity";

export const DRILL_STEP_NAMES = [
  "intent",
  "rebase",
  "review",
  "test",
  "document",
  "lint",
  "push",
  "pr",
  "ci",
] as const;
export const DrillStepName = z.enum(DRILL_STEP_NAMES);
export type DrillStepName = z.infer<typeof DrillStepName>;

export const DRILL_STEP_STATUSES = [
  "pending",
  "running",
  "awaiting_approval",
  "fixing",
  "fix_review",
  "completed",
  "skipped",
  "failed",
] as const;
export const DrillStepStatus = z.enum(DRILL_STEP_STATUSES);
export type DrillStepStatus = z.infer<typeof DrillStepStatus>;

export const DRILL_RUN_STATUSES = [
  "pending",
  "running",
  "completed",
  "failed",
  "cancelled",
] as const;
export const DrillRunStatus = z.enum(DRILL_RUN_STATUSES);
export type DrillRunStatus = z.infer<typeof DrillRunStatus>;

export const DRILL_APPROVAL_ACTIONS = [
  "approve",
  "fix",
  "skip",
  "abort",
] as const;
export const DrillApprovalAction = z.enum(DRILL_APPROVAL_ACTIONS);
export type DrillApprovalAction = z.infer<typeof DrillApprovalAction>;

export const DrillStepRow = z.object({
  name: DrillStepName,
  status: DrillStepStatus,
});
export type DrillStepRow = z.infer<typeof DrillStepRow>;

export const DrillRunRef = z.object({
  drillIdentity: DrillIdentity,
  runId: z.string().min(1),
});
export type DrillRunRef = z.infer<typeof DrillRunRef>;

export const DrillRunInfo = z.object({
  schemaVersion: z.literal(1),
  id: z.string().min(1),
  drillIdentity: DrillIdentity,
  branch: z.string().min(1),
  headSha: z.string().min(1),
  submittedHeadSha: z.string().min(1).nullable(),
  baseSha: z.string().min(1).nullable(),
  status: DrillRunStatus,
  prUrl: z.string().min(1).nullable(),
  error: z.string().min(1).nullable(),
  ciReady: z.boolean(),
  ciReadyNoCi: z.boolean(),
  awaitingAgent: z.boolean(),
  awaitingAgentSince: z.iso.datetime().nullable(),
  steps: z.array(DrillStepRow),
});
export type DrillRunInfo = z.infer<typeof DrillRunInfo>;
