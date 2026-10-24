package cli

import (
	"context"
	"fmt"

	"github.com/runecraftai/squad/packages/drill/internal/branchsync"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

// triggerOrphanRun never falls back to a branch push or a rerun of the gate tip.
// A version-matched daemon must explicitly admit this operation before the
// non-forced private-ref push, and verify the exact submitted head at start.
func triggerOrphanRun(ctx context.Context, env *axiEnv, state branchsync.State, branch, head string, skip []types.StepName, intent string, specialized bool) (string, error) {
	unchanged := func() bool {
		fresh := inspectAxiBranchSync(ctx, env)
		return fresh.State == branchsync.StateCustodyReturned && fresh.Pipeline.RunID == state.Pipeline.RunID &&
			fresh.Local.Branch == branch && fresh.Local.Head == head && fresh.Local.Clean
	}
	if !unchanged() {
		return "", fmt.Errorf("orphan_start_refused: local branch, head or cleanliness changed")
	}
	p := &ipc.OrphanStartParams{RepoID: env.repo.ID, Branch: branch, PreviousRunID: state.Pipeline.RunID, HeadSHA: head, CheckOnly: true, SkipSteps: skip, Intent: intent, SpecializedReview: specialized}
	var result ipc.OrphanStartResult
	if err := env.client.Call(ipc.MethodStartOrphan, p, &result); err != nil {
		return "", fmt.Errorf("orphan_start_unavailable: daemon did not admit an exact-head start; no branch push attempted: %w", err)
	}
	if !result.Ready {
		return "", fmt.Errorf("orphan_start_unavailable: daemon did not confirm exact-head support")
	}
	if !unchanged() {
		return "", fmt.Errorf("orphan_start_refused: local branch changed before submission")
	}
	ref := ipc.OrphanSubmissionPrefix + state.Pipeline.RunID
	if err := git.PushCommit(ctx, ".", env.p.RepoDir(env.repo.ID), head, ref, "", false); err != nil {
		return "", fmt.Errorf("orphan_start_refused: private submission failed; no branch push attempted: %w", err)
	}
	if !unchanged() {
		return "", fmt.Errorf("orphan_start_refused: local branch changed after submission")
	}
	p.CheckOnly = false
	result = ipc.OrphanStartResult{}
	if err := env.client.Call(ipc.MethodStartOrphan, p, &result); err != nil {
		return "", fmt.Errorf("orphan_start_refused: daemon could not start the submitted local commit; no fallback attempted: %w", err)
	}
	if !result.Ready || result.RunID == "" {
		return "", fmt.Errorf("orphan_start_refused: daemon did not confirm a run for the submitted local commit")
	}
	return result.RunID, nil
}
