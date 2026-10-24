package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/branchsync"
	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/pipeline"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

func TestOrphanReleaseThenExactLocalHeadStart(t *testing.T) {
	p, d := startTestDaemonWithSteps(t, func() []pipeline.Step {
		return []pipeline.Step{&mockPassStep{name: types.StepReview}}
	})
	repo, gateHead := setupTestGitRepo(t, p, d, "orphan-start")
	local := repo.WorkingPath
	if err := os.WriteFile(filepath.Join(local, "local.txt"), []byte("new local work\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitCmd(t, local, "add", "local.txt")
	gitCmd(t, local, "commit", "-m", "local commit not in gate")
	head := gitOutput(t, local, "rev-parse", "HEAD")
	branch := gitOutput(t, local, "branch", "--show-current")
	prior, err := d.InsertRun(repo.ID, branch, head, gateHead)
	if err != nil {
		t.Fatal(err)
	}
	missing := strings.Repeat("a", 40)
	if err := d.UpdateRunStatusWithVerifiedHead(prior.ID, types.RunFailed, missing); err != nil {
		t.Fatal(err)
	}
	service := &branchsync.Service{DB: d, Repo: repo, WorkDir: local, GateDir: p.RepoDir(repo.ID), Paths: p}
	if state := service.Recover(context.Background(), false); !state.Recovered {
		t.Fatalf("release: %#v", state)
	}
	client, err := ipc.Dial(p.Socket())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	request := &ipc.OrphanStartParams{RepoID: repo.ID, Branch: branch, PreviousRunID: prior.ID, HeadSHA: head, CheckOnly: true, Intent: "preserve all accepted requirements"}
	var result ipc.OrphanStartResult
	if err := client.Call(ipc.MethodStartOrphan, request, &result); err != nil || !result.Ready {
		t.Fatalf("preflight: %#v, %v", result, err)
	}
	ref := ipc.OrphanSubmissionPrefix + prior.ID
	// Ordinary non-forced push transfers the exact local commit to a private
	// ref. It does not fast-forward or rewrite refs/heads/main in the gate.
	gitCmd(t, local, "push", p.RepoDir(repo.ID), head+":"+ref)
	var notification ipc.PushReceivedResult
	if err := client.Call(ipc.MethodPushReceived, &ipc.PushReceivedParams{Gate: p.RepoDir(repo.ID), Ref: ref, New: head}, &notification); err != nil || notification.RunID != "" {
		t.Fatalf("private push triggered pipeline: %#v, %v", notification, err)
	}
	request.CheckOnly = false
	if err := client.Call(ipc.MethodStartOrphan, request, &result); err != nil || result.RunID == "" {
		t.Fatalf("start: %#v, %v", result, err)
	}
	run := waitForRunTerminalState(t, d, result.RunID)
	if run.SubmittedHeadSHA == nil || *run.SubmittedHeadSHA != head || run.HeadSHA != head || run.Status != types.RunCompleted {
		t.Fatalf("fresh run: %#v", run)
	}
	if run.Intent == nil || *run.Intent != request.Intent {
		t.Fatal("fresh run lost accepted intent")
	}
	if gitOutput(t, local, "rev-parse", "HEAD") != head || gitOutput(t, p.RepoDir(repo.ID), "rev-parse", "refs/heads/main") != gateHead {
		t.Fatal("fresh start moved a branch")
	}
	// A consumed release cannot start another run or cancel its successor.
	if err := client.Call(ipc.MethodStartOrphan, request, &result); err == nil || !strings.Contains(err.Error(), "orphan_start_refused") {
		t.Fatalf("reused release: %v", err)
	}
}

func TestOrphanStartRefusesUnprovenLocalHead(t *testing.T) {
	p, d := startTestDaemonWithSteps(t, func() []pipeline.Step {
		return []pipeline.Step{&mockPassStep{name: types.StepReview}}
	})
	repo, head := setupTestGitRepo(t, p, d, "orphan-refuse")
	prior, err := d.InsertRun(repo.ID, "main", head, head)
	if err != nil {
		t.Fatal(err)
	}
	missing := strings.Repeat("a", 40)
	if err := d.UpdateRunStatusWithVerifiedHead(prior.ID, types.RunFailed, missing); err != nil {
		t.Fatal(err)
	}
	if err := d.ReleaseOrphanedRun(prior.ID, missing, head, ""); err != nil {
		t.Fatal(err)
	}
	client, err := ipc.Dial(p.Socket())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	for _, kind := range []string{"missing submission", "wrong local head", "wrong branch", "head reappeared"} {
		t.Run(kind, func(t *testing.T) {
			request := &ipc.OrphanStartParams{RepoID: repo.ID, Branch: "main", PreviousRunID: prior.ID, HeadSHA: head}
			switch kind {
			case "wrong local head":
				request.HeadSHA = missing
			case "wrong branch":
				request.Branch = "other"
			case "head reappeared":
				if err := d.UpdateRunHeadSHA(prior.ID, head); err != nil {
					t.Fatal(err)
				}
			}
			var result ipc.OrphanStartResult
			if err := client.Call(ipc.MethodStartOrphan, request, &result); err == nil || !strings.Contains(err.Error(), "orphan_start_refused") {
				t.Fatalf("unsafe start: %#v, %v", result, err)
			}
			if gitOutput(t, p.RepoDir(repo.ID), "rev-parse", "refs/heads/main") != head {
				t.Fatal("refused start moved gate branch")
			}
			runs, err := d.GetRunsByRepo(repo.ID)
			if err != nil || len(runs) != 1 {
				t.Fatalf("refused start created a run: %#v, %v", runs, err)
			}
		})
	}
}

// TestOrphanReleaseWithLostPublishedTailStartsFreshRun covers the pushed half
// of the orphan class: the run published the gate head, then a later fix round
// advanced its recorded head past that published head and the object was lost.
// The release must still admit a fresh run for the descendant local head
// without pushing or moving any branch.
func TestOrphanReleaseWithLostPublishedTailStartsFreshRun(t *testing.T) {
	p, d := startTestDaemonWithSteps(t, func() []pipeline.Step {
		return []pipeline.Step{&mockPassStep{name: types.StepReview}}
	})
	repo, published := setupTestGitRepo(t, p, d, "orphan-pushed-tail")
	local := repo.WorkingPath
	if err := os.WriteFile(filepath.Join(local, "local.txt"), []byte("new local work\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitCmd(t, local, "add", "local.txt")
	gitCmd(t, local, "commit", "-m", "local commit not in gate")
	head := gitOutput(t, local, "rev-parse", "HEAD")
	branch := gitOutput(t, local, "branch", "--show-current")
	prior, err := d.InsertRun(repo.ID, branch, head, published)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateRunPushBinding(prior.ID, db.PushBinding{
		HeadSHA: published, TargetKind: "upstream", TargetFingerprint: branchsync.TargetFingerprint(repo.PushURL()), Ref: "refs/heads/" + branch,
	}); err != nil {
		t.Fatal(err)
	}
	missing := strings.Repeat("a", 40)
	if err := d.UpdateRunStatusWithVerifiedHead(prior.ID, types.RunFailed, missing); err != nil {
		t.Fatal(err)
	}
	service := &branchsync.Service{DB: d, Repo: repo, WorkDir: local, GateDir: p.RepoDir(repo.ID), Paths: p}
	state := service.Recover(context.Background(), false)
	if !state.Recovered || state.State != branchsync.StateCustodyReturned {
		t.Fatalf("pushed tail release: %#v", state)
	}
	prior, err = d.GetRun(prior.ID)
	if err != nil || prior.CustodyReturnHead == nil || *prior.CustodyReturnHead != head {
		t.Fatalf("released head = %#v, %v", prior, err)
	}
	if prior.CustodyReturnNote == nil || !strings.Contains(*prior.CustodyReturnNote, "published head "+published+" survives") {
		t.Fatalf("release audit does not name the surviving published head: %#v", prior.CustodyReturnNote)
	}
	client, err := ipc.Dial(p.Socket())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	request := &ipc.OrphanStartParams{RepoID: repo.ID, Branch: branch, PreviousRunID: prior.ID, HeadSHA: head, CheckOnly: true, Intent: "preserve all accepted requirements"}
	var result ipc.OrphanStartResult
	if err := client.Call(ipc.MethodStartOrphan, request, &result); err != nil || !result.Ready {
		t.Fatalf("pushed prior preflight: %#v, %v", result, err)
	}
	ref := ipc.OrphanSubmissionPrefix + prior.ID
	gitCmd(t, local, "push", p.RepoDir(repo.ID), head+":"+ref)
	request.CheckOnly = false
	if err := client.Call(ipc.MethodStartOrphan, request, &result); err != nil || result.RunID == "" {
		t.Fatalf("pushed prior start: %#v, %v", result, err)
	}
	run := waitForRunTerminalState(t, d, result.RunID)
	if run.SubmittedHeadSHA == nil || *run.SubmittedHeadSHA != head || run.HeadSHA != head {
		t.Fatalf("fresh run after published tail loss: %#v", run)
	}
	if got := gitOutput(t, local, "rev-parse", "HEAD"); got != head {
		t.Fatalf("fresh start moved local HEAD to %s", got)
	}
	if got := gitOutput(t, p.RepoDir(repo.ID), "rev-parse", "refs/heads/"+branch); got != published {
		t.Fatalf("fresh start moved gate branch to %s, want %s", got, published)
	}
}

// TestOrphanStartRefusesRetiredBranch proves a merged or closed pull request
// retires the branch for fresh starts too: the daemon admission refuses the
// released orphan even though its custody stamp and missing head qualify.
func TestOrphanStartRefusesRetiredBranch(t *testing.T) {
	for _, state := range []string{"merged", "closed"} {
		t.Run(state, func(t *testing.T) {
			p, d := startTestDaemonWithSteps(t, func() []pipeline.Step {
				return []pipeline.Step{&mockPassStep{name: types.StepReview}}
			})
			repo, head := setupTestGitRepo(t, p, d, "orphan-retired")
			prior, err := d.InsertRun(repo.ID, "main", head, head)
			if err != nil {
				t.Fatal(err)
			}
			missing := strings.Repeat("d", 40)
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
			request := &ipc.OrphanStartParams{RepoID: repo.ID, Branch: "main", PreviousRunID: prior.ID, HeadSHA: head, CheckOnly: true, Intent: "preserve all accepted requirements"}
			var result ipc.OrphanStartResult
			callErr := client.Call(ipc.MethodStartOrphan, request, &result)
			if callErr == nil || !strings.Contains(callErr.Error(), "orphan_start_refused") || !strings.Contains(callErr.Error(), "retired") || !strings.Contains(callErr.Error(), state) {
				t.Fatalf("retired start admitted: %#v, %v", result, callErr)
			}
			if got := gitOutput(t, p.RepoDir(repo.ID), "rev-parse", "refs/heads/main"); got != head {
				t.Fatal("refused retired start moved gate branch")
			}
			runs, err := d.GetRunsByRepo(repo.ID)
			if err != nil || len(runs) != 1 {
				t.Fatalf("refused retired start created a run: %#v, %v", runs, err)
			}
		})
	}
}
