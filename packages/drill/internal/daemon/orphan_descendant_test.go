package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/branchsync"
	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
	"github.com/runecraftai/squad/packages/drill/internal/pipeline"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

type releasedOrphanFixture struct {
	client   *ipc.Client
	db       *db.DB
	paths    *paths.Paths
	repo     *db.Repo
	local    string
	gate     string
	branch   string
	released string
	priorID  string
}

// newReleasedOrphanFixture reproduces the measured missing-object incident: the
// run's recorded pipeline head is not an object anywhere, and the clean local
// head it was released at is a local-only commit.
func newReleasedOrphanFixture(t *testing.T) releasedOrphanFixture {
	t.Helper()
	p, d := startTestDaemonWithSteps(t, func() []pipeline.Step {
		return []pipeline.Step{&mockPassStep{name: types.StepReview}}
	})
	repo, gateHead := setupTestGitRepo(t, p, d, "orphan-descendant")
	local := repo.WorkingPath
	if err := os.WriteFile(filepath.Join(local, "local.txt"), []byte("local work\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitCmd(t, local, "add", "local.txt")
	gitCmd(t, local, "commit", "-m", "local commit not in gate")
	released := gitOutput(t, local, "rev-parse", "HEAD")
	branch := gitOutput(t, local, "branch", "--show-current")
	prior, err := d.InsertRun(repo.ID, branch, released, gateHead)
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
	t.Cleanup(func() { client.Close() })
	return releasedOrphanFixture{
		client: client, db: d, paths: p, repo: repo, local: local, gate: p.RepoDir(repo.ID),
		branch: branch, released: released, priorID: prior.ID,
	}
}

func TestOrphanStartAcceptsDescendantOfReleasedHead(t *testing.T) {
	f := newReleasedOrphanFixture(t)
	gateBefore := gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch)

	// The release audit told the operator the fixes were lost, so they redo
	// them: the supported fresh head is a descendant of the audited release.
	if err := os.WriteFile(filepath.Join(f.local, "redo.txt"), []byte("redone fix\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitCmd(t, f.local, "add", "redo.txt")
	gitCmd(t, f.local, "commit", "-m", "redo the lost pipeline fix")
	head := gitOutput(t, f.local, "rev-parse", "HEAD")
	if head == f.released {
		t.Fatal("fixture did not move the local head")
	}

	request := &ipc.OrphanStartParams{RepoID: f.repo.ID, Branch: f.branch, PreviousRunID: f.priorID, HeadSHA: head, CheckOnly: true, Intent: "preserve all accepted requirements"}
	var result ipc.OrphanStartResult
	if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err != nil || !result.Ready {
		t.Fatalf("descendant preflight: %#v, %v", result, err)
	}
	ref := ipc.OrphanSubmissionPrefix + f.priorID
	gitCmd(t, f.local, "push", f.gate, head+":"+ref)
	request.CheckOnly = false
	result = ipc.OrphanStartResult{}
	if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err != nil || result.RunID == "" {
		t.Fatalf("descendant start: %#v, %v", result, err)
	}
	run := waitForRunTerminalState(t, f.db, result.RunID)
	if run.SubmittedHeadSHA == nil || *run.SubmittedHeadSHA != head || run.HeadSHA != head {
		t.Fatalf("descendant run head: %#v", run)
	}
	prior, err := f.db.GetRun(f.priorID)
	if err != nil || prior == nil || prior.CustodyReturnHead == nil || *prior.CustodyReturnHead != f.released {
		t.Fatalf("release audit anchor changed: %#v, %v", prior, err)
	}
	if prior.CustodyReturnNote == nil || !strings.Contains(*prior.CustodyReturnNote, f.released) {
		t.Fatalf("release audit note changed: %#v", prior.CustodyReturnNote)
	}
	if gitOutput(t, f.local, "rev-parse", "HEAD") != head || gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch) != gateBefore {
		t.Fatal("descendant start moved a branch")
	}
}

func TestOrphanStartRefusesHeadThatDoesNotDescendFromReleasedHead(t *testing.T) {
	f := newReleasedOrphanFixture(t)
	gateBefore := gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch)

	// A rewritten local history has new commits, but none descend from the
	// audited released head, so exact-head submission must still refuse.
	gitCmd(t, f.local, "reset", "--hard", gateBefore)
	if err := os.WriteFile(filepath.Join(f.local, "rewritten.txt"), []byte("rewritten\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitCmd(t, f.local, "add", "rewritten.txt")
	gitCmd(t, f.local, "commit", "-m", "rewritten local history")
	head := gitOutput(t, f.local, "rev-parse", "HEAD")
	if _, err := git.Run(context.Background(), f.local, "merge-base", "--is-ancestor", f.released, head); err == nil {
		t.Fatalf("fixture is not a rewrite: released %s head %s", f.released, head)
	}
	localBefore := gitOutput(t, f.local, "show-ref")

	ref := ipc.OrphanSubmissionPrefix + f.priorID
	gitCmd(t, f.local, "push", f.gate, head+":"+ref)
	request := &ipc.OrphanStartParams{RepoID: f.repo.ID, Branch: f.branch, PreviousRunID: f.priorID, HeadSHA: head, Intent: "preserve all accepted requirements"}
	var result ipc.OrphanStartResult
	if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err == nil ||
		!strings.Contains(err.Error(), "orphan_start_refused") || !strings.Contains(err.Error(), "descend") {
		t.Fatalf("rewritten head accepted: %#v, %v", result, err)
	}
	if result.RunID != "" {
		t.Fatalf("refused start created a run: %#v", result)
	}
	if gitOutput(t, f.local, "show-ref") != localBefore || gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch) != gateBefore {
		t.Fatal("refused start moved a branch")
	}
	runs, err := f.db.GetRunsByRepo(f.repo.ID)
	if err != nil || len(runs) != 1 {
		t.Fatalf("refused start created a run: %#v, %v", runs, err)
	}
}

// commitReleasedOrphanHead adds a local commit for the orphan fixture and
// returns its SHA.
func commitReleasedOrphanHead(t *testing.T, f releasedOrphanFixture, name string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.local, name), []byte(name+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitCmd(t, f.local, "add", name)
	gitCmd(t, f.local, "commit", "-m", "commit "+name)
	return gitOutput(t, f.local, "rev-parse", "HEAD")
}

func TestOrphanStartClearsStalePrivateSubmission(t *testing.T) {
	t.Run("descendant supersedes leftover submission", func(t *testing.T) {
		f := newReleasedOrphanFixture(t)
		ref := ipc.OrphanSubmissionPrefix + f.priorID
		gateBefore := gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch)

		// A failed start leaves the private submission behind at the head it
		// had pushed; the operator then commits more work on top.
		first := commitReleasedOrphanHead(t, f, "first.txt")
		gitCmd(t, f.local, "push", f.gate, first+":"+ref)
		head := commitReleasedOrphanHead(t, f, "second.txt")

		request := &ipc.OrphanStartParams{RepoID: f.repo.ID, Branch: f.branch, PreviousRunID: f.priorID, HeadSHA: head, CheckOnly: true, Intent: "preserve all accepted requirements"}
		var result ipc.OrphanStartResult
		if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err != nil || !result.Ready {
			t.Fatalf("preflight blocked by stale submission: %#v, %v", result, err)
		}
		if _, err := git.Run(context.Background(), f.gate, "rev-parse", "--verify", ref+"^{commit}"); err == nil {
			t.Fatal("stale private submission was not cleared")
		}
		gitCmd(t, f.local, "push", f.gate, head+":"+ref)
		request.CheckOnly = false
		result = ipc.OrphanStartResult{}
		if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err != nil || result.RunID == "" {
			t.Fatalf("retry start: %#v, %v", result, err)
		}
		run := waitForRunTerminalState(t, f.db, result.RunID)
		if run.SubmittedHeadSHA == nil || *run.SubmittedHeadSHA != head {
			t.Fatalf("retry run head: %#v", run)
		}
		if gitOutput(t, f.local, "rev-parse", "HEAD") != head || gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch) != gateBefore {
			t.Fatal("retry moved a branch")
		}
	})

	t.Run("rewritten descendant still supersedes", func(t *testing.T) {
		f := newReleasedOrphanFixture(t)
		ref := ipc.OrphanSubmissionPrefix + f.priorID
		gateBefore := gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch)

		first := commitReleasedOrphanHead(t, f, "first.txt")
		gitCmd(t, f.local, "push", f.gate, first+":"+ref)
		gitCmd(t, f.local, "reset", "--hard", f.released)
		head := commitReleasedOrphanHead(t, f, "rewritten.txt")
		if _, err := git.Run(context.Background(), f.local, "merge-base", "--is-ancestor", first, head); err == nil {
			t.Fatal("fixture did not rewrite the leftover submission")
		}

		request := &ipc.OrphanStartParams{RepoID: f.repo.ID, Branch: f.branch, PreviousRunID: f.priorID, HeadSHA: head, CheckOnly: true, Intent: "preserve all accepted requirements"}
		var result ipc.OrphanStartResult
		if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err != nil || !result.Ready {
			t.Fatalf("preflight blocked by stale submission: %#v, %v", result, err)
		}
		// A non-forced push can only succeed once the stale ref is cleared.
		gitCmd(t, f.local, "push", f.gate, head+":"+ref)
		request.CheckOnly = false
		result = ipc.OrphanStartResult{}
		if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err != nil || result.RunID == "" {
			t.Fatalf("rewritten descendant start: %#v, %v", result, err)
		}
		if gitOutput(t, f.local, "rev-parse", "HEAD") != head || gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch) != gateBefore {
			t.Fatal("rewritten descendant start moved a branch")
		}
	})

	t.Run("live owner keeps the submission", func(t *testing.T) {
		f := newReleasedOrphanFixture(t)
		ref := ipc.OrphanSubmissionPrefix + f.priorID
		first := commitReleasedOrphanHead(t, f, "first.txt")
		gitCmd(t, f.local, "push", f.gate, first+":"+ref)
		head := commitReleasedOrphanHead(t, f, "second.txt")
		if _, err := f.db.InsertRun(f.repo.ID, f.branch, head, f.released); err != nil {
			t.Fatal(err)
		}

		request := &ipc.OrphanStartParams{RepoID: f.repo.ID, Branch: f.branch, PreviousRunID: f.priorID, HeadSHA: head, CheckOnly: true, Intent: "preserve all accepted requirements"}
		var result ipc.OrphanStartResult
		if err := f.client.Call(ipc.MethodStartOrphan, request, &result); err == nil || !strings.Contains(err.Error(), "orphan_start_refused") {
			t.Fatalf("live owner admitted a stale submission: %#v, %v", result, err)
		}
		if got := gitOutput(t, f.gate, "rev-parse", ref+"^{commit}"); got != first {
			t.Fatalf("live owner lost its submission: %s, want %s", got, first)
		}
	})

	t.Run("live owner keeps the submission under the branch lock", func(t *testing.T) {
		f := newReleasedOrphanFixture(t)
		ref := ipc.OrphanSubmissionPrefix + f.priorID
		gateBefore := gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch)
		first := commitReleasedOrphanHead(t, f, "first.txt")
		gitCmd(t, f.local, "push", f.gate, first+":"+ref)
		head := commitReleasedOrphanHead(t, f, "second.txt")
		// A run that goes live after the request-level ownership check must
		// still keep its submission when the in-lock proof runs again.
		if _, err := f.db.InsertRun(f.repo.ID, f.branch, head, f.released); err != nil {
			t.Fatal(err)
		}
		prior, err := f.db.GetRun(f.priorID)
		if err != nil || prior == nil {
			t.Fatalf("released orphan: %#v, %v", prior, err)
		}
		manager := NewRunManager(f.db, f.paths, nil)
		err = manager.clearStaleOrphanSubmission(context.Background(), f.repo, prior, head)
		if err == nil || !strings.Contains(err.Error(), "orphan_start_refused") {
			t.Fatalf("in-lock ownership proof admitted a live run: %v", err)
		}
		if got := gitOutput(t, f.gate, "rev-parse", ref+"^{commit}"); got != first {
			t.Fatalf("live owner lost its submission under the branch lock: %s, want %s", got, first)
		}
		if gitOutput(t, f.local, "rev-parse", "HEAD") != head || gitOutput(t, f.gate, "rev-parse", "refs/heads/"+f.branch) != gateBefore {
			t.Fatal("in-lock refusal moved a branch")
		}
	})
}
