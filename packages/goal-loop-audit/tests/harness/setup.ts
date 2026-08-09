// pi-goal-list-loop-audit — v0.28.18
// tests/harness/setup.ts
//
// bun test preload (bunfig.toml [test].preload) — runs BEFORE any test file's
// imports in every test process. Points the GLOBAL settings path at a
// per-process tmp file so the suite is hermetic from the developer's real
// ~/.pi/agent/pi-goal-list-loop-audit.settings.json. (Exposed 2026-07-29:
// setting autoAcceptDrafts globally on the dev rig made the draft-Confirm
// behavioral tests auto-accept and fail.)

import * as os from "node:os";
import * as path from "node:path";

process.env.GLLA_GLOBAL_SETTINGS_PATH ??= path.join(
  os.tmpdir(),
  `glla-test-global-settings-${process.pid}.json`,
);
