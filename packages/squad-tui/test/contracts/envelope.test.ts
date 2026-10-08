import { describe, expect, it } from "vitest";
import { CommandEnvelope, EventEnvelope } from "../../src/contracts/envelope";

describe("CommandEnvelope", () => {
  it("requires an explicit target, never an implicit active endpoint", () => {
    const command = {
      schemaVersion: 1,
      requestId: "req-1",
      target: { kind: "session", id: "sess-executor-claude" },
      payload: { text: "please run the lint stage" },
    };
    expect(CommandEnvelope.parse(command)).toEqual(command);
  });

  it("rejects a command with no target at all", () => {
    const invalid = { schemaVersion: 1, requestId: "req-1", payload: {} };
    expect(CommandEnvelope.safeParse(invalid).success).toBe(false);
  });
});

describe("EventEnvelope", () => {
  it("parses one of the PRD's fixed event types with ordering fields", () => {
    const event = {
      schemaVersion: 1,
      eventId: "evt-1",
      sequence: 42,
      timestamp: "2026-10-08T15:00:00.000Z",
      entity: { kind: "stage", id: "squad-tui-contracts" },
      type: "stage.updated",
      payload: { state: "running" },
    };
    expect(EventEnvelope.parse(event)).toEqual(event);
  });

  it("rejects an event type outside the fixed PRD vocabulary", () => {
    const invalid = {
      schemaVersion: 1,
      eventId: "evt-1",
      sequence: 42,
      timestamp: "2026-10-08T15:00:00.000Z",
      entity: { kind: "stage", id: "squad-tui-contracts" },
      type: "stage.exploded",
      payload: {},
    };
    expect(EventEnvelope.safeParse(invalid).success).toBe(false);
  });
});
