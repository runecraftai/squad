import * as z from "zod";

export const TaskId = z.string().min(1).brand<"TaskId">();
export type TaskId = z.infer<typeof TaskId>;

export const AttemptId = z.string().min(1).brand<"AttemptId">();
export type AttemptId = z.infer<typeof AttemptId>;

export const SessionId = z.string().min(1).brand<"SessionId">();
export type SessionId = z.infer<typeof SessionId>;

export const OperationalBaseId = z.string().min(1).brand<"OperationalBaseId">();
export type OperationalBaseId = z.infer<typeof OperationalBaseId>;

export const AbsolutePath = z
  .string()
  .min(1)
  .refine((value) => value.startsWith("/"), {
    message:
      "must be an absolute path, never an inherited relative/ambient cwd",
  })
  .brand<"AbsolutePath">();
export type AbsolutePath = z.infer<typeof AbsolutePath>;
