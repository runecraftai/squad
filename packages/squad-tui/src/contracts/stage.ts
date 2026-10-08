import * as z from "zod";
import { DrillRunRef, DrillStepName } from "./drill-run";
import { ExecutionState } from "./execution-state";
import { AttemptId, SessionId, TaskId } from "./identity";

export const STAGE_KINDS = [
  "drill-pipeline-step",
  "deterministic-command",
  "agent-step",
] as const;
export const StageKind = z.enum(STAGE_KINDS);
export type StageKind = z.infer<typeof StageKind>;

export const Stage = z
  .object({
    schemaVersion: z.literal(1),
    taskId: TaskId,
    attemptId: AttemptId.nullable(),
    kind: StageKind,
    drillStepName: DrillStepName.nullable(),
    drillRunRef: DrillRunRef.nullable(),
    state: ExecutionState,
    session: SessionId.nullable(),
  })
  .superRefine((value, ctx) => {
    const isDrillStep = value.kind === "drill-pipeline-step";
    if (isDrillStep && value.drillStepName === null) {
      ctx.addIssue({
        code: "custom",
        path: ["drillStepName"],
        message: "drill-pipeline-step stages must name a drill step",
      });
    }
    if (isDrillStep && value.drillRunRef === null) {
      ctx.addIssue({
        code: "custom",
        path: ["drillRunRef"],
        message: "drill-pipeline-step stages must reference a drill run",
      });
    }
    if (!isDrillStep && value.drillStepName !== null) {
      ctx.addIssue({
        code: "custom",
        path: ["drillStepName"],
        message: "only drill-pipeline-step stages may name a drill step",
      });
    }
    if (!isDrillStep && value.drillRunRef !== null) {
      ctx.addIssue({
        code: "custom",
        path: ["drillRunRef"],
        message: "only drill-pipeline-step stages may reference a drill run",
      });
    }
  });
export type Stage = z.infer<typeof Stage>;
