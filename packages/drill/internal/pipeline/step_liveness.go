package pipeline

import (
	"context"
	"fmt"
	"time"
)

// Step liveness watchdog.
//
// A running step's agent invocation is an exec.CommandContext process
// configured through shellenv.ConfigureShellCommand (internal/agent). If that
// process dies (or becomes an uncollected zombie) while a descendant it
// spawned is still alive and holds its inherited stdout/stderr pipe open,
// the step's blocking read on that pipe never sees EOF: step.Execute, and
// with it the whole run, waits forever even though the step's own
// last_activity (and the already-existing step_quiet_warning display) has
// gone stale. Nothing today notices that the recorded agent_pid is no longer
// a live process, so the run reports "running" indefinitely instead of
// failing.
//
// watchStepLiveness closes that gap: it polls the step's recorded agent_pid
// for the lifetime of one executeStep call, and once the same pid is
// observed dead or zombie on stepLivenessConfirmations consecutive polls, it
// cancels the step's context. That cancellation reaches every agent
// invocation (every pipeline step runs sctx.Agent.Run(sctx.Ctx, ...)) and
// triggers the same ConfigureShellCommand-installed cmd.Cancel that already
// tears down a cancelled command's whole process group - including a
// surviving descendant holding the pipe open - so the blocked read
// unblocks and step.Execute returns with an error instead of hanging.
//
// Requiring more than one confirmation protects a step that is genuinely
// mid-exit: the normal exit path (internal/agent's emitAgentExited callback)
// clears agent_pid synchronously before the invocation returns, so a
// transiently dead-but-not-yet-cleared pid that is actually completing
// normally will not survive a second poll - the field will already be nil.
const (
	stepLivenessPollInterval  = 15 * time.Second
	stepLivenessConfirmations = 2
)

// stepLivenessEvidence is the proof the watchdog collected before cancelling
// a step's context, surfaced in the step's failure message and log so an
// operator sees why the run failed instead of a bare "context canceled".
type stepLivenessEvidence struct {
	pid          int
	state        string
	lastActivity string
	quietFor     time.Duration
}

// wrap composes the watchdog's evidence with the error step.Execute actually
// returned (ordinarily a context-cancellation error from the agent's exec
// invocation) into one operator-facing message.
func (ev *stepLivenessEvidence) wrap(err error) error {
	activity := ev.lastActivity
	if activity == "" {
		activity = "(no recorded activity)"
	}
	quiet := "unknown"
	if ev.quietFor > 0 {
		quiet = ev.quietFor.Round(time.Second).String()
	}
	return fmt.Errorf("step agent process pid %d is dead (state=%s); step was quiet for %s before failing (last activity: %q): %w",
		ev.pid, ev.state, quiet, activity, err)
}

// pollLivenessEvidence does a non-blocking read of a watchdog's evidence
// channel, returning nil when nothing has been reported yet.
func pollLivenessEvidence(ch <-chan *stepLivenessEvidence) *stepLivenessEvidence {
	select {
	case ev := <-ch:
		return ev
	default:
		return nil
	}
}

// watchStepLiveness polls stepID's recorded agent_pid until ctx is done. When
// the same nonzero pid is observed dead or zombie on consecutive polls, it
// sends evidence on result (buffered, sent at most once) and calls cancel
// exactly once, then returns. It is meant to run in its own goroutine for
// the duration of one executeStep call.
func (e *Executor) watchStepLiveness(ctx context.Context, cancel context.CancelFunc, stepID string, result chan<- *stepLivenessEvidence) {
	interval := e.stepLivenessPollInterval
	if interval <= 0 {
		interval = stepLivenessPollInterval
	}
	confirmations := e.stepLivenessConfirmations
	if confirmations <= 0 {
		confirmations = stepLivenessConfirmations
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	deadPID := 0
	deadStreak := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		step, err := e.db.GetStepResult(stepID)
		if err != nil || step == nil || step.AgentPID == nil || *step.AgentPID <= 0 {
			deadPID, deadStreak = 0, 0
			continue
		}
		pid := *step.AgentPID

		alive, state, stateErr := stepProcessState(pid)
		if stateErr != nil || alive {
			// Any alive/unknown observation breaks the "same pid dead on
			// consecutive polls" contract, so the streak resets even when the
			// pid is unchanged.
			deadPID, deadStreak = 0, 0
			continue
		}

		if pid != deadPID {
			deadPID = pid
			deadStreak = 0
		}
		deadStreak++
		if deadStreak < confirmations {
			continue
		}

		evidence := &stepLivenessEvidence{pid: pid, state: state}
		if step.LastActivity != nil {
			evidence.lastActivity = *step.LastActivity
		}
		if step.LastActivityAt != nil {
			evidence.quietFor = time.Since(time.Unix(*step.LastActivityAt, 0))
		}
		select {
		case result <- evidence:
		default:
		}
		cancel()
		return
	}
}
