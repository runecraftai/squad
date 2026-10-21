//go:build e2e

package e2e

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/types"
)

// Exercise actual CLI custody recovery after a native agent error, not a
// fabricated TOON response. Only the pipeline agent is deterministic here.
func TestOperatorFailedRunRecovery(t *testing.T) {
	h := NewHarness(t, SetupOpts{Agent: "claude", Scenario: branchSyncScenario(t)})
	originalScenario, err := os.ReadFile(h.Scenario)
	if err != nil {
		t.Fatal(err)
	}
	h.CommitChange("init-recovery", "seed.txt", "seed\n", "seed")
	if out, err := h.RunInDir(h.AddWorktree("init-recovery"), "init"); err != nil {
		t.Fatalf("init: %v\n%s", err, out)
	}
	const branch = "feature/operator-recovery"
	h.CommitChange(branch, "feature.txt", "unsafe\n", "feature")
	operator := h.AddWorktree(branch)
	if out, err := h.RunInDir(operator, "axi", "run", "--intent", axiIntent); err != nil || !strings.Contains(out, "step: review") {
		t.Fatalf("review gate: %v\n%s", err, out)
	}
	if out, err := h.RunInDir(operator, "axi", "respond", "--action", "fix", "--findings", "sync-1"); err != nil {
		t.Fatalf("preserve pipeline fix: %v\n%s", err, out)
	}

	// Fail the next native agent call after the pipeline has made a commit.
	// The fake agent rejects a directory as an edit target and exits nonzero.
	if err := os.WriteFile(h.Scenario, []byte(`actions:
  - edits:
      - path: "."
        new: "cannot write a directory"
`), 0o644); err != nil {
		t.Fatal(err)
	}
	failed, err := h.RunInDir(operator, "axi", "respond", "--action", "approve")
	if err == nil || !strings.Contains(failed, "outcome: failed") || !strings.Contains(failed, "code: recover_custody") {
		t.Fatalf("native failure with preserved custody: %v\n%s", err, failed)
	}
	run := h.WaitForRun(branch, 30*time.Second)
	if run.Status != types.RunFailed {
		t.Fatalf("run status = %s, want failed", run.Status)
	}
	recovered, err := h.RunInDir(operator, "axi", "sync", "--recover")
	if err != nil || !strings.Contains(recovered, "state: custody_returned") {
		t.Fatalf("recover custody: %v\n%s", err, recovered)
	}
	status, err := h.runGit(context.Background(), operator, "status", "--porcelain")
	if err != nil || len(status) != 0 {
		t.Fatalf("recovered branch is not clean: %v\n%s", err, status)
	}
	before := len(h.Runs())
	if before != 1 {
		t.Fatalf("raw recovery unexpectedly started a follow-on run: %d runs", before)
	}
	head := strings.TrimSpace(h.WorktreeRefSHA(branch))
	t.Logf("pre-fix real path: failed run %s; guarded custody returned; clean HEAD %s; runs=%d (no follow-on run)", run.ID, head, before)
	// Repeat the original entry point with the helper owning the failed
	// respond return. It must recover custody AND start a run without a steer.
	if err := os.WriteFile(h.Scenario, originalScenario, 0o644); err != nil {
		t.Fatal(err)
	}
	const helperBranch = "feature/helper-recovery"
	h.CommitChange(helperBranch, "feature.txt", "unsafe\n", "helper feature")
	operator = h.AddWorktree(helperBranch)
	if out, err := h.RunInDir(operator, "axi", "run", "--intent", axiIntent); err != nil || !strings.Contains(out, "step: review") {
		t.Fatalf("helper review gate: %v\n%s", err, out)
	}
	if out, err := h.RunInDir(operator, "axi", "respond", "--action", "fix", "--findings", "sync-1"); err != nil {
		t.Fatalf("helper preserved fix: %v\n%s", err, out)
	}
	if err := os.WriteFile(h.Scenario, []byte(`actions:
  - edits:
      - path: "."
        new: "cannot write a directory"
`), 0o644); err != nil {
		t.Fatal(err)
	}
	before = len(h.Runs())
	helperRun := h.ActiveRun(helperBranch)
	if helperRun == nil {
		t.Fatal("helper run is not active before the failing response")
	}
	// The recovered head includes a fix made only in the local gate.
	gateDir := filepath.Join(h.DrillHome, "repos", h.repoID()+".git")
	preserved, err := h.runGit(context.Background(), gateDir, "rev-parse", "refs/heads/"+helperBranch)
	if err != nil {
		t.Fatal(err)
	}
	head = strings.TrimSpace(string(preserved))
	if head == strings.TrimSpace(h.WorktreeRefSHA(helperBranch)) {
		t.Fatal("fixture lacks an unpublished pipeline fix to recover")
	}

	// Persistent native errors allow two automatic reruns, then report all
	// three ids (including the failed respond's run), never loop forever.
	root, err := findRepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	squadRoot := filepath.Clean(filepath.Join(root, "..", ".."))
	if err := os.Symlink(h.DrillBin, filepath.Join(h.BinDir, "drill")); err != nil {
		t.Fatal(err)
	}
	base := t.TempDir()
	if err := os.MkdirAll(filepath.Join(base, "state"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(squadRoot, "bin", "sq-drill-drive.sh"), "recovery", "respond", "--intent", axiIntent, "--action", "approve")
	cmd.Dir = operator
	cmd.Env = mergedEnv(os.Environ(), map[string]string{"SQUAD_BASE": base})
	out, driveErr := cmd.CombinedOutput()
	if driveErr == nil {
		t.Fatalf("persistent native failure should block:\n%s", out)
	}
	runs := h.Runs()
	if len(runs) != before+2 {
		t.Fatalf("automatic reruns = %d, want 2: %v\n%s", len(runs)-before, driveErr, out)
	}
	record, err := os.ReadFile(filepath.Join(base, "state", "recovery.status"))
	if err != nil || !strings.HasPrefix(string(record), "blocked:") {
		t.Fatalf("missing actionable blocked event: %v\n%s", err, record)
	}
	for _, attempt := range runs {
		if attempt.Branch != helperBranch {
			continue
		}
		if !strings.Contains(string(record), attempt.ID) {
			t.Errorf("blocked event omits attempted id %s: %s", attempt.ID, record)
		}
		// The first attempt precedes the pipeline fix; only the automatic
		// submissions must use the exact preserved-and-recovered head.
		if attempt.ID != helperRun.ID && (attempt.SubmittedHeadSHA == nil || *attempt.SubmittedHeadSHA != head) {
			t.Errorf("rerun changed the submitted head: %#v, want %s", attempt.SubmittedHeadSHA, head)
		}
	}
	if got := strings.TrimSpace(h.WorktreeRefSHA(helperBranch)); got != head {
		t.Errorf("local head after retries = %s, want recovered head %s", got, head)
	}
	status, err = h.runGit(context.Background(), operator, "status", "--porcelain")
	if err != nil || len(status) != 0 {
		t.Errorf("automatic recovery dirtied the branch: %v\n%s", err, status)
	}
	t.Logf("post-fix real path: %s\n%s", out, record)
}
