package daemon

import (
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/pipeline"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

func TestRetiredBranchRefusesPushAndRerunAdmission(t *testing.T) {
	for _, state := range []string{"merged", "closed"} {
		t.Run(state, func(t *testing.T) {
			p, d := startTestDaemonWithSteps(t, func() []pipeline.Step {
				return []pipeline.Step{&mockPassStep{name: types.StepReview}}
			})
			repo, head := setupTestGitRepo(t, p, d, "retired-admission-"+state)
			prior, err := d.InsertRun(repo.ID, "main", head, head)
			if err != nil {
				t.Fatal(err)
			}
			if err := d.UpdateRunPRState(prior.ID, state); err != nil {
				t.Fatal(err)
			}
			client, err := ipc.Dial(p.Socket())
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			gate := p.RepoDir(repo.ID)
			gateBefore := gitOutput(t, gate, "rev-parse", "refs/heads/main")

			assertRefused := func(path string, callErr error) {
				t.Helper()
				if callErr == nil {
					t.Fatalf("%s admitted a retired branch", path)
				}
				for _, want := range []string{"branch_retired", "retired", state} {
					if !strings.Contains(callErr.Error(), want) {
						t.Fatalf("%s refusal is not named %q: %v", path, want, callErr)
					}
				}
			}

			var pushed ipc.PushReceivedResult
			assertRefused("push", client.Call(ipc.MethodPushReceived, &ipc.PushReceivedParams{
				Gate: gate, Ref: "refs/heads/main", Old: head, New: head, Intent: "retired branch must not restart",
			}, &pushed))
			if pushed.RunID != "" {
				t.Fatalf("refused push created run %s", pushed.RunID)
			}

			var rerun ipc.RerunResult
			assertRefused("rerun", client.Call(ipc.MethodRerun, &ipc.RerunParams{
				RepoID: repo.ID, Branch: "main", Intent: "retired branch must not restart",
			}, &rerun))
			if rerun.RunID != "" {
				t.Fatalf("refused rerun created run %s", rerun.RunID)
			}

			if got := gitOutput(t, gate, "rev-parse", "refs/heads/main"); got != gateBefore {
				t.Fatalf("refused admission moved gate branch to %s, want %s", got, gateBefore)
			}
			runs, err := d.GetRunsByRepo(repo.ID)
			if err != nil || len(runs) != 1 {
				t.Fatalf("refused admission created a run: %#v, %v", runs, err)
			}
		})
	}
}

func TestRetiredBranchRefusesOrphanAdmission(t *testing.T) {
	for _, state := range []string{"merged", "closed"} {
		t.Run(state, func(t *testing.T) {
			p, d := startTestDaemonWithSteps(t, func() []pipeline.Step {
				return []pipeline.Step{&mockPassStep{name: types.StepReview}}
			})
			repo, head := setupTestGitRepo(t, p, d, "retired-orphan-"+state)
			prior, err := d.InsertRun(repo.ID, "main", head, head)
			if err != nil {
				t.Fatal(err)
			}
			missing := strings.Repeat("e", 40)
			if err := d.UpdateRunStatusWithVerifiedHead(prior.ID, types.RunFailed, missing); err != nil {
				t.Fatal(err)
			}
			if err := d.ReleaseOrphanedRun(prior.ID, missing, head, ""); err != nil {
				t.Fatal(err)
			}
			if err := d.UpdateRunPRState(prior.ID, state); err != nil {
				t.Fatal(err)
			}
			client, err := ipc.Dial(p.Socket())
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			gate := p.RepoDir(repo.ID)
			gateBefore := gitOutput(t, gate, "rev-parse", "refs/heads/main")

			var result ipc.OrphanStartResult
			callErr := client.Call(ipc.MethodStartOrphan, &ipc.OrphanStartParams{
				RepoID: repo.ID, Branch: "main", PreviousRunID: prior.ID, HeadSHA: head,
				CheckOnly: true, Intent: "retired branch must not restart",
			}, &result)
			if callErr == nil {
				t.Fatal("orphan admission accepted a retired branch")
			}
			for _, want := range []string{"orphan_start_refused", "retired", state} {
				if !strings.Contains(callErr.Error(), want) {
					t.Fatalf("orphan refusal is not named %q: %v", want, callErr)
				}
			}
			if result.RunID != "" {
				t.Fatalf("refused orphan start created run %s", result.RunID)
			}
			if got := gitOutput(t, gate, "rev-parse", "refs/heads/main"); got != gateBefore {
				t.Fatalf("refused orphan start moved gate branch to %s, want %s", got, gateBefore)
			}
			runs, err := d.GetRunsByRepo(repo.ID)
			if err != nil || len(runs) != 1 {
				t.Fatalf("refused orphan start created a run: %#v, %v", runs, err)
			}
		})
	}
}
