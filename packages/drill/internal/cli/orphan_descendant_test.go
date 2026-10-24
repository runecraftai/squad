package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/branchsync"
	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
)

// newReleasedOrphanCLI reproduces a missing-object release at the current local
// head and returns the wired CLI environment for the supported fresh run.
func newReleasedOrphanCLI(t *testing.T, f cliRecoverFixture) (*axiEnv, string) {
	t.Helper()
	p, err := paths.New()
	if err != nil {
		t.Fatal(err)
	}
	database, err := db.Open(p.DB())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	repo, err := database.GetRepoByPath(f.local)
	if err != nil || repo == nil {
		t.Fatalf("repo: %#v, %v", repo, err)
	}
	runs, err := database.GetRunsByRepo(repo.ID)
	if err != nil || len(runs) != 1 {
		t.Fatalf("runs: %#v, %v", runs, err)
	}
	missing := strings.Repeat("a", 40)
	if err := database.UpdateRunHeadSHA(runs[0].ID, missing); err != nil {
		t.Fatal(err)
	}
	if err := database.ReleaseOrphanedRun(runs[0].ID, missing, f.submitted, ""); err != nil {
		t.Fatal(err)
	}
	client := serveOrphanStub(t, runs[0].ID)
	return &axiEnv{d: database, repo: repo, p: p, client: client}, runs[0].ID
}

// serveOrphanStub advertises exact-head support and proves the submitted
// commit, so the CLI path is exercised without a shared daemon.
func serveOrphanStub(t *testing.T, priorID string) *ipc.Client {
	t.Helper()
	return serveOrphanHandler(t, func(ctx context.Context, raw json.RawMessage) (interface{}, error) {
		var request ipc.OrphanStartParams
		if err := json.Unmarshal(raw, &request); err != nil {
			return nil, err
		}
		if request.PreviousRunID != priorID || request.Intent != "full accepted intent" {
			return nil, fmt.Errorf("wrong submission identity or intent")
		}
		if request.CheckOnly {
			return &ipc.OrphanStartResult{Ready: true}, nil
		}
		return &ipc.OrphanStartResult{Ready: true, RunID: "successor"}, nil
	})
}

func serveOrphanHandler(t *testing.T, handler ipc.HandlerFunc) *ipc.Client {
	t.Helper()
	srv := ipc.NewServer()
	srv.Handle(ipc.MethodStartOrphan, handler)
	socket := filepath.Join(makeSocketSafeTempDir(t), "orphan.sock")
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(socket) }()
	t.Cleanup(func() { srv.Close(); <-errCh })
	var client *ipc.Client
	var err error
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		client, err = ipc.Dial(socket)
		if err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if client == nil {
		t.Fatalf("test IPC server did not start: %v", err)
	}
	t.Cleanup(func() { client.Close() })
	return client
}

func commitLocalFile(t *testing.T, dir, name, content, message string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	cliGit(t, dir, "add", name)
	cliGit(t, dir, "commit", "-m", message)
	return cliGit(t, dir, "rev-parse", "HEAD")
}

func TestTriggerOrphanRunAcceptsDescendantOfReleasedHead(t *testing.T) {
	f := newCLIRecoverFixture(t)
	env, priorID := newReleasedOrphanCLI(t, f)
	gateBefore := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover")

	head := commitLocalFile(t, f.local, "redo.txt", "redone fix\n", "redo the lost pipeline fix")
	localBefore := cliGit(t, f.local, "show-ref")
	id, err := triggerRun(context.Background(), env, "feature/recover", head, nil, "full accepted intent", false)
	if err != nil || id != "successor" {
		t.Fatalf("descendant fresh run: %s, %v", id, err)
	}
	staged := cliGit(t, f.gate, "rev-parse", ipc.OrphanSubmissionPrefix+priorID+"^{commit}")
	if staged != head {
		t.Fatalf("private submission = %s, want %s", staged, head)
	}
	if cliGit(t, f.local, "show-ref") != localBefore || cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover") != gateBefore {
		t.Fatal("descendant fresh run moved a branch")
	}
}

