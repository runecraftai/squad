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
	"github.com/runecraftai/squad/packages/drill/internal/pipeline"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

type releasedOrphanFixture struct {
	client   *ipc.Client
	db       *db.DB
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
		client: client, db: d, repo: repo, local: local, gate: p.RepoDir(repo.ID),
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
