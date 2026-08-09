/**
 * Squad's Pi-side goal-loop-audit integration (T-M5-02, REQ-M3-03).
 *
 * Boots the vendored @runecraft/goal-loop-audit extension inside the Squad Pi
 * session. The package drives durable goals to verified completion with an
 * isolated auditor (fresh session, read tools only) and exposes /goal, /list
 * and /loop. Squad-named bootstrapper keeping the registration explicit in
 * the repo's .pi tree; the package's own `pi` manifest also enables
 * auto-discovery through the root workspace.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import registerGoalLoopAudit from "../../packages/goal-loop-audit/extensions/loops/goal.ts";

export default function registerSquadGoalLoopAudit(pi: ExtensionAPI) {
  registerGoalLoopAudit(pi);
}
