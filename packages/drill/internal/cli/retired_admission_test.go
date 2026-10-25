package cli

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/branchsync"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
)

// TestTriggerRunRefusesRetiredReleasedBranch covers the exact regression: a
// branch released as an orphan whose pull request merged or closed afterwards
// must refuse a fresh axi run before any push or private submission.
func TestTriggerRunRefusesRetiredReleasedBranch(t *testing.T) {
	cases := []struct {
		prState   string
		wantState string
	}{
		{prState: "merged", wantState: branchsync.StateMergedRemoteRetained},
		{prState: "closed", wantState: branchsync.StateClosed},
	}
	for _, tc := range cases {
		t.Run(tc.prState, func(t *testing.T) {
			f := newCLIRecoverFixture(t)
			env, priorID := newReleasedOrphanCLI(t, f)
			if err := env.d.UpdateRunPRState(priorID, tc.prState); err != nil {
				t.Fatal(err)
			}
			gateBefore := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover")
			localBefore := cliGit(t, f.local, "show-ref")

			id, err := triggerRun(context.Background(), env, "feature/recover", f.submitted, nil, "full accepted intent", false)
			if err == nil || id != "" {
				t.Fatalf("retired branch started run %q: %v", id, err)
			}
			var ownership *branchOwnershipError
			if !errors.As(err, &ownership) {
				t.Fatalf("retired refusal is not the structured ownership error: %v", err)
			}
			if ownership.state.State != tc.wantState {
				t.Fatalf("refusal state = %q, want %q", ownership.state.State, tc.wantState)
			}
			for _, want := range []string{"retired", tc.prState} {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("refusal does not name %q: %v", want, err)
				}
			}
			if got := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover"); got != gateBefore {
				t.Fatalf("refused run moved gate branch to %s, want %s", got, gateBefore)
			}
			if got := cliGit(t, f.local, "show-ref"); got != localBefore {
				t.Fatal("refused run moved a local ref")
			}
			if _, stagedErr := git.Run(context.Background(), f.gate, "rev-parse", "--verify", ipc.OrphanSubmissionPrefix+priorID+"^{commit}"); stagedErr == nil {
				t.Fatal("refused run created a private submission")
			}
			runs, err := env.d.GetRunsByRepo(env.repo.ID)
			if err != nil || len(runs) != 1 {
				t.Fatalf("refused run created a run: %#v, %v", runs, err)
			}
		})
	}
}
