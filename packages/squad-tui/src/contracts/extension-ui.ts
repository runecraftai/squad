import * as z from "zod";
import { CorrelationMismatchError, parseContract } from "./errors";

const ExtensionUIRequestBase = z.object({
  id: z.string().min(1),
  prompt: z.string().min(1).optional(),
});

export const SelectExtensionUIRequest = ExtensionUIRequestBase.extend({
  method: z.literal("select"),
  options: z.array(z.string().min(1)).min(1),
});

export const ConfirmExtensionUIRequest = ExtensionUIRequestBase.extend({
  method: z.literal("confirm"),
});

export const InputExtensionUIRequest = ExtensionUIRequestBase.extend({
  method: z.literal("input"),
  placeholder: z.string().min(1).optional(),
});

export const EditorExtensionUIRequest = ExtensionUIRequestBase.extend({
  method: z.literal("editor"),
  initialValue: z.string().optional(),
});

const ExtensionUIRequestByMethod = {
  select: SelectExtensionUIRequest,
  confirm: ConfirmExtensionUIRequest,
  input: InputExtensionUIRequest,
  editor: EditorExtensionUIRequest,
} as const;

type KnownExtensionUIMethod = keyof typeof ExtensionUIRequestByMethod;

function isKnownExtensionUIMethod(
  method: string,
): method is KnownExtensionUIMethod {
  return Object.hasOwn(ExtensionUIRequestByMethod, method);
}

const RawExtensionUIRequest = z
  .object({
    id: z.string().min(1),
    method: z.string().min(1),
  })
  .loose();

export type KnownExtensionUIRequest = z.infer<
  (typeof ExtensionUIRequestByMethod)[KnownExtensionUIMethod]
>;

export type UnknownExtensionUIRequest = {
  method: "unknown";
  rawMethod: string;
  id: string;
  raw: Record<string, unknown>;
};

export type ExtensionUIRequest =
  KnownExtensionUIRequest | UnknownExtensionUIRequest;

function readExtensionUIMethod(input: unknown): unknown {
  if (typeof input !== "object" || input === null) {
    return undefined;
  }
  return (input as { method?: unknown }).method;
}

export function parseExtensionUIRequest(input: unknown): ExtensionUIRequest {
  const method = readExtensionUIMethod(input);
  if (typeof method === "string" && isKnownExtensionUIMethod(method)) {
    return parseContract(
      "ExtensionUIRequest",
      ExtensionUIRequestByMethod[method],
      input,
    );
  }
  const raw = parseContract("ExtensionUIRequest", RawExtensionUIRequest, input);
  return { method: "unknown", rawMethod: raw.method, id: raw.id, raw };
}

export const ExtensionUIResponse = z.object({
  type: z.literal("extension_ui_response"),
  id: z.string().min(1),
  value: z.unknown(),
});
export type ExtensionUIResponse = z.infer<typeof ExtensionUIResponse>;

export function correlateExtensionUIResponse(
  request: ExtensionUIRequest,
  response: ExtensionUIResponse,
): void {
  if (request.id !== response.id) {
    throw new CorrelationMismatchError(
      "ExtensionUIResponse",
      request.id,
      response.id,
    );
  }
}

export function parseExtensionUIResponseValue(
  request: ExtensionUIRequest,
  response: ExtensionUIResponse,
): string | boolean | Record<string, unknown> {
  correlateExtensionUIResponse(request, response);
  switch (request.method) {
    case "select": {
      const allowed = z.enum(request.options as [string, ...string[]]);
      return parseContract(
        "ExtensionUIResponse.select.value",
        allowed,
        response.value,
      );
    }
    case "confirm":
      return parseContract(
        "ExtensionUIResponse.confirm.value",
        z.boolean(),
        response.value,
      );
    case "input":
    case "editor":
      return parseContract(
        "ExtensionUIResponse.text.value",
        z.string(),
        response.value,
      );
    case "unknown":
      return (response.value ?? {}) as Record<string, unknown>;
  }
}
