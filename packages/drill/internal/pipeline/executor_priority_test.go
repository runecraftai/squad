package pipeline

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/config"
	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

func waitForFixReviewRound(t *testing.T, database *db.DB, runID string, round int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		steps, err := database.GetStepsByRun(runID)
		if err != nil {
			t.Fatal(err)
		}
		for _, step := range steps {
			stats, err := database.StepRoundStats(step.ID)
			if err == nil && stats.TotalRounds == round && step.Status == types.StepStatusFixReview {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("fix review evaluation %d did not arrive", round)
}

func TestExecutor_ExhaustedBudgetStillPresentsAskUser(t *testing.T) {
	database, p, run, repo := setupTest(t)
	cfg := &config.Config{AutoFix: config.AutoFix{Review: 2, MaxFixRounds: 1}}
	var fixes atomic.Int32
	step := &adaptiveCallStep{name: types.StepReview, fn: func(sctx *StepContext) (*StepOutcome, error) {
		if sctx.Fixing {
			fixes.Add(1)
		}
		return &StepOutcome{NeedsApproval: true, AutoFixable: true, Findings: `{"findings":[{"id":"decision","severity":"error","action":"ask-user","description":"requirement"},{"id":"bug","severity":"error","action":"auto-fix","description":"independent bug"}]}`}, nil
	}}
	exec := NewExecutor(database, p, cfg, nil, []Step{step}, nil)
	events := collectEvents(exec)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	workDir := t.TempDir()
	go func() { done <- exec.Execute(ctx, run, repo, workDir) }()
	waitForFixReviewRound(t, database, run.ID, 2)
	if fixes.Load() != 1 {
		t.Fatalf("fixes = %d, want one independent objective fix", fixes.Load())
	}
	gate := waitForEvent(t, events, ipc.EventStepCompleted, string(types.StepStatusFixReview))
	if gate.Findings == nil || len(mustParseFindingItems(t, *gate.Findings)) != 2 {
		t.Fatalf("decision not presented with complete known list: %+v", gate)
	}
	if err := exec.Respond(types.StepReview, types.ActionFix, []string{"decision", "bug"}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "used 1/1 fix executions (1 auto + 0 user); next fix refused (not executed)") {
			t.Fatalf("expected refusal without consuming a user execution: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("refusal did not finish")
	}
	if fixes.Load() != 1 {
		t.Errorf("refused fix executed: calls = %d", fixes.Load())
	}
	failure := events.findLast(ipc.EventStepCompleted, string(types.StepStatusFailed))
	if failure == nil || failure.Error == nil || !strings.Contains(*failure.Error, "next fix refused") || failure.Findings == nil {
		t.Fatalf("failure event lost refusal or unresolved findings: %+v", failure)
	}
}

func TestExecutor_ResumeHonorsFixExecutionBudget(t *testing.T) {
	for _, previousFixes := range []int{2, 3} {
		t.Run(fmt.Sprintf("%d prior fixes", previousFixes), func(t *testing.T) {
			database, p, run, repo := setupTest(t)
			if err := database.UpdateRunStatus(run.ID, types.RunRunning); err != nil {
				t.Fatal(err)
			}
			result, err := database.InsertStepResult(run.ID, types.StepReview)
			if err != nil {
				t.Fatal(err)
			}
			if err := database.StartStep(result.ID); err != nil {
				t.Fatal(err)
			}
			findings := `{"findings":[{"id":"requirement","severity":"error","action":"ask-user","description":"still unresolved"}]}`
			for i := 0; i <= previousFixes; i++ {
				trigger := "auto_fix"
				if i == 0 {
					trigger = "initial"
				}
				round, err := database.InsertStepRound(result.ID, i+1, trigger, &findings, nil, 1)
				if err != nil {
					t.Fatal(err)
				}
				if i < previousFixes {
					ids := `["requirement"]`
					if err := database.SetStepRoundSelection(round.ID, &ids, db.RoundSelectionSourceAutoFix); err != nil {
						t.Fatal(err)
					}
				}
			}
			if err := database.ParkStepForApproval(run.ID, result.ID, types.StepStatusFixReview, 1, &findings); err != nil {
				t.Fatal(err)
			}
			run, err = database.GetRun(run.ID)
			if err != nil {
				t.Fatal(err)
			}
			var fixes atomic.Int32
			step := &adaptiveCallStep{name: types.StepReview, fn: func(sctx *StepContext) (*StepOutcome, error) {
				if !sctx.Fixing {
					t.Error("resume reran the initial evaluation")
				}
				fixes.Add(1)
				return &StepOutcome{NeedsApproval: true, Findings: findings}, nil
			}}
			exec := NewExecutor(database, p, &config.Config{AutoFix: config.AutoFix{MaxFixRounds: 3}}, nil, []Step{step}, nil)
			events := collectEvents(exec)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			workDir := t.TempDir()
			go func() { done <- exec.Resume(ctx, run, repo, workDir) }()
			waitForEvent(t, events, ipc.EventStepCompleted, string(types.StepStatusFixReview))
			if err := exec.Respond(types.StepReview, types.ActionFix, []string{"requirement"}); err != nil {
				t.Fatal(err)
			}
			if previousFixes < 3 {
				waitForFixReviewRound(t, database, run.ID, 4)
				if err := exec.Respond(types.StepReview, types.ActionFix, []string{"requirement"}); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case err := <-done:
				if err == nil || !strings.Contains(err.Error(), "used 3/3 fix executions") || !strings.Contains(err.Error(), "next fix refused") {
					t.Fatalf("resume did not enforce the budget: %v", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("resume exceeded the budget instead of refusing")
			}
			if got := int(fixes.Load()); got != 3-previousFixes {
				t.Errorf("resumed fixes = %d, want %d", got, 3-previousFixes)
			}
			stats, err := database.StepRoundStats(result.ID)
			if err != nil || stats.FixRounds != 3 {
				t.Fatalf("recorded fixes = %d, want 3: %v", stats.FixRounds, err)
			}
		})
	}
}

// A user-triggered fix can be authorized without selected finding ids, so a
// recovered gate must count executed fix rounds, not recorded selections.
func TestExecutor_ResumeCountsFixWithoutSelection(t *testing.T) {
	database, p, run, repo := setupTest(t)
	if err := database.UpdateRunStatus(run.ID, types.RunRunning); err != nil {
		t.Fatal(err)
	}
	result, err := database.InsertStepResult(run.ID, types.StepReview)
	if err != nil {
		t.Fatal(err)
	}
	if err := database.StartStep(result.ID); err != nil {
		t.Fatal(err)
	}
	findings := `{"findings":[{"id":"requirement","severity":"error","action":"ask-user","description":"still unresolved"}]}`
	prior := []struct {
		trigger string
		source  string
	}{
		{"initial", db.RoundSelectionSourceAutoFix},
		{"auto_fix", db.RoundSelectionSourceUser},
		{"auto_fix", ""},
		{"auto_fix", ""},
	}
	for i, round := range prior {
		inserted, err := database.InsertStepRound(result.ID, i+1, round.trigger, &findings, nil, 1)
		if err != nil {
			t.Fatal(err)
		}
		if round.source != "" {
			source := round.source
			ids := `["requirement"]`
			if err := database.SetStepRoundSelection(inserted.ID, &ids, source); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := database.ParkStepForApproval(run.ID, result.ID, types.StepStatusFixReview, 1, &findings); err != nil {
		t.Fatal(err)
	}
	run, err = database.GetRun(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	step := &adaptiveCallStep{name: types.StepReview, fn: func(sctx *StepContext) (*StepOutcome, error) {
		t.Error("recovery executed a fix beyond the shared budget")
		return &StepOutcome{NeedsApproval: true, Findings: findings}, nil
	}}
	exec := NewExecutor(database, p, &config.Config{AutoFix: config.AutoFix{MaxFixRounds: 3}}, nil, []Step{step}, nil)
	events := collectEvents(exec)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- exec.Resume(ctx, run, repo, t.TempDir()) }()
	waitForEvent(t, events, ipc.EventStepCompleted, string(types.StepStatusFixReview))
	if err := exec.Respond(types.StepReview, types.ActionFix, nil); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "used 3/3 fix executions (1 auto + 2 user)") {
			t.Fatalf("recovery undercounted executed fixes: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("recovery exceeded the budget instead of refusing")
	}
	stats, err := database.StepRoundStats(result.ID)
	if err != nil || stats.FixRounds != 3 {
		t.Fatalf("recorded fixes = %d, want 3: %v", stats.FixRounds, err)
	}
}

// S7: a requirement is already known, but timeout documentation and a script
// header must not consume the fix budget before that requirement is presented.
func TestExecutor_DecisionBeforeInfoOnlyFix(t *testing.T) {
	for _, tc := range []struct {
		name, severity, action string
		needsApproval          bool
	}{
		{"info ask-user", "info", "ask-user", false},
		{"error ask-user", "error", "ask-user", true},
		{"error needs approval", "error", "no-op", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, p, run, repo := setupTest(t)
			cfg := &config.Config{AutoFix: config.AutoFix{Review: 3}}
			findings := fmt.Sprintf(`{"findings":[{"id":"requirement","severity":%q,"action":%q,"description":"central requirement"},{"id":"timeout-doc","severity":"info","action":"auto-fix","description":"timeout documentation"},{"id":"header","severity":"info","action":"auto-fix","description":"script header"}]}`, tc.severity, tc.action)
			var fixes atomic.Int32
			step := &adaptiveCallStep{name: types.StepReview, fn: func(sctx *StepContext) (*StepOutcome, error) {
				if sctx.Fixing {
					fixes.Add(1)
					items := mustParseFindingItems(t, sctx.PreviousFindings)
					if len(items) == 3 {
						return &StepOutcome{}, nil // one authorized batch resolves all
					}
					// An automatic info-only fix leaves the central requirement
					// unresolved, just as both cosmetic fixes did in S7.
				}
				return &StepOutcome{NeedsApproval: tc.needsApproval, AutoFixable: true, Findings: findings}, nil
			}}
			exec := NewExecutor(database, p, cfg, nil, []Step{step}, nil)
			events := collectEvents(exec)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			workDir := t.TempDir()
			go func() { done <- exec.Execute(ctx, run, repo, workDir) }()

			deadline := time.After(5 * time.Second)
			for events.findLast(ipc.EventStepCompleted, string(types.StepStatusAwaitingApproval)) == nil {
				select {
				case err := <-done:
					t.Fatalf("run ended before presenting decision: %v; fixes = %d", err, fixes.Load())
				case <-deadline:
					t.Fatal("decision was not presented")
				case <-time.After(10 * time.Millisecond):
				}
			}
			if got := fixes.Load(); got != 0 {
				t.Errorf("executed %d fixes before presenting the requirement, want 0", got)
			}
			gate := events.findLast(ipc.EventStepCompleted, string(types.StepStatusAwaitingApproval))
			if gate.Findings == nil || len(mustParseFindingItems(t, *gate.Findings)) != 3 {
				t.Fatalf("gate lost known findings: %+v", gate)
			}
			logData, err := os.ReadFile(filepath.Join(p.RunLogDir(run.ID), "review.log"))
			if err != nil {
				t.Fatalf("read step log: %v", err)
			}
			if !strings.Contains(string(logData), "info-only auto-fix deferred") {
				t.Errorf("durable log did not record why the info-only fix was not applied:\n%s", logData)
			}
			if err := exec.Respond(types.StepReview, types.ActionFix, []string{"requirement", "timeout-doc", "header"}); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("authorized batch did not finish")
			}
			if got := fixes.Load(); got != 1 {
				t.Errorf("fixes after authorization = %d, want one batch", got)
			}
		})
	}
}

// The durable log names the shared execution budget: after one automatic fix,
// the next user-triggered fix is execution 2 of 3, not a user-only 1 of 3.
func TestExecutor_UserFixLogReportsSharedExecutionBudget(t *testing.T) {
	database, p, run, repo := setupTest(t)
	cfg := &config.Config{AutoFix: config.AutoFix{Review: 3}}
	calls := 0
	step := &adaptiveCallStep{name: types.StepReview, fn: func(sctx *StepContext) (*StepOutcome, error) {
		calls++
		if calls == 1 {
			return &StepOutcome{AutoFixable: true, Findings: `{"findings":[{"id":"docs","severity":"info","action":"auto-fix","description":"timeout documentation"}]}`}, nil
		}
		return &StepOutcome{NeedsApproval: true, Findings: `{"findings":[{"id":"requirement","severity":"error","action":"ask-user","description":"central requirement"}]}`}, nil
	}}
	exec := NewExecutor(database, p, cfg, nil, []Step{step}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	workDir := t.TempDir()
	go func() { done <- exec.Execute(ctx, run, repo, workDir) }()

	waitForFixReviewRound(t, database, run.ID, 2)
	if err := exec.Respond(types.StepReview, types.ActionFix, []string{"requirement"}); err != nil {
		t.Fatal(err)
	}
	waitForFixReviewRound(t, database, run.ID, 3)
	logData, err := os.ReadFile(filepath.Join(p.RunLogDir(run.ID), "review.log"))
	if err != nil {
		t.Fatalf("read step log: %v", err)
	}
	if !strings.Contains(string(logData), "user-fix execution 2/3 starting after round 2") {
		t.Errorf("user fix did not report the shared execution budget:\n%s", logData)
	}
	if err := exec.Respond(types.StepReview, types.ActionApprove, nil); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("run did not finish")
	}
}
