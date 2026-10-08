import { describe, expect, it } from "vitest";
import {
  AdapterCapabilityDescriptor,
  resolveCapabilitySupport,
} from "../../src/contracts/capabilities";
import {
  ContractValidationError,
  parseContract,
} from "../../src/contracts/errors";
import {
  legacyMissingKeysCapabilityFixture,
  tmuxCapabilityFixture,
  tuiosCapabilityFixture,
} from "../fixtures/capabilities";

describe("AdapterCapabilityDescriptor", () => {
  it("accepts the real tmux capability matrix", () => {
    expect(AdapterCapabilityDescriptor.parse(tmuxCapabilityFixture)).toEqual(
      tmuxCapabilityFixture,
    );
  });

  it("accepts the real TUIOS capability matrix, including unknown-not-unsupported entries", () => {
    const parsed = AdapterCapabilityDescriptor.parse(tuiosCapabilityFixture);
    expect(resolveCapabilitySupport(parsed, "sendKeyEscape")).toBe("unknown");
    expect(resolveCapabilitySupport(parsed, "structuredAgentReport")).toBe(
      "supported",
    );
  });

  it("treats a capability absent from the descriptor as unknown, never a silent unsupported/supported guess", () => {
    const parsed = AdapterCapabilityDescriptor.parse(
      legacyMissingKeysCapabilityFixture,
    );
    expect(resolveCapabilitySupport(parsed, "workspaceLeasing")).toBe(
      "unknown",
    );
  });

  it("parses a legacy descriptor missing newer capability keys without failing (schema evolution)", () => {
    expect(() =>
      AdapterCapabilityDescriptor.parse(legacyMissingKeysCapabilityFixture),
    ).not.toThrow();
  });

  it("fails with a typed error on a malformed capability level", () => {
    const malformed = {
      ...tmuxCapabilityFixture,
      capabilities: {
        ...tmuxCapabilityFixture.capabilities,
        launch: { level: "maybe" },
      },
    };
    const result = AdapterCapabilityDescriptor.safeParse(malformed);
    expect(result.success).toBe(false);
  });

  it("rejects an unsupported schemaVersion", () => {
    const result = AdapterCapabilityDescriptor.safeParse({
      ...tmuxCapabilityFixture,
      schemaVersion: 2,
    });
    expect(result.success).toBe(false);
  });

  it("surfaces ContractValidationError through the shared parse helper for a malformed descriptor", () => {
    expect(() =>
      parseContract(
        "AdapterCapabilityDescriptor",
        AdapterCapabilityDescriptor,
        { backend: "tmux" },
      ),
    ).toThrow(ContractValidationError);
  });
});
