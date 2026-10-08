import * as z from "zod";
import { ExecutionState } from "./execution-state";
import { TaskId } from "./identity";
import { Stage } from "./stage";

export const Mission = z.object({
  schemaVersion: z.literal(1),
  missionId: TaskId,
  title: z.string().min(1),
  linkedTaskIds: z.array(TaskId),
  stages: z.array(Stage),
  state: ExecutionState,
});
export type Mission = z.infer<typeof Mission>;
