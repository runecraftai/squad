import { describe, expect, it } from "vitest";
import {
  ContractValidationError,
  UnsupportedSchemaVersionError,
} from "../../src/contracts/errors";
import { hasForkDrift, parseSession } from "../../src/contracts/session";
import {
  sessionMalformedFixture,
  sessionUnsupportedVersionFixture,
  sessionV0LegacyFixture,
  sessionV1Fixture,
} from "../fixtures/session";

describe("parseSession", () => {
  it("parses a current v1 session and keeps role/harness/backend/origin as separate fields", () => {
    const session = parseSession(sessionV1Fixture);
    expect(session.role).toBe("orchestrator");
    expect(session.harness).toBe("pi");
    expect(session.backend).toBe("tmux");
    expect(session.origin).toBe("interactive-primary");
  });

  it("migrates a legacy v0 fixture (predating health/piProcess) to the current shape", () => {
    const session = parseSession(sessionV0LegacyFixture);
    expect(session.schemaVersion).toBe(1);
    expect(session.health).toBeNull();
    expect(session.piProcess).toBeNull();
    expect(session.linkedTask).toEqual({
      taskId: "squad-tui-contracts",
      attemptId: null,
    });
  });

  it("rejects an unsupported schemaVersion with a typed error", () => {
    expect(() => parseSession(sessionUnsupportedVersionFixture)).toThrow(
      UnsupportedSchemaVersionError,
    );
  });

  it("rejects a malformed session payload with a typed error", () => {
    expect(() => parseSession(sessionMalformedFixture)).toThrow(
      ContractValidationError,
    );
  });
});

describe("hasForkDrift", () => {
  it("is false when only one conversation leaf is known", () => {
    expect(hasForkDrift({ leafCount: 1 })).toBe(false);
  });

  it("is true when more than one conversation leaf is reported, per the T02 attach-race finding", () => {
    expect(hasForkDrift({ leafCount: 2 })).toBe(true);
  });

  it("never claims drift when the leaf count itself is unknown", () => {
    expect(hasForkDrift({ leafCount: null })).toBe(false);
  });
});
