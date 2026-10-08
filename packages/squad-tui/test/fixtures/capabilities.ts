import type { AdapterCapabilityDescriptor } from "../../src/contracts/capabilities";

export const tmuxCapabilityFixture: AdapterCapabilityDescriptor = {
  schemaVersion: 1,
  backend: "tmux",
  backendVersion: "3.4",
  capabilities: {
    launch: { level: "supported" },
    sendText: { level: "supported" },
    sendKeyEscape: { level: "supported" },
    sendKeyEnter: { level: "supported" },
    sendKeyCtrlC: { level: "supported" },
    diagnosticAttach: { level: "supported" },
    liveness: { level: "supported" },
    resumeAfterDisconnect: {
      level: "unsupported",
      note: "no dedicated resume verb; relies on the pane persisting detached",
    },
    structuredAgentReport: { level: "unsupported" },
    sendQueueStalledDetection: { level: "unsupported" },
    workspaceLeasing: { level: "unsupported" },
  },
};

export const tuiosCapabilityFixture: AdapterCapabilityDescriptor = {
  schemaVersion: 1,
  backend: "tuios",
  backendVersion: "0.8.0",
  capabilities: {
    launch: { level: "supported" },
    sendText: { level: "supported" },
    sendKeyEscape: {
      level: "unknown",
      note: "accepts an arbitrary key string; whether the agent surface honors Escape is unverified",
    },
    sendKeyEnter: { level: "supported" },
    sendKeyCtrlC: {
      level: "unknown",
      note: "not independently verified in phase-0 recon",
    },
    diagnosticAttach: { level: "supported" },
    liveness: { level: "supported" },
    resumeAfterDisconnect: { level: "supported" },
    structuredAgentReport: { level: "supported" },
    sendQueueStalledDetection: { level: "supported" },
    workspaceLeasing: { level: "supported" },
  },
};

export const legacyMissingKeysCapabilityFixture: AdapterCapabilityDescriptor = {
  schemaVersion: 1,
  backend: "herdr",
  backendVersion: "0.1.0",
  capabilities: {
    launch: { level: "supported" },
  },
};
