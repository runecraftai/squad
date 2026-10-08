import { describe, expect, it } from "vitest";
import {
  SessionLockRequest,
  SessionLockResult,
} from "../../src/contracts/service-exclusivity";

describe("SessionLockRequest", () => {
  it("accepts a create-mode request scoped to one base and session id", () => {
    const request = {
      schemaVersion: 1,
      baseId: "base-main",
      sessionId: "sess-orchestrator-pi",
      mode: "create",
      requesterId: "squad-tui-service",
    };
    expect(SessionLockRequest.parse(request)).toEqual(request);
  });

  it("rejects a request missing its session id", () => {
    const invalid = {
      schemaVersion: 1,
      baseId: "base-main",
      mode: "attach",
      requesterId: "squad-tui-service",
    };
    expect(SessionLockRequest.safeParse(invalid).success).toBe(false);
  });
});

describe("SessionLockResult", () => {
  it("models a grant", () => {
    const grant = {
      outcome: "granted",
      sessionId: "sess-orchestrator-pi",
      holderId: "squad-tui-service-1",
      acquiredAt: "2026-10-08T15:00:00.000Z",
    };
    expect(SessionLockResult.parse(grant)).toEqual(grant);
  });

  it("models the exact creation-race failure mode reproduced in T02 5a", () => {
    const rejection = {
      outcome: "rejected",
      reason: "create-race-lost",
      heldBy: null,
    };
    expect(SessionLockResult.parse(rejection)).toEqual(rejection);
  });

  it("models the exact attach-race fork-detected failure mode reproduced in T02 5b", () => {
    const rejection = {
      outcome: "rejected",
      reason: "attach-race-fork-detected",
      heldBy: "squad-tui-service-1",
    };
    expect(SessionLockResult.parse(rejection)).toEqual(rejection);
  });

  it("rejects an unrecognized rejection reason as a typed error", () => {
    const invalid = { outcome: "rejected", reason: "mystery", heldBy: null };
    expect(SessionLockResult.safeParse(invalid).success).toBe(false);
  });
});
