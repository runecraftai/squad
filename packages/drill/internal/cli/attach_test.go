package cli

import (
	"context"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/gate"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
	"github.com/runecraftai/squad/packages/drill/internal/wizard"
)

// TestRootInteractiveWizardFailsLoudlyWhenRunRegistrationIsSlow covers
// issue #122 defect 3. Prior behavior: if the daemon didn't register a
// run after push (e.g. gate hook disabled by husky), the wizard's wait
// silently returned nil, the wizard declared success, and the command
// printed "No active run" with exit code 0. That masked the real failure.
// After the fix, an error surfaces all the way to the CLI.
func TestRootInteractiveWizardFailsLoudlyWhenRunRegistrationIsSlow(t *testing.T) {
	setupTestRepo(t)
	drillHome := makeSocketSafeTempDir(t)
	t.Setenv("DRILL_HOME", drillHome)
	p := paths.WithRoot(drillHome)

	d, err := db.Open(p.DB())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })

	if _, _, err := gate.Init(context.Background(), d, p, "."); err != nil {
		t.Fatal(err)
	}

	startTestDaemon(t, p, d)

	prevInteractive := terminalInteractive
	terminalInteractive = func() bool { return true }
	defer func() { terminalInteractive = prevInteractive }()

	prevWizardRun := wizardRun
	wizardRun = func(cfg wizard.Config) (wizard.Result, error) {
		if cfg.WaitForRun == nil {
			t.Fatal("expected wait function")
		}
		if err := cfg.WaitForRun(context.Background(), "feat/slow"); err != nil {
			return wizard.Result{}, err
		}
		return wizard.Result{Success: true, Pushed: true, TargetBranch: "feat/slow"}, nil
	}
	defer func() { wizardRun = prevWizardRun }()

	prevRunTUI := runTUI
	runTUI = func(string, *ipc.Client, *ipc.RunInfo, string) error {
		t.Fatal("should not attach when no run is visible yet")
		return nil
	}
	defer func() { runTUI = prevRunTUI }()

	_, err = executeCmd()
	if err == nil {
		t.Fatal("executeCmd() should return an error when the daemon doesn't register a run")
	}
	if !strings.Contains(err.Error(), "feat/slow") {
		t.Errorf("error should name the branch we were waiting for, got: %v", err)
	}
}
