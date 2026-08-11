/**
 * Squad's Pi-side pr-review integration (T-M3-03, REQ-M3-02).
 *
 * Boots the maintained @runecraft/pr-review package extension inside the Squad Pi
 * session: parallel tiered review of strike PRs, COMMENT-only publication
 * (the package default; auto-approve is disabled), findings table surfaced to
 * the commander. Never auto-merges and never self-approves, including under a
 * +yolo posture (the package's approval path requires its own trusted
 * opt-in; Squad's flow keeps it off).
 *
 * Auto-discovery: the package's own `pi` manifest (packages/pr-review) is
 * registered through the root workspace, so this adapter is a Squad-named
 * bootstrapper that keeps the registration explicit in the repo's .pi tree.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import registerPrReview from "../../packages/pr-review/extensions/index.ts";

export default function registerSquadPrReview(pi: ExtensionAPI) {
  registerPrReview(pi);
}