func TestTriggerOrphanRunRefusesHeadThatDoesNotDescendFromReleasedHead(t *testing.T) {
	f := newCLIRecoverFixture(t)
	env, priorID := newReleasedOrphanCLI(t, f)
	gateBefore := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover")

	cliGit(t, f.local, "reset", "--hard", f.submitted+"^")
	head := commitLocalFile(t, f.local, "rewritten.txt", "rewritten\n", "rewritten local history")
	if _, err := git.Run(context.Background(), f.local, "merge-base", "--is-ancestor", f.submitted, head); err == nil {
		t.Fatalf("fixture is not a rewrite: released %s head %s", f.submitted, head)
	}
	localBefore := cliGit(t, f.local, "show-ref")
	id, err := triggerRun(context.Background(), env, "feature/recover", head, nil, "full accepted intent", false)
	if err == nil || !strings.Contains(err.Error(), "orphan_start_refused") || !strings.Contains(err.Error(), "descend") || id != "" {
		t.Fatalf("rewritten head accepted: %s, %v", id, err)
	}
	if cliGit(t, f.local, "show-ref") != localBefore || cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover") != gateBefore {
		t.Fatal("refusal moved a branch")
	}
	if _, err := git.Run(context.Background(), f.gate, "rev-parse", "--verify", ipc.OrphanSubmissionPrefix+priorID+"^{commit}"); err == nil {
		t.Fatal("CLI submitted a non-descendant head to the private ref")
	}
}

// TestTriggerOrphanRunRetriesDescendantAfterFailedStart is the CLI half of the
// stale-submission regression: a refused start leaves the private ref behind,
// and a later descendant must still be submitted and started.
func TestTriggerOrphanRunRetriesDescendantAfterFailedStart(t *testing.T) {
	f := newCLIRecoverFixture(t)
	p, err := paths.New()
	if err != nil {
		t.Fatal(err)
	}
	database, err := db.Open(p.DB())
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	repo, err := database.GetRepoByPath(f.local)
	if err != nil || repo == nil {
		t.Fatalf("repo: %#v, %v", repo, err)
	}
	runs, err := database.GetRunsByRepo(repo.ID)
	if err != nil || len(runs) != 1 {
		t.Fatalf("runs: %#v, %v", runs, err)
	}
	missing := strings.Repeat("a", 40)
	if err := database.UpdateRunHeadSHA(runs[0].ID, missing); err != nil {
		t.Fatal(err)
	}
	if err := database.ReleaseOrphanedRun(runs[0].ID, missing, f.submitted, ""); err != nil {
		t.Fatal(err)
	}
	ref := ipc.OrphanSubmissionPrefix + runs[0].ID
	starts := 0
	client := serveOrphanHandler(t, func(ctx context.Context, raw json.RawMessage) (interface{}, error) {
		var request ipc.OrphanStartParams
		if err := json.Unmarshal(raw, &request); err != nil {
			return nil, err
		}
		if request.CheckOnly {
			return &ipc.OrphanStartResult{Ready: true}, nil
		}
		starts++
		if starts == 1 {
			return nil, fmt.Errorf("orphan_start_refused: simulated start failure after submission")
		}
		staged, err := git.Run(ctx, f.gate, "rev-parse", ref+"^{commit}")
		if err != nil || staged != request.HeadSHA {
			return nil, fmt.Errorf("exact local commit was not submitted")
		}
		return &ipc.OrphanStartResult{Ready: true, RunID: "successor"}, nil
	})
	env := &axiEnv{d: database, repo: repo, p: p, client: client}
	gateBefore := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover")

	first := commitLocalFile(t, f.local, "first.txt", "first redo\n", "first redo")
	if id, err := triggerRun(context.Background(), env, "feature/recover", first, nil, "full accepted intent", false); err == nil || id != "" {
		t.Fatalf("first start should be refused: %s, %v", id, err)
	}
	if staged := cliGit(t, f.gate, "rev-parse", ref+"^{commit}"); staged != first {
		t.Fatalf("refused start did not leave its submission behind: %s", staged)
	}

	head := commitLocalFile(t, f.local, "second.txt", "second redo\n", "second redo")
	localBefore := cliGit(t, f.local, "show-ref")
	id, err := triggerRun(context.Background(), env, "feature/recover", head, nil, "full accepted intent", false)
	if err != nil || id != "successor" {
		t.Fatalf("descendant retry: %s, %v", id, err)
	}
	if staged := cliGit(t, f.gate, "rev-parse", ref+"^{commit}"); staged != head {
		t.Fatalf("private submission = %s, want %s", staged, head)
	}
	if cliGit(t, f.local, "show-ref") != localBefore {
		t.Fatal("retry moved the local branch")
	}
	if cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover") != gateBefore {
		t.Fatal("retry moved the gate branch")
	}
}

