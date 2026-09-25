package steps

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/agent"
)

func TestStandaloneReviewUsesReviewStepEngine(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var mu sync.Mutex
	var purposes []string
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		mu.Lock()
		purposes = append(purposes, opts.Purpose)
		mu.Unlock()
		if opts.Purpose == "review-consolidator" {
			return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["feature.txt"],"risk_level":"low","risk_rationale":"no issues","risk_scope":"source-or-external"}`)}, nil
		}
		return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":["feature.txt"]}`)}, nil
	}}
	findings, err := RunStandaloneReview(context.Background(), a, dir, base, head, "intent", 6, time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(purposes) != len(reviewLensInstructions)+1 {
		t.Fatalf("calls=%v", purposes)
	}
	gotLenses := make(map[string]bool, len(reviewLensInstructions))
	for _, purpose := range purposes[:len(reviewLensInstructions)] {
		gotLenses[purpose] = true
	}
	for _, lens := range reviewLensInstructions {
		if !gotLenses["review-lens:"+lens.name] {
			t.Errorf("missing lens %q in %v", lens.name, purposes)
		}
	}
	if purposes[len(purposes)-1] != "review-consolidator" {
		t.Fatalf("consolidator purpose=%q", purposes[len(purposes)-1])
	}
	if len(findings.Items) != 0 {
		t.Fatalf("findings=%+v", findings)
	}
	if findings.RiskLevel != "low" {
		t.Fatalf("risk_level=%q", findings.RiskLevel)
	}
	if findings.RiskRationale != "no issues" {
		t.Fatalf("risk_rationale=%q", findings.RiskRationale)
	}
	if findings.RiskScope != "source-or-external" {
		t.Fatalf("risk_scope=%q", findings.RiskScope)
	}
}
