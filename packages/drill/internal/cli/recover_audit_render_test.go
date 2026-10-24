package cli

import (
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
)

// orphanRunHead turns the fixture's run into the measured missing-object case
// and optionally records the release.
func orphanRunHead(t *testing.T, local string, release bool) (string, string) {
	t.Helper()
	p, err := paths.New()
	if err != nil {
		t.Fatal(err)
	}
	database, err := db.Open(p.DB())
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	repo, err := database.GetRepoByPath(local)
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
	if release {
		if err := database.ReleaseOrphanedRun(runs[0].ID, missing, cliGit(t, local, "rev-parse", "HEAD"), ""); err != nil {
			t.Fatal(err)
		}
	}
	return runs[0].ID, missing
}

func TestHumanRecoverShowsLossAuditBeforeRelease(t *testing.T) {
	f := newCLIRecoverFixture(t)
	runID, missing := orphanRunHead(t, f.local, false)
	previous := syncInteractive
	syncInteractive = func() bool { return false }
	t.Cleanup(func() { syncInteractive = previous })

	out, err := executeCmd("sync", "--recover")
	if err == nil {
		t.Fatalf("expected non-interactive refusal:\n%s", out)
	}
	for _, want := range []string{runID, missing, "recorded: " + missing, "missing from this repository and the local gate", "unpublished fixes are lost", "no branch, ref, or worktree moves"} {
		if !strings.Contains(out, want) {
			t.Errorf("pre-release audit missing %q:\n%s", want, out)
		}
	}
	for _, unwanted := range []string{"preserved", "preserve"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("pre-release output claims preservation with %q:\n%s", unwanted, out)
		}
	}
	if got := cliGit(t, f.local, "rev-parse", "HEAD"); got != f.submitted {
		t.Fatal("refused confirmation moved HEAD")
	}
}

func TestHumanRecoverShowsLossAuditAfterRelease(t *testing.T) {
	f := newCLIRecoverFixture(t)
	gateBefore := cliGit(t, f.gate, "show-ref")
	runID, missing := orphanRunHead(t, f.local, false)

	out, err := executeCmd("sync", "--recover", "--yes")
	if err != nil {
		t.Fatalf("orphan recovery: %v\n%s", err, out)
	}
	for _, want := range []string{runID, missing, f.submitted, "recorded: " + missing, "unpublished fixes are lost", "audit:"} {
		if !strings.Contains(out, want) {
			t.Errorf("post-release audit missing %q:\n%s", want, out)
		}
	}
	for _, unwanted := range []string{"preserved", "preserve"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("post-release output claims preservation with %q:\n%s", unwanted, out)
		}
	}
	if got := cliGit(t, f.local, "rev-parse", "HEAD"); got != f.submitted {
		t.Fatal("orphan recovery moved HEAD")
	}
	if cliGit(t, f.gate, "show-ref") != gateBefore {
		t.Fatal("orphan recovery moved a gate ref")
	}
}
