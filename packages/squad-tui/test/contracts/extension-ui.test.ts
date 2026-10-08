import { describe, expect, it } from "vitest";
import {
  CorrelationMismatchError,
  ContractValidationError,
} from "../../src/contracts/errors";
import {
  correlateExtensionUIResponse,
  parseExtensionUIRequest,
  parseExtensionUIResponseValue,
} from "../../src/contracts/extension-ui";

describe("parseExtensionUIRequest", () => {
  it("parses the real select dialog shape observed against Pi RPC (T02)", () => {
    const request = parseExtensionUIRequest({
      id: "req-1",
      method: "select",
      options: ["Allow", "Deny"],
    });
    expect(request.method).toBe("select");
  });

  it("parses confirm/input/editor dialog shapes", () => {
    expect(
      parseExtensionUIRequest({ id: "req-2", method: "confirm" }).method,
    ).toBe("confirm");
    expect(
      parseExtensionUIRequest({ id: "req-3", method: "input" }).method,
    ).toBe("input");
    expect(
      parseExtensionUIRequest({ id: "req-4", method: "editor" }).method,
    ).toBe("editor");
  });

  it("degrades an unrecognized extension UI method to unknown rather than throwing", () => {
    const request = parseExtensionUIRequest({
      id: "req-5",
      method: "future-dialog",
      extra: true,
    });
    expect(request.method).toBe("unknown");
    if (request.method !== "unknown") {
      throw new Error("expected unknown");
    }
    expect(request.rawMethod).toBe("future-dialog");
  });

  it("fails with a typed error on a structurally malformed request (no id)", () => {
    expect(() =>
      parseExtensionUIRequest({ method: "select", options: ["Allow"] }),
    ).toThrow(ContractValidationError);
  });

  it("fails with a typed error when a recognized method has a malformed payload instead of downgrading to unknown", () => {
    expect(() =>
      parseExtensionUIRequest({ id: "req-6", method: "select" }),
    ).toThrow(ContractValidationError);
    expect(() =>
      parseExtensionUIRequest({ id: "req-7", method: "select", options: [] }),
    ).toThrow(ContractValidationError);
    expect(() =>
      parseExtensionUIRequest({ id: "req-8", method: "confirm", prompt: "" }),
    ).toThrow(ContractValidationError);
  });

  it("degrades inherited Object.prototype keys used as methods to unknown instead of crashing", () => {
    for (const method of ["toString", "constructor", "valueOf", "__proto__"]) {
      const request = parseExtensionUIRequest({ id: "req-9", method });
      expect(request.method).toBe("unknown");
      if (request.method !== "unknown") {
        throw new Error("expected unknown");
      }
      expect(request.rawMethod).toBe(method);
    }
  });
});

describe("extension UI response correlation and values", () => {
  it("accepts a select response whose value is one of the offered options", () => {
    const request = parseExtensionUIRequest({
      id: "req-1",
      method: "select",
      options: ["Allow", "Deny"],
    });
    const value = parseExtensionUIResponseValue(request, {
      type: "extension_ui_response",
      id: "req-1",
      value: "Allow",
    });
    expect(value).toBe("Allow");
  });

  it("rejects a select response whose value was never offered", () => {
    const request = parseExtensionUIRequest({
      id: "req-1",
      method: "select",
      options: ["Allow", "Deny"],
    });
    expect(() =>
      parseExtensionUIResponseValue(request, {
        type: "extension_ui_response",
        id: "req-1",
        value: "Maybe",
      }),
    ).toThrow(ContractValidationError);
  });

  it("rejects a response whose id does not correlate to the originating request", () => {
    const request = parseExtensionUIRequest({ id: "req-1", method: "confirm" });
    expect(() =>
      correlateExtensionUIResponse(request, {
        type: "extension_ui_response",
        id: "req-2",
        value: true,
      }),
    ).toThrow(CorrelationMismatchError);
  });
});
