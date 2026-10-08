import { describe, expect, it } from "vitest";
import { ContractValidationError } from "../../src/contracts/errors";
import { parseTranscriptEvent } from "../../src/contracts/transcript";

const envelopeBase = {
  schemaVersion: 1,
  sessionId: "sess-orchestrator-pi",
  sequence: 1,
  timestamp: "2026-10-08T15:00:00.000Z",
};

describe("parseTranscriptEvent", () => {
  it("distinguishes agent_end from agent_settled, matching the T02 prompt-acceptance-vs-completion finding", () => {
    const end = parseTranscriptEvent({
      ...envelopeBase,
      payload: { type: "agent_end" },
    });
    const settled = parseTranscriptEvent({
      ...envelopeBase,
      payload: { type: "agent_settled" },
    });
    expect(end.payload.type).toBe("agent_end");
    expect(settled.payload.type).toBe("agent_settled");
  });

  it("carries queue_update steering/followUp arrays distinctly from a fresh prompt", () => {
    const event = parseTranscriptEvent({
      ...envelopeBase,
      payload: {
        type: "queue_update",
        steering: ["skip ahead"],
        followUp: ["say DONE"],
      },
    });
    if (event.payload.type !== "queue_update") {
      throw new Error("expected queue_update");
    }
    expect(event.payload.steering).toEqual(["skip ahead"]);
    expect(event.payload.followUp).toEqual(["say DONE"]);
  });

  it("degrades an unrecognized event type to unknown instead of throwing or inventing a shape", () => {
    const event = parseTranscriptEvent({
      ...envelopeBase,
      payload: { type: "future_event_type", someField: 42 },
    });
    expect(event.payload.type).toBe("unknown");
    if (event.payload.type !== "unknown") {
      throw new Error("expected unknown");
    }
    expect(event.payload.rawType).toBe("future_event_type");
  });

  it("fails with a typed error when the envelope itself is malformed", () => {
    expect(() =>
      parseTranscriptEvent({
        ...envelopeBase,
        sequence: "not-a-number",
        payload: { type: "agent_end" },
      }),
    ).toThrow(ContractValidationError);
  });

  it("fails with a typed error when a recognized event type has a malformed payload instead of downgrading to unknown", () => {
    expect(() =>
      parseTranscriptEvent({
        ...envelopeBase,
        payload: { type: "message_delta" },
      }),
    ).toThrow(ContractValidationError);
    expect(() =>
      parseTranscriptEvent({
        ...envelopeBase,
        payload: { type: "queue_update" },
      }),
    ).toThrow(ContractValidationError);
  });

  it("wraps the extension UI request payload opaquely for extension-ui.ts to interpret", () => {
    const event = parseTranscriptEvent({
      ...envelopeBase,
      payload: {
        type: "extension_ui_request",
        requestPayload: {
          id: "req-1",
          method: "select",
          options: ["Allow", "Deny"],
        },
      },
    });
    expect(event.payload.type).toBe("extension_ui_request");
  });
});
