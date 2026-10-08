export const sessionV1Fixture = {
  schemaVersion: 1,
  sessionId: "sess-orchestrator-pi",
  baseId: "base-main",
  role: "orchestrator",
  harness: "pi",
  backend: "tmux",
  origin: "interactive-primary",
  state: "running",
  linkedTask: null,
  health: { leafCount: 1 },
  piProcess: null,
};

export const sessionV0LegacyFixture = {
  schemaVersion: 0,
  sessionId: "sess-executor-claude",
  baseId: "base-main",
  role: "executor",
  harness: "claude",
  backend: "tmux",
  origin: "squad-dispatch",
  state: "succeeded",
  linkedTask: { taskId: "squad-tui-contracts", attemptId: null },
};

export const sessionUnsupportedVersionFixture = {
  ...sessionV1Fixture,
  schemaVersion: 7,
};

export const sessionMalformedFixture = {
  ...sessionV1Fixture,
  harness: 42,
};