// TestTriggerPushedOrphanRunAfterLostTailRelease covers the pushed half of the
// orphan class end to end at the CLI layer: a run that published the submitted
// head and then lost its later unpublished pipeline tail releases through the
// human recovery command, and a fresh run for a descendant local head goes
// through the audited private submission instead of a branch push. Rewritten
// history is still refused by name.
func TestTriggerPushedOrphanRunAfterLostTailRelease(t *testing.T) {
	f := newCLIRecoverFixture(t)
	p, err := paths.New()
	if err != nil {
		t.Fatal(err)
	}
	database, err := db.Open(p.DB())
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	repo, err := database.GetRepoByPath(f.local)
	if err != nil || repo == nil {
		t.Fatalf("repo: %#v, %v", repo, err)
	}
	runs, err := database.GetRunsByRepo(repo.ID)
	if err != nil || len(runs) != 1 {
		t.Fatalf("runs: %#v, %v", runs, err)
	}
	prior := runs[0]
	missing := strings.Repeat("a", 40)
	cliGit(t, f.local, "push", repo.PushURL(), "refs/heads/feature/recover:refs/heads/feature/recover")
	if err := database.UpdateRunPushBinding(prior.ID, db.PushBinding{
		HeadSHA: f.submitted, TargetKind: "upstream", TargetFingerprint: branchsync.TargetFingerprint(repo.PushURL()), Ref: "refs/heads/feature/recover",
	}); err != nil {
		t.Fatal(err)
	}
	if err := database.UpdateRunHeadSHA(prior.ID, missing); err != nil {
		t.Fatal(err)
	}
	gateHead := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover")
	gateRefs := cliGit(t, f.gate, "show-ref")

	out, err := executeCmd("sync", "--recover", "--yes")
	if err != nil {
		t.Fatalf("pushed orphan recovery: %v\n%s", err, out)
	}
	for _, want := range []string{prior.ID, missing, f.submitted, "unpublished fixes are lost", "published head " + f.submitted + " survives"} {
		if !strings.Contains(out, want) {
			t.Errorf("pushed orphan release missing %q:\n%s", want, out)
		}
	}
	if cliGit(t, f.gate, "show-ref") != gateRefs || cliGit(t, f.local, "rev-parse", "HEAD") != f.submitted {
		t.Fatal("pushed orphan release moved a ref or HEAD")
	}

	client := serveOrphanStub(t, prior.ID)
	env := &axiEnv{d: database, repo: repo, p: p, client: client}

	cliGit(t, f.local, "reset", "--hard", f.submitted+"^")
	rewritten := commitLocalFile(t, f.local, "rewritten.txt", "rewritten\n", "rewritten local history")
	if _, err := triggerRun(context.Background(), env, "feature/recover", rewritten, nil, "full accepted intent", false); err == nil || !strings.Contains(err.Error(), "descend") {
		t.Fatalf("rewritten head accepted after a pushed release: %v", err)
	}
	cliGit(t, f.local, "reset", "--hard", f.submitted)

	head := commitLocalFile(t, f.local, "redo.txt", "redone fix\n", "redo the lost pipeline tail")
	localBefore := cliGit(t, f.local, "show-ref")
	id, err := triggerRun(context.Background(), env, "feature/recover", head, nil, "full accepted intent", false)
	if err != nil || id != "successor" {
		t.Fatalf("descendant fresh run after pushed release: %s, %v", id, err)
	}
	if staged := cliGit(t, f.gate, "rev-parse", ipc.OrphanSubmissionPrefix+prior.ID+"^{commit}"); staged != head {
		t.Fatalf("private submission = %s, want %s", staged, head)
	}
	if cliGit(t, f.local, "show-ref") != localBefore {
		t.Fatal("fresh run moved the local branch")
	}
	if got := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover"); got != gateHead {
		t.Fatalf("fresh run moved the gate branch to %s, want %s", got, gateHead)
	}
}
