import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { ReviewLoopCoordinator } from "../lib/pr-review-loop.ts";
import { SelfReviewPermitCoordinator } from "../lib/pr-self-review.ts";
import registerPrReviewSubagents from "./pr-review-subagent.ts";
import registerReviewFocus from "./pr-review-focus.ts";
import registerReviewTable from "./review-table.ts";

/** Register the package behind one shared, session-scoped review-loop authority. */
export default function registerPrReview(pi: ExtensionAPI) {
	const loopCoordinator = new ReviewLoopCoordinator(pi);
	const selfReviewCoordinator = new SelfReviewPermitCoordinator(pi, () => !!loopCoordinator.peek());
	registerPrReviewSubagents(pi, loopCoordinator, selfReviewCoordinator);
	registerReviewFocus(pi, loopCoordinator);
	registerReviewTable(pi, loopCoordinator, selfReviewCoordinator);
}
