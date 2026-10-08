import * as z from "zod";
import { AbsolutePath } from "./identity";

export const DrillIdentity = z.object({
  repoId: z.string().min(1),
  gatePath: AbsolutePath,
});
export type DrillIdentity = z.infer<typeof DrillIdentity>;
