import { describe, expect, it } from "vitest";
import { DrillRunInfo } from "../../src/contracts/drill-run";

const runFixture = {
  schemaVersion: 1,
  id: "run-1",
  drillIdentity: { repoId: "squad", gatePath: "/home/rehem/Projects/squad" },
  branch: "sq/squad-tui-contracts",
  headSha: "403beb0",
  submittedHeadSha: "403beb0",
  baseSha: "0000000",
  status: "running",
  prUrl: null,
  error: null,
  ciReady: false,
  ciReadyNoCi: false,
  awaitingAgent: false,
  awaitingAgentSince: null,
  steps: [
    { name: "intent", status: "completed" },
    { name: "lint", status: "running" },
  ],
};

describe("DrillRunInfo", () => {
  it("parses a real-shaped run scoped by an explicit drill identity, not Squad's operational base", () => {
    expect(DrillRunInfo.parse(runFixture)).toEqual(runFixture);
  });

  it("fails with a typed error on an unrecognized step status (TOON text drift, not the IPC contract)", () => {
    const malformed = {
      ...runFixture,
      steps: [{ name: "lint", status: "almost-done" }],
    };
    expect(DrillRunInfo.safeParse(malformed).success).toBe(false);
  });

  it("fails with a typed error on an unrecognized run status", () => {
    const malformed = { ...runFixture, status: "stuck" };
    expect(DrillRunInfo.safeParse(malformed).success).toBe(false);
  });
});
