package steps

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

func setupTwoFileGitRepo(t *testing.T) (string, string, string) {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test",
			"GIT_AUTHOR_EMAIL=test@test.com",
			"GIT_COMMITTER_NAME=test",
			"GIT_COMMITTER_EMAIL=test@test.com",
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	run("init", "-b", "main")
	os.WriteFile(filepath.Join(dir, "base.txt"), []byte("base"), 0o644)
	run("add", "-A")
	run("commit", "-m", "base")
	baseSHA := strings.TrimSpace(string(mustOutput(t, "git", "-C", dir, "rev-parse", "HEAD")))
	run("checkout", "-b", "feature")
	os.WriteFile(filepath.Join(dir, "feature.txt"), []byte("feat"), 0o644)
	os.WriteFile(filepath.Join(dir, "extra.txt"), []byte("extra"), 0o644)
	run("add", "-A")
	run("commit", "-m", "add files")
	headSHA := strings.TrimSpace(string(mustOutput(t, "git", "-C", dir, "rev-parse", "HEAD")))
	return dir, baseSHA, headSHA
}

func mustOutput(t *testing.T, args ...string) []byte {
	t.Helper()
	out, err := exec.Command(args[0], args[1:]...).CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %v", args, err)
	}
	return out
}

func TestStandaloneReviewPreservesRiskFieldsAcrossComplement(t *testing.T) {
	dir, base, head := setupTwoFileGitRepo(t)
	var mu sync.Mutex
	var purposes []string
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		mu.Lock()
		purposes = append(purposes, opts.Purpose)
		mu.Unlock()
		switch opts.Purpose {
		case "review-consolidator":
			return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["feature.txt"],"risk_level":"high","risk_rationale":"significant","risk_scope":"pipeline-owned-delivery"}`)}, nil
		case "review-coverage-complement":
			return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["extra.txt"]}`)}, nil
		default:
			return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":[]}`)}, nil
		}
	}}
	findings, err := RunStandaloneReview(context.Background(), a, dir, base, head, "intent", 6, time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	if findings.RiskLevel != "high" {
		t.Fatalf("risk_level=%q, want high", findings.RiskLevel)
	}
	if findings.RiskRationale != "significant" {
		t.Fatalf("risk_rationale=%q, want significant", findings.RiskRationale)
	}
	if findings.RiskScope != "pipeline-owned-delivery" {
		t.Fatalf("risk_scope=%q, want pipeline-owned-delivery", findings.RiskScope)
	}
}
