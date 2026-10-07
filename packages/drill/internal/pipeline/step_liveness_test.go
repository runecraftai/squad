//go:build unix

package pipeline

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/types"
)

// TestExecutor_StepLivenessWatchdogFailsRunOnDeadAgentProcess reproduces the
// drill-wedged-run-zombie-child incident: a running step's recorded agent
// process dies (here, as a genuine uncollected zombie child of the test
// process, matching the production evidence's "<defunct>" child) while the
// step itself is still blocked waiting on it - exactly what a wedged
// exec.CommandContext-based agent invocation looks like from the executor's
// point of view. Before the step liveness watchdog existed, nothing ever
// noticed the recorded agent_pid was dead, so step.Execute (and the whole
// run) waited forever. This test fails by timeout - not by assertion - on
// code that lacks the watchdog, which is the point: it is a regression
// guard against the hang coming back, not just against a changed message.
func TestExecutor_StepLivenessWatchdogFailsRunOnDeadAgentProcess(t *testing.T) {
	database, p, run, repo := setupTest(t)
	workDir := t.TempDir()

	var zombieCmd *exec.Cmd
	step := &adaptiveCallStep{
		name: types.StepReview,
		fn: func(sctx *StepContext) (*StepOutcome, error) {
			// Simulate a real agent invocation: start a direct child
			// process and deliberately never reap it, exactly like the
			// production incident evidence (an uncollected "<defunct>"
			// child). The child exits almost immediately, so it becomes a
			// genuine zombie a kill(pid, 0) + `ps stat` liveness check can
			// observe - no mocking of process state involved.
			cmd := exec.Command("true")
			if err := cmd.Start(); err != nil {
				return nil, fmt.Errorf("start test zombie process: %w", err)
			}
			zombieCmd = cmd
			pid := cmd.Process.Pid
			if err := sctx.DB.SetStepAgentActivity(sctx.StepResultID, fmt.Sprintf("test agent started pid=%d", pid), &pid); err != nil {
				return nil, fmt.Errorf("record test agent pid: %w", err)
			}
			// Block exactly like a wedged native agent invocation would: a
			// blind blocking read on a pipe a dead process's live
			// descendant still holds open. Only context cancellation (the
			// watchdog's job, via the same cmd.Cancel every real agent
			// adapter installs) unblocks it.
			<-sctx.Ctx.Done()
			return nil, sctx.Ctx.Err()
		},
	}

	executor := NewExecutor(database, p, nil, nil, []Step{step}, nil)
	// Tiny intervals so the test is fast; production uses the package
	// defaults (stepLivenessPollInterval, stepLivenessConfirmations).
	executor.stepLivenessPollInterval = 20 * time.Millisecond
	executor.stepLivenessConfirmations = 2

	done := make(chan error, 1)
	go func() {
		done <- executor.Execute(context.Background(), run, repo, workDir)
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected the run to fail once its recorded agent process was observed dead, got nil error")
		}
		if !strings.Contains(err.Error(), fmt.Sprintf("pid %d", zombieCmd.Process.Pid)) {
			t.Errorf("expected failure evidence to name the dead pid %d, got: %v", zombieCmd.Process.Pid, err)
		}
		if !strings.Contains(err.Error(), "is dead") {
			t.Errorf("expected failure evidence to say the process is dead, got: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("run did not fail within the bounded watchdog window: it hung instead of detecting the dead agent process (regression: step liveness watchdog not wired in)")
	}

	steps, err := database.GetStepsByRun(run.ID)
	if err != nil {
		t.Fatalf("get steps by run: %v", err)
	}
	found := false
	for _, s := range steps {
		if s.StepName != types.StepReview {
			continue
		}
		found = true
		if s.Status != types.StepStatusFailed {
			t.Errorf("expected review step status %q, got %q", types.StepStatusFailed, s.Status)
		}
		if s.Error == nil || !strings.Contains(*s.Error, "is dead") {
			got := "<nil>"
			if s.Error != nil {
				got = *s.Error
			}
			t.Errorf("expected step error to record the dead-process evidence, got: %s", got)
		}
		if s.AgentPID != nil {
			t.Errorf("expected agent_pid to be cleared on failure, got %v", *s.AgentPID)
		}
	}
	if !found {
		t.Fatal("review step result not found")
	}

	if zombieCmd != nil {
		// Reap the zombie now that the assertions above have observed it;
		// otherwise it lingers as a zombie for the rest of the test binary's
		// life.
		_ = zombieCmd.Wait()
	}
}
