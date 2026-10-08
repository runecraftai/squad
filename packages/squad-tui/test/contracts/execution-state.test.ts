import { describe, expect, it } from "vitest";
import {
  coerceExecutionState,
  ExecutionState,
} from "../../src/contracts/execution-state";

describe("ExecutionState", () => {
  it("accepts every documented state including interrupted and unknown", () => {
    for (const state of [
      "queued",
      "running",
      "blocked",
      "succeeded",
      "failed",
      "cancelling",
      "cancelled",
      "interrupted",
      "unknown",
    ]) {
      expect(ExecutionState.parse(state)).toBe(state);
    }
  });
});

describe("coerceExecutionState", () => {
  it("passes through a recognized state unchanged", () => {
    expect(coerceExecutionState("running")).toBe("running");
  });

  it("maps an unrecognized harness-reported state to unknown rather than inventing one", () => {
    expect(coerceExecutionState("paused-for-reasons-we-have-never-seen")).toBe(
      "unknown",
    );
  });

  it("maps a non-string value to unknown without throwing", () => {
    expect(coerceExecutionState(null)).toBe("unknown");
    expect(coerceExecutionState(undefined)).toBe("unknown");
    expect(coerceExecutionState(42)).toBe("unknown");
  });
});
