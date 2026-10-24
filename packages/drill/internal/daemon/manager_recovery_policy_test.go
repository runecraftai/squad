package daemon

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/agent"
	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/executionpolicy"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

func TestResumeRecoveredRunRemovesWorktreeWhenPolicyUnavailable(t *testing.T) {
	p := paths.WithRoot(t.TempDir())
	if err := p.EnsureDirs(); err != nil {
		t.Fatal(err)
	}
	d, err := db.Open(p.DB())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	repo, headSHA := setupTestGitRepo(t, p, d, "repo1")
	run, err := d.InsertRun(repo.ID, "feature", headSHA, headSHA)
	if err != nil {
		t.Fatal(err)
	}
	gateDir := p.RepoDir(repo.ID)
	workDir := p.WorktreeDir(repo.ID, run.ID)
	if err := git.WorktreeAdd(context.Background(), gateDir, workDir, headSHA); err != nil {
		t.Fatalf("WorktreeAdd: %v", err)
	}

	previous := newRunExecutionPolicy
	newRunExecutionPolicy = func(string) (executionpolicy.ExecutionPolicy, error) {
		return nil, errors.New("execution policy unavailable")
	}
	t.Cleanup(func() { newRunExecutionPolicy = previous })

	m := NewRunManager(d, p, nil)
	m.resumeRecoveredRun(recoveredRunPlan{
		run:     run,
		repo:    repo,
		workDir: workDir,
		gateDir: gateDir,
		agent:   agent.NewNoop(),
	})

	if _, err := os.Stat(workDir); !os.IsNotExist(err) {
		t.Fatalf("recovered worktree survived policy failure: stat err=%v", err)
	}
	got, err := d.GetRun(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != types.RunFailed {
		t.Fatalf("recovered run status = %s, want %s", got.Status, types.RunFailed)
	}
}
