import { describe, expect, it } from "vitest";
import { Stage } from "../../src/contracts/stage";

const drillStage = {
  schemaVersion: 1,
  taskId: "squad-tui-contracts",
  attemptId: "attempt-1",
  kind: "drill-pipeline-step",
  drillStepName: "lint",
  drillRunRef: {
    drillIdentity: { repoId: "squad", gatePath: "/home/rehem/Projects/squad" },
    runId: "run-1",
  },
  state: "running",
  session: null,
};

describe("Stage", () => {
  it("accepts a drill-pipeline-step stage naming its drill step and run", () => {
    expect(Stage.parse(drillStage)).toEqual(drillStage);
  });

  it("accepts a deterministic-command stage with no agent session at all", () => {
    const deterministic = {
      schemaVersion: 1,
      taskId: "squad-tui-contracts",
      attemptId: null,
      kind: "deterministic-command",
      drillStepName: null,
      drillRunRef: null,
      state: "succeeded",
      session: null,
    };
    expect(Stage.parse(deterministic)).toEqual(deterministic);
  });

  it("accepts an agent-step stage that does carry a session", () => {
    const agentStep = {
      schemaVersion: 1,
      taskId: "squad-tui-contracts",
      attemptId: "attempt-1",
      kind: "agent-step",
      drillStepName: null,
      drillRunRef: null,
      state: "running",
      session: "sess-executor-claude",
    };
    expect(Stage.parse(agentStep)).toEqual(agentStep);
  });

  it("rejects a drill-pipeline-step stage missing its drill step name", () => {
    const invalid = { ...drillStage, drillStepName: null };
    expect(Stage.safeParse(invalid).success).toBe(false);
  });

  it("rejects a non-drill stage that still names a drill step", () => {
    const invalid = {
      ...drillStage,
      kind: "deterministic-command",
    };
    expect(Stage.safeParse(invalid).success).toBe(false);
  });
});
