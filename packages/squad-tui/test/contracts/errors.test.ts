import * as z from "zod";
import { describe, expect, it } from "vitest";
import {
  ContractValidationError,
  parseContract,
  UnsupportedSchemaVersionError,
} from "../../src/contracts/errors";

describe("parseContract", () => {
  const schema = z.object({ name: z.string().min(1) });

  it("returns the parsed value on success", () => {
    expect(parseContract("Example", schema, { name: "ok" })).toEqual({
      name: "ok",
    });
  });

  it("throws a ContractValidationError naming the schema and the failing path on malformed input", () => {
    try {
      parseContract("Example", schema, { name: "" });
      throw new Error("expected parseContract to throw");
    } catch (error) {
      expect(error).toBeInstanceOf(ContractValidationError);
      expect((error as ContractValidationError).schemaName).toBe("Example");
      expect((error as ContractValidationError).issues.length).toBeGreaterThan(
        0,
      );
    }
  });
});

describe("UnsupportedSchemaVersionError", () => {
  it("names the schema, the received version, and the supported versions", () => {
    const error = new UnsupportedSchemaVersionError("Example", 9, [0, 1]);
    expect(error.schemaName).toBe("Example");
    expect(error.receivedVersion).toBe(9);
    expect(error.supportedVersions).toEqual([0, 1]);
  });
});
