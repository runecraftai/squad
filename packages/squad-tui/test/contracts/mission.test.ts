import { describe, expect, it } from "vitest";
import { Mission } from "../../src/contracts/mission";

describe("Mission", () => {
  it("is keyed by an existing backlog task id, minting no new authoritative identity", () => {
    const mission = {
      schemaVersion: 1,
      missionId: "squad-tui-contracts",
      title: "Contratos TUI de sessão, missão, etapa e adaptador",
      linkedTaskIds: [],
      stages: [],
      state: "running",
    };
    expect(Mission.parse(mission)).toEqual(mission);
  });

  it("rejects a mission whose nested stage violates the drill/non-drill invariant", () => {
    const mission = {
      schemaVersion: 1,
      missionId: "squad-tui-contracts",
      title: "Contratos TUI de sessão, missão, etapa e adaptador",
      linkedTaskIds: [],
      stages: [
        {
          schemaVersion: 1,
          taskId: "squad-tui-contracts",
          attemptId: null,
          kind: "drill-pipeline-step",
          drillStepName: null,
          drillRunRef: null,
          state: "running",
          session: null,
        },
      ],
      state: "running",
    };
    expect(Mission.safeParse(mission).success).toBe(false);
  });
});
