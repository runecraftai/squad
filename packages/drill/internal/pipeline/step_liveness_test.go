//go:build unix

package pipeline

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/agent"
	"github.com/runecraftai/squad/packages/drill/internal/shellenv"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

const (
	stepLivenessPipeLeaderEnv    = "DRILL_STEP_LIVENESS_PIPE_LEADER"
	stepLivenessPipeHolderEnv    = "DRILL_STEP_LIVENESS_PIPE_HOLDER"
	stepLivenessPipeHolderPIDEnv = "DRILL_STEP_LIVENESS_PIPE_HOLDER_PID_FILE"
)

// pipeWedgeAgent models a wedged native agent invocation for the incident
// regression test. Its Run starts a command whose leader exits immediately
// after forking a surviving descendant that inherits the leader's
// stdout/stderr pipe. It then blocks reading that pipe without ever calling
// Wait, so the exited leader stays an uncollected zombie and cmd.Cancel stays
// armed - exactly the production shape where the recorded agent_pid was
// dead/defunct while the step stayed blocked on a pipe a live descendant held
// open. Only the watchdog cancelling the step context can tear the group down.
type pipeWedgeAgent struct {
	holderPIDFile string

	mu     sync.Mutex
	leader int
}

func (a *pipeWedgeAgent) Name() string { return "pipe-wedge-test" }

func (a *pipeWedgeAgent) Close() error { return nil }

func (a *pipeWedgeAgent) leaderPID() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.leader
}

func (a *pipeWedgeAgent) Run(ctx context.Context, opts agent.RunOpts) (*agent.Result, error) {
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStepLivenessPipeLeaderHelper$")
	cmd.Env = append(os.Environ(),
		stepLivenessPipeLeaderEnv+"=1",
		stepLivenessPipeHolderPIDEnv+"="+a.holderPIDFile,
	)
	shellenv.ConfigureShellCommand(cmd)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start wedge command: %w", err)
	}
	a.mu.Lock()
	a.leader = cmd.Process.Pid
	a.mu.Unlock()

	if opts.OnLifecycle != nil {
		opts.OnLifecycle(agent.LifecycleEvent{
			Agent:   a.Name(),
			Phase:   agent.LifecyclePhaseStart,
			PID:     cmd.Process.Pid,
			Message: fmt.Sprintf("%s started pid=%d", a.Name(), cmd.Process.Pid),
		})
	}

	// Read the pipe to EOF. The leader has exited but its surviving descendant
	// still holds the write end, so this only returns once the descendant is
	// torn down. Nothing here calls Wait before the read completes: that keeps
	// the leader a zombie and cmd.Cancel armed for the watchdog's cancellation.
	_, readErr := io.Copy(io.Discard, stdout)
	_, _ = io.Copy(io.Discard, stderr)
	waitErr := cmd.Wait()

	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if waitErr != nil {
		return nil, waitErr
	}
	return nil, fmt.Errorf("wedge command ended without cancellation: %v", readErr)
}

// TestStepLivenessPipeLeaderHelper is re-executed as a subprocess by
// pipeWedgeAgent. It forks a descendant that inherits this process's stdout
// and stderr (the pipe the blocked reader holds), records the descendant's
// pid, and exits without reaping it - leaving a zombie leader and a live
// same-process-group descendant holding the pipe open.
func TestStepLivenessPipeLeaderHelper(t *testing.T) {
	if os.Getenv(stepLivenessPipeLeaderEnv) != "1" {
		t.Skip("pipe leader helper process only")
	}
	holder := exec.Command(os.Args[0], "-test.run=^TestStepLivenessPipeHolderHelper$")
	holder.Env = append(os.Environ(), stepLivenessPipeHolderEnv+"=1")
	holder.Stdout = os.Stdout
	holder.Stderr = os.Stderr
	if err := holder.Start(); err != nil {
		os.Exit(2)
	}
	if pidFile := os.Getenv(stepLivenessPipeHolderPIDEnv); pidFile != "" {
		_ = os.WriteFile(pidFile, []byte(strconv.Itoa(holder.Process.Pid)), 0o644)
	}
	os.Exit(0)
}

// TestStepLivenessPipeHolderHelper is the surviving descendant: it inherits
// the leader's stdout/stderr and stays alive until the process group is torn
// down, holding the pipe open.
func TestStepLivenessPipeHolderHelper(t *testing.T) {
	if os.Getenv(stepLivenessPipeHolderEnv) != "1" {
		t.Skip("pipe holder helper process only")
	}
	time.Sleep(60 * time.Second)
	os.Exit(0)
}

// TestExecutor_StepLivenessWatchdogFailsRunOnDeadAgentProcess reproduces the
// drill-wedged-run-zombie-child incident end to end: a running step's recorded
// agent process (the command leader) exits and is left as an uncollected
// zombie while a live descendant still holds the agent's stdout/stderr pipe
// open, so the step blocks on that pipe. Before the watchdog existed nothing
// noticed the recorded agent_pid was dead and the run waited forever. With the
// watchdog, the cancellation reaches the agent invocation, cmd.Cancel tears
// down the process group (descendant included), the blocked read unblocks, and
// the run fails naming the dead pid and process state. The test fails by
// timeout - not by assertion - on code that lacks the watchdog.
func TestExecutor_StepLivenessWatchdogFailsRunOnDeadAgentProcess(t *testing.T) {
	database, p, run, repo := setupTest(t)
	workDir := t.TempDir()

	holderPIDFile := filepath.Join(t.TempDir(), "holder.pid")
	ag := &pipeWedgeAgent{holderPIDFile: holderPIDFile}

	step := &adaptiveCallStep{
		name: types.StepReview,
		fn: func(sctx *StepContext) (*StepOutcome, error) {
			_, err := sctx.Agent.Run(sctx.Ctx, agent.RunOpts{Prompt: "wedge on a pipe a dead process's descendant holds open"})
			return nil, err
		},
	}

	executor := NewExecutor(database, p, nil, ag, []Step{step}, nil)
	// Tiny intervals so the test is fast; production uses the package
	// defaults (stepLivenessPollInterval, stepLivenessConfirmations).
	executor.stepLivenessPollInterval = 20 * time.Millisecond
	executor.stepLivenessConfirmations = 2

	done := make(chan error, 1)
	go func() {
		done <- executor.Execute(context.Background(), run, repo, workDir)
	}()

	var runErr error
	select {
	case runErr = <-done:
	case <-time.After(10 * time.Second):
		killHolder(holderPIDFile)
		t.Fatal("run did not fail within the bounded watchdog window: it hung instead of detecting the dead agent process (regression: step liveness watchdog not wired in)")
	}
	t.Cleanup(func() { killHolder(holderPIDFile) })

	if runErr == nil {
		t.Fatal("expected the run to fail once its recorded agent process was observed dead, got nil error")
	}
	leaderPID := ag.leaderPID()
	if leaderPID == 0 {
		t.Fatal("test agent never recorded a leader pid")
	}
	if !strings.Contains(runErr.Error(), fmt.Sprintf("pid %d", leaderPID)) {
		t.Errorf("expected failure evidence to name the dead pid %d, got: %v", leaderPID, runErr)
	}
	if !strings.Contains(runErr.Error(), "is dead") {
		t.Errorf("expected failure evidence to say the process is dead, got: %v", runErr)
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
}

func killHolder(pidFile string) {
	b, err := os.ReadFile(pidFile)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 0 {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
}
