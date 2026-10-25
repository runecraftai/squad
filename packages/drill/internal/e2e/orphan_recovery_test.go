//go:build e2e

package e2e

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

// Exercise both real gate hooks and the new daemon entry, with no branch
// rewrite between an orphan release and validation of the exact local head.
func TestAxiOrphanReleaseStartsExactLocalHeadWithoutBranchMove(t *testing.T) {
	h := NewHarness(t, SetupOpts{Agent: "claude", Scenario: branchSyncScenario(t)})
	h.CommitChange("init-orphan", "seed.txt", "seed\n", "seed")
	if out, err := h.RunInDir(h.AddWorktree("init-orphan"), "init"); err != nil {
		t.Fatalf("init: %v\n%s", err, out)
	}
	const branch = "feature/orphan-recovery"
	h.CommitChange(branch, "feature.txt", "unsafe\n", "local work")
	operator := h.AddWorktree(branch)
	localHead := strings.TrimSpace(h.WorktreeRefSHA(branch))
	gateDir := filepath.Join(h.DrillHome, "repos", h.repoID()+".git")
	ctx := context.Background()
	// A newly initialized gate has no local heads; seed only this fixture's
	// branch from the independent upstream, without firing receive hooks.
	if out, err := h.runGit(ctx, gateDir, "fetch", "--no-tags", h.UpstreamDir, "refs/heads/main:refs/heads/"+branch); err != nil {
		t.Fatalf("seed gate fixture: %v\n%s", err, out)
	}
	gateHeadBytes, err := h.runGit(ctx, gateDir, "rev-parse", "refs/heads/"+branch)
	if err != nil {
		t.Fatalf("read fixture gate head: %v\n%s", err, gateHeadBytes)
	}
	gateHead := strings.TrimSpace(string(gateHeadBytes))
	if gateHead == localHead {
		t.Fatal("fixture lacks different local and gate heads")
	}
	database, err := db.Open(paths.WithRoot(h.DrillHome).DB())
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	prior, err := database.InsertRun(h.repoID(), branch, localHead, gateHead)
	if err != nil {
		t.Fatal(err)
	}
	missing := strings.Repeat("a", 40)
	if err := database.UpdateRunStatusWithVerifiedHead(prior.ID, types.RunFailed, missing); err != nil {
		t.Fatal(err)
	}
	out, err := h.RunInDir(operator, "axi", "sync", "--recover")
	if err != nil || !strings.Contains(out, "state: custody_returned") || !strings.Contains(out, "unpublished fixes are lost") {
		t.Fatalf("release: %v\n%s", err, out)
	}
	out, err = h.RunInDir(operator, "axi", "run", "--intent", axiIntent)
	if err != nil || !strings.Contains(out, "step: review") {
		t.Fatalf("fresh exact-head run: %v\n%s", err, out)
	}
	fresh := h.ActiveRun(branch)
	if fresh == nil || fresh.ID == prior.ID || fresh.SubmittedHeadSHA == nil || *fresh.SubmittedHeadSHA != localHead {
		t.Fatalf("fresh run did not use the local commit: %#v", fresh)
	}
	if got := strings.TrimSpace(h.WorktreeRefSHA(branch)); got != localHead {
		t.Fatalf("local branch moved: %s", got)
	}
	gotGate, err := h.runGit(ctx, gateDir, "rev-parse", "refs/heads/"+branch)
	if err != nil || strings.TrimSpace(string(gotGate)) != gateHead {
		t.Fatalf("gate branch moved: %v\n%s", err, gotGate)
	}
	if len(h.Runs()) != 2 {
		t.Fatalf("private submission hook started an extra run: %#v", h.Runs())
	}
}
