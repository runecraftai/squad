package cli

import (
	"os/exec"
	"regexp"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

// TestAxiSyncRecoverGateAtLocalHeadAdvertisesAnchorExit drives the CLI through
// the reproduced incident: a failed verified run whose gate branch equals the
// operator head while the preserved pipeline head survives only as an
// unreachable object in the validated gate. The refusal must keep the
// gate-divergence safety, print a next_action, and that exact command must be
// executable before the documented keep-local retry returns custody.
func TestAxiSyncRecoverGateAtLocalHeadAdvertisesAnchorExit(t *testing.T) {
	f := newCLIRecoverFixture(t)
	// The shared fixture models a cancellation; the incident run is a failed
	// run whose preserved head was verified by the pipeline.
	p, err := paths.New()
	if err != nil {
		t.Fatal(err)
	}
	database, err := db.Open(p.DB())
	if err != nil {
		t.Fatal(err)
	}
	repo, err := database.GetRepoByPath(f.local)
	if err != nil || repo == nil {
		database.Close()
		t.Fatalf("repo: %#v, %v", repo, err)
	}
	runs, err := database.GetRunsByRepo(repo.ID)
	if err != nil || len(runs) != 1 {
		database.Close()
		t.Fatalf("runs: %#v, %v", runs, err)
	}
	if err := database.UpdateRunStatusWithVerifiedHead(runs[0].ID, types.RunFailed, f.preserved); err != nil {
		database.Close()
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	// Both branches at the submitted head; the preserved head is only an
	// unreachable object in the gate and there is no recovery anchor.
	cliGit(t, f.gate, "update-ref", "refs/heads/feature/recover", f.submitted)

	out, err := executeCmd("axi", "sync", "--recover")
	if err == nil {
		t.Fatalf("gate divergence should refuse:\n%s", out)
	}
	if !strings.Contains(out, "safety: blocked_recover_gate_diverged") {
		t.Fatalf("refusal lost the gate-divergence safety:\n%s", out)
	}
	if !strings.Contains(out, "code: anchor_preserved_head") {
		t.Fatalf("refusal has no actionable exit:\n%s", out)
	}

	command := nextActionFetch(t, out)
	anchor := anchorRefForRun(t, command)
	run := exec.Command("sh", "-c", command)
	run.Dir = f.local
	if shellOut, shellErr := run.CombinedOutput(); shellErr != nil {
		t.Fatalf("advertised command %q failed: %v\n%s", command, shellErr, shellOut)
	}
	if got := cliGit(t, f.local, "rev-parse", anchor); got != f.preserved {
		t.Fatalf("%s = %s, want preserved %s", anchor, got, f.preserved)
	}

	out, err = executeCmd("axi", "sync", "--recover", "--keep-local")
	if err != nil {
		t.Fatalf("keep-local recovery after anchoring: %v\n%s", err, out)
	}
	if !strings.Contains(out, "recovered: true") {
		t.Fatalf("keep-local did not return custody:\n%s", out)
	}
	if got := cliGit(t, f.local, "rev-parse", "HEAD"); got != f.submitted {
		t.Fatalf("keep-local moved the worktree: HEAD = %s", got)
	}
	if got := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover"); got != f.submitted {
		t.Fatalf("keep-local adopted the diverged gate: gate branch = %s", got)
	}
}

var nextActionCommandLine = regexp.MustCompile(`(?m)^\s*command:\s*(.*)$`)

func nextActionFetch(t *testing.T, out string) string {
	t.Helper()
	for _, match := range nextActionCommandLine.FindAllStringSubmatch(out, -1) {
		candidate := strings.TrimSpace(strings.Trim(strings.TrimSpace(match[1]), `"`))
		if strings.HasPrefix(candidate, "git fetch") {
			return candidate
		}
	}
	t.Fatalf("no advertised fetch command in output:\n%s", out)
	return ""
}

var recoveryAnchorPattern = regexp.MustCompile(`refs/drill/recover/[A-Za-z0-9]+`)

func anchorRefForRun(t *testing.T, command string) string {
	t.Helper()
	ref := recoveryAnchorPattern.FindString(command)
	if ref == "" {
		t.Fatalf("advertised command does not name the recovery anchor: %s", command)
	}
	return ref
}
