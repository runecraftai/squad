/**
 * Workmux status tracking extension for pi.
 *
 * Reports agent status to workmux for tmux window status display.
 * See: https://workmux.raine.dev/guide/status-tracking
 *
 * IMPORTANT: Do not add console.log/console.error statements here.
 * They produce visible output that pollutes the agent's TUI pane.
 * Status updates should be silent - the sidebar reads state from
 * the state store, not from stdout.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  function setStatus(status: string) {
    pi.exec("workmux", ["set-window-status", status]).catch(() => {});
  }

  pi.on("agent_start", async () => {
    setStatus("working");
  });

  pi.on("agent_end", async () => {
    setStatus("done");
  });
}
