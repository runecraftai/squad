package steps

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/agent"
	"github.com/runecraftai/squad/packages/drill/internal/config"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

type controlledReviewAgent struct {
	run func(context.Context, agent.RunOpts) (*agent.Result, error)
}

func (a controlledReviewAgent) Name() string { return "controlled" }
func (a controlledReviewAgent) Run(ctx context.Context, opts agent.RunOpts) (*agent.Result, error) {
	return a.run(ctx, opts)
}
func (a controlledReviewAgent) Close() error { return nil }

func TestSpecializedReviewBatch_BoundsConcurrencyAndOrdersResults(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var active, peak atomic.Int32
	a := controlledReviewAgent{run: func(ctx context.Context, opts agent.RunOpts) (*agent.Result, error) {
		validPurpose := false
		for _, lens := range reviewLensInstructions {
			validPurpose = validPurpose || opts.Purpose == "review-lens:"+lens.name
		}
		if !validPurpose || opts.Session != nil {
			t.Errorf("invalid purpose/session: %#v", opts)
		}
		current := active.Add(1)
		for {
			old := peak.Load()
			if current <= old || peak.CompareAndSwap(old, current) {
				break
			}
		}
		defer active.Add(-1)
		select {
		case <-time.After(20 * time.Millisecond):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":[]}`)}, nil
	}}
	snapshot := newReviewSnapshot("", "", base, head, "", nil, "", "", "", "")
	results := runReviewSpecialists(context.Background(), a, dir, snapshot, 2, time.Second, nil)
	if peak.Load() != 2 {
		t.Fatalf("peak concurrency = %d, want 2", peak.Load())
	}
	for i, result := range results {
		if result.Lens != reviewLensInstructions[i].name || result.Err != nil {
			t.Fatalf("result[%d] = %#v", i, result)
		}
	}
}

func TestSpecializedReviewBatch_DiscardsLensMutationAndPreservesOfficialWorktree(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	before, err := os.ReadFile(filepath.Join(dir, "feature.txt"))
	if err != nil {
		t.Fatal(err)
	}
	var checkouts sync.Map
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		if filepath.Clean(opts.CWD) == filepath.Clean(dir) {
			t.Error("lens received official worktree")
		}
		if _, loaded := checkouts.LoadOrStore(opts.CWD, true); loaded {
			t.Errorf("lenses shared checkout %q", opts.CWD)
		}
		original, err := os.ReadFile(filepath.Join(opts.CWD, "feature.txt"))
		if err != nil || string(original) != "feature code\n" {
			t.Errorf("lens did not receive original snapshot bytes: %q, %v", original, err)
		}
		if err := os.WriteFile(filepath.Join(opts.CWD, "feature.txt"), []byte("hostile"), 0o644); err != nil {
			t.Error(err)
		}
		return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":["feature.txt"]}`)}, nil
	}}
	snapshot := newReviewSnapshot("", "", base, head, "", nil, "", "", "", "")
	results := runReviewSpecialists(context.Background(), a, dir, snapshot, 6, time.Second, nil)
	for _, result := range results {
		if result.Err != nil {
			t.Fatal(result.Err)
		}
	}
	after, err := os.ReadFile(filepath.Join(dir, "feature.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("official worktree file changed")
	}
}

func TestSpecializedReviewBatch_OfficialStateFingerprintDetectsMutation(t *testing.T) {
	dir, _, _ := setupGitRepo(t)
	before, err := officialReviewState(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "intrusion.txt"), []byte("hostile"), 0o644); err != nil {
		t.Fatal(err)
	}
	after, err := officialReviewState(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if before == after {
		t.Fatal("official worktree mutation did not change fingerprint")
	}
}

func TestConsolidatorUsesSnapshotAndFreshSession(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("intent", "agent", "base", "head", "diff", []string{"a.go"}, "", "scope", "none", "")
	var calls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		calls.Add(1)
		if opts.Session != nil || opts.Purpose != "review-consolidator" || !strings.Contains(opts.Prompt, snapshot.ID) {
			t.Fatalf("consolidator invocation did not use fresh snapshot context: %#v", opts)
		}
		return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["a.go"]}`)}, nil
	}}
	results := []reviewLensResult{{Lens: "security", Output: reviewLensOutput{InspectedFiles: []string{"a.go"}}}}
	if _, err := consolidateReviewCandidates(context.Background(), a, dir, snapshot, results, time.Second); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("consolidator calls = %d, want 1", calls.Load())
	}
}

func TestConsolidatorRejectsFalseEvidence(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"a.go"}, "", "", "", "")
	candidate := reviewLensCandidate{Scenario: "impossible request", Impact: "data loss", Evidence: "no such code", File: ptrString("a.go"), Line: ptrInt(1), SuggestedAction: "fix", SuggestedSeverity: "error"}
	a := controlledReviewAgent{run: func(_ context.Context, _ agent.RunOpts) (*agent.Result, error) {
		return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["a.go"]}`)}, nil
	}}
	findings, err := consolidateReviewCandidates(context.Background(), a, dir, snapshot, []reviewLensResult{{Lens: "security", Output: reviewLensOutput{Candidates: []reviewLensCandidate{candidate}, InspectedFiles: []string{"a.go"}}}}, time.Second)
	if err != nil || len(findings.Items) != 0 {
		t.Fatalf("unsupported candidate survived: %#v, %v", findings, err)
	}
}

func TestConsolidatorDeduplicatesByContractScenarioAndRange(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.go"), []byte("line one\nline two\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"a.go"}, "", "", "", "")
	var calls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, _ agent.RunOpts) (*agent.Result, error) {
		calls.Add(1)
		return &agent.Result{Output: json.RawMessage(`{"findings":[{"severity":"error","file":"a.go","line":2,"description":"one semantic finding","action":"auto-fix","review_scope":"source"}],"inspected_files":["a.go"]}`)}, nil
	}}
	line := 2
	candidate := reviewLensCandidate{Scenario: "same failure", Impact: "broken contract", Evidence: "line 2 violates invariant", File: ptrString("a.go"), Line: &line, SuggestedAction: "fix", SuggestedSeverity: "warning"}
	findings, err := consolidateReviewCandidates(context.Background(), a, dir, snapshot, []reviewLensResult{{Lens: "security", Output: reviewLensOutput{Candidates: []reviewLensCandidate{candidate}, InspectedFiles: []string{"a.go"}}}, {Lens: "architecture", Output: reviewLensOutput{Candidates: []reviewLensCandidate{candidate}, InspectedFiles: []string{"a.go"}}}}, time.Second)
	if err != nil || len(findings.Items) != 1 || findings.Items[0].Severity != "error" || calls.Load() != 1 {
		t.Fatalf("semantic duplicate consolidation = %#v calls=%d err=%v", findings, calls.Load(), err)
	}
}

func TestConsolidatorValidatesAnchorsAndOutsideDiffClaims(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "changed.go"), []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"changed.go"}, "", "", "", "")
	findings := Findings{Items: []Finding{{File: "changed.go", Line: 2, Description: "valid"}, {File: "changed.go", Line: 9, Description: "past EOF"}, {File: "outside.go", Line: 1, Description: "no affected path proof"}, {File: "../escape.go", Line: 1, Description: "traversal"}}}
	filtered := validateConsolidatedAnchors(findings, snapshot, dir)
	if len(filtered.Items) != 1 || filtered.Items[0].Description != "valid" {
		t.Fatalf("invalid anchors survived: %#v", filtered.Items)
	}
}

func TestConsolidatorRetainsUnanchoredNonLocalFindings(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"a.go"}, "", "", "", "")
	findings := Findings{Items: []Finding{
		{Description: "architectural concern across modules", ReviewScope: "source"},
		{Description: "cross-cutting intent violation", ReviewScope: "pipeline-owned-delivery"},
		{Description: "external contract issue", ReviewScope: "external-delivery"},
	}}
	filtered := validateConsolidatedAnchors(findings, snapshot, dir)
	if len(filtered.Items) != 3 {
		t.Fatalf("unanchored non-local findings dropped: got %d, want 3", len(filtered.Items))
	}
}

func TestConsolidatorDropsUnanchoredFindingsWithInvalidScope(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"a.go"}, "", "", "", "")
	findings := Findings{Items: []Finding{
		{Description: "issue with invalid scope", ReviewScope: "invalid"},
		{Description: "issue with empty scope", ReviewScope: ""},
	}}
	filtered := validateConsolidatedAnchors(findings, snapshot, dir)
	if len(filtered.Items) != 0 {
		t.Fatalf("invalid-scope unanchored findings survived: got %d, want 0", len(filtered.Items))
	}
}

func TestConsolidatorDropsUnanchoredFindingsWithEmptyDescription(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"a.go"}, "", "", "", "")
	findings := Findings{Items: []Finding{
		{Description: "", ReviewScope: "source"},
		{Description: "  ", ReviewScope: "source"},
	}}
	filtered := validateConsolidatedAnchors(findings, snapshot, dir)
	if len(filtered.Items) != 0 {
		t.Fatalf("empty-description unanchored findings survived: got %d, want 0", len(filtered.Items))
	}
}

func TestConsolidatorDropsPartiallyAnchoredFindings(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"a.go"}, "", "", "", "")
	findings := Findings{Items: []Finding{
		{File: "a.go", Line: 0, Description: "file but no line", ReviewScope: "source"},
		{File: "", Line: 5, Description: "line but no file", ReviewScope: "source"},
	}}
	filtered := validateConsolidatedAnchors(findings, snapshot, dir)
	if len(filtered.Items) != 0 {
		t.Fatalf("partially-anchored findings survived: got %d, want 0", len(filtered.Items))
	}
}

func TestConsolidatorCoverageGapBoundedPass(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"missing.go"}, "", "", "", "")
	var calls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		call := calls.Add(1)
		if call == 1 {
			return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":[]}`)}, nil
		}
		if opts.Purpose != "review-coverage-complement" {
			t.Fatalf("second invocation purpose = %q", opts.Purpose)
		}
		return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["missing.go"]}`)}, nil
	}}
	results := []reviewLensResult{{Lens: "security", Output: reviewLensOutput{InspectedFiles: []string{}}}}
	if _, err := consolidateReviewCandidates(context.Background(), a, dir, snapshot, results, time.Second); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatalf("calls = %d, want one initial and one complement", calls.Load())
	}
}

func TestConsolidatorCoverageFailsAfterOneIncompleteComplement(t *testing.T) {
	dir := t.TempDir()
	snapshot := newReviewSnapshot("", "", "base", "head", "diff", []string{"missing.go"}, "", "", "", "")
	var calls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, _ agent.RunOpts) (*agent.Result, error) {
		calls.Add(1)
		return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":[]}`)}, nil
	}}
	results := []reviewLensResult{{Lens: "security", Output: reviewLensOutput{InspectedFiles: []string{}}}}
	_, err := consolidateReviewCandidates(context.Background(), a, dir, snapshot, results, time.Second)
	if err == nil || !strings.Contains(err.Error(), "coverage incomplete") || calls.Load() != 2 {
		t.Fatalf("incomplete coverage result err=%v calls=%d", err, calls.Load())
	}
}

func TestConsolidatorNormalizesNativeTaxonomy(t *testing.T) {
	findings := normalizeConsolidatedFindings(Findings{Items: []Finding{{Severity: "P0", Action: "invented", ReviewScope: "other"}}})
	item := findings.Items[0]
	if item.Severity != "warning" || item.Action != "ask-user" || item.ReviewScope != "source" {
		t.Fatalf("normalized finding = %#v", item)
	}
}

func TestSpecializedReviewOnlyConsolidatedFindingsReachGate(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var mono, consolidations atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		switch opts.Purpose {
		case "review":
			mono.Add(1)
			return &agent.Result{Output: json.RawMessage(`{"summary":"mono says clean","findings":[]}`)}, nil
		case "review-consolidator":
			consolidations.Add(1)
			return &agent.Result{Output: json.RawMessage(`{"findings":[{"severity":"error","file":"feature.txt","line":1,"description":"consolidated issue","action":"auto-fix","review_scope":"source"}],"inspected_files":[]}`)}, nil
		case "review-coverage-complement":
			return &agent.Result{Output: json.RawMessage(`{"findings":[{"severity":"error","file":"feature.txt","line":1,"description":"consolidated issue","action":"auto-fix","review_scope":"source"}],"inspected_files":["feature.txt"]}`)}, nil
		default:
			return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":[]}`)}, nil
		}
	}}
	sctx := newTestContextWithDBRecords(t, a, dir, base, head, config.Commands{})
	sctx.Config.Review.Topology.Topology = config.ReviewTopologySpecialized
	sctx.Config.Review.Topology.Enforcement = config.ReviewEnforcementBlocking
	sctx.Config.Review.Topology.MaxParallel = 6
	sctx.Config.Review.Topology.Timeout = time.Second
	outcome, err := (&ReviewStep{}).Execute(sctx)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := types.ParseFindingsJSON(outcome.Findings)
	if err != nil || len(parsed.Items) != 1 || parsed.Items[0].Description != "consolidated issue" || !outcome.NeedsApproval || mono.Load() != 1 || consolidations.Load() != 1 {
		t.Fatalf("gate used non-consolidated result: findings=%#v outcome=%#v mono=%d consolidator=%d err=%v", parsed, outcome, mono.Load(), consolidations.Load(), err)
	}
}

func TestReviewStep_RereviewRunsFreshFullSpecializedBatch(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var fixer, reviewer, lenses, consolidator atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		if opts.Session != nil {
			t.Errorf("review invocation reused a session: %s", opts.Purpose)
		}
		switch opts.Purpose {
		case "review-fix":
			fixer.Add(1)
			if err := os.WriteFile(filepath.Join(dir, "fix-round.txt"), []byte("fixed"), 0o644); err != nil {
				return nil, err
			}
			return &agent.Result{Output: json.RawMessage(`{"summary":"apply fix"}`)}, nil
		case "review":
			reviewer.Add(1)
			return &agent.Result{Output: json.RawMessage(`{"findings":[],"summary":"mono"}`)}, nil
		case "review-consolidator":
			consolidator.Add(1)
			return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["feature.txt","fix-round.txt"]}`)}, nil
		case "review-coverage-complement":
			return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":["feature.txt","fix-round.txt"]}`)}, nil
		default:
			if strings.HasPrefix(opts.Purpose, "review-lens:") {
				lenses.Add(1)
				return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":["feature.txt","fix-round.txt"]}`)}, nil
			}
			return nil, fmt.Errorf("unexpected agent purpose %s", opts.Purpose)
		}
	}}
	sctx := newTestContextWithDBRecords(t, a, dir, base, head, config.Commands{})
	sctx.Fixing = true
	sctx.PreviousFindings = `{"findings":[{"id":"previous","severity":"warning","description":"prior claim"}]}`
	sctx.Config.Review.Topology.Topology = config.ReviewTopologySpecialized
	sctx.Config.Review.Topology.Enforcement = config.ReviewEnforcementBlocking
	sctx.Config.Review.Topology.MaxParallel = 6
	sctx.Config.Review.Topology.Timeout = time.Second
	if _, err := (&ReviewStep{}).Execute(sctx); err != nil {
		t.Fatal(err)
	}
	if fixer.Load() != 1 || reviewer.Load() != 1 || lenses.Load() != int32(len(reviewLensInstructions)) || consolidator.Load() != 1 {
		t.Fatalf("rereview counts fixer=%d reviewer=%d lenses=%d consolidator=%d", fixer.Load(), reviewer.Load(), lenses.Load(), consolidator.Load())
	}
}

func ptrString(value string) *string { return &value }
func ptrInt(value int) *int          { return &value }

func TestSpecializedReviewBatch_ValidatesStructuredCandidates(t *testing.T) {
	line := 7
	valid := reviewLensOutput{Candidates: []reviewLensCandidate{{Scenario: "request with invalid token", Impact: "unauthorized access", Evidence: "handler accepts token", Line: &line, SuggestedAction: "reject invalid token", SuggestedSeverity: "error"}}, InspectedFiles: []string{"handler.go"}}
	if err := validateReviewLensOutput(valid); err != nil {
		t.Fatalf("valid candidate rejected: %v", err)
	}
	valid.Candidates[0].Scenario = " "
	if err := validateReviewLensOutput(valid); err == nil {
		t.Fatal("candidate without scenario accepted")
	}
}

func TestReviewStep_SpecializedSingleTopologyUsesLegacyReviewer(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var calls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, _ agent.RunOpts) (*agent.Result, error) {
		calls.Add(1)
		return &agent.Result{Output: json.RawMessage(`{"summary":"clean","findings":[]}`)}, nil
	}}
	sctx := newTestContext(t, a, dir, base, head, config.Commands{})
	sctx.Config.Review.Topology.Topology = config.ReviewTopologySingle
	if _, err := (&ReviewStep{}).Execute(sctx); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("single topology invocations = %d, want only legacy reviewer", calls.Load())
	}
}

func TestReviewStep_SpecializedObserveFailureKeepsLegacyReview(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var calls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		calls.Add(1)
		if opts.Purpose == "review" {
			return &agent.Result{Output: json.RawMessage(`{"summary":"authoritative clean","findings":[]}`)}, nil
		}
		return nil, fmt.Errorf("controlled lens failure")
	}}
	sctx := newTestContextWithDBRecords(t, a, dir, base, head, config.Commands{})
	sctx.Config.Review.Topology.Topology = config.ReviewTopologySpecialized
	sctx.Config.Review.Topology.Enforcement = config.ReviewEnforcementObserve
	sctx.Config.Review.Topology.MaxParallel = 2
	sctx.Config.Review.Topology.Timeout = time.Second
	outcome, err := (&ReviewStep{}).Execute(sctx)
	if err != nil || outcome == nil {
		t.Fatalf("observe failure affected authoritative reviewer: outcome=%#v err=%v", outcome, err)
	}
	if calls.Load() != 7 {
		t.Fatalf("agent calls = %d, want reviewer plus six lenses", calls.Load())
	}
}

func TestReviewStep_SpecializedBatchRejectsBlockingFailure(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var calls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		calls.Add(1)
		if opts.Purpose == "review" {
			return &agent.Result{Output: json.RawMessage(`{"summary":"clean","findings":[]}`)}, nil
		}
		return nil, fmt.Errorf("controlled lens failure")
	}}
	sctx := newTestContextWithDBRecords(t, a, dir, base, head, config.Commands{})
	sctx.Config.Review.Topology.Topology = config.ReviewTopologySpecialized
	sctx.Config.Review.Topology.Enforcement = config.ReviewEnforcementBlocking
	sctx.Config.Review.Topology.MaxParallel = 2
	sctx.Config.Review.Topology.Timeout = time.Second
	if _, err := (&ReviewStep{}).Execute(sctx); err == nil || !strings.Contains(err.Error(), "specialized review incomplete") {
		t.Fatalf("blocking batch result error = %v", err)
	}
	if calls.Load() != 7 {
		t.Fatalf("agent calls = %d, want reviewer plus six lenses", calls.Load())
	}
}

func TestReviewStep_SpecializedBatchDetectsOfficialWorktreeMutation(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var sctxCalls atomic.Int32
	a := controlledReviewAgent{run: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		if opts.Purpose == "review" {
			return &agent.Result{Output: json.RawMessage(`{"summary":"clean","findings":[]}`)}, nil
		}
		if sctxCalls.Add(1) == 1 {
			if err := os.WriteFile(filepath.Join(dir, "intrusion.txt"), []byte("hostile"), 0o600); err != nil {
				return nil, err
			}
		}
		return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":[]}`)}, nil
	}}
	sctx := newTestContextWithDBRecords(t, a, dir, base, head, config.Commands{})
	sctx.Config.Review.Topology.Topology = config.ReviewTopologySpecialized
	sctx.Config.Review.Topology.MaxParallel = 2
	sctx.Config.Review.Topology.Timeout = time.Second
	if _, err := (&ReviewStep{}).Execute(sctx); err == nil || !strings.Contains(err.Error(), "official worktree state changed") {
		t.Fatalf("official mutation result = %v", err)
	}
}

func TestReviewLensHelperSubprocess(t *testing.T) {
	if os.Getenv("DRILL_REVIEW_LENS_HELPER") == "1" {
		for {
			time.Sleep(time.Second)
		}
	}
}

func TestSpecializedReviewBatch_CancellationReapsAgentProcess(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	var pid atomic.Int64
	var reaped atomic.Bool
	a := controlledReviewAgent{run: func(ctx context.Context, _ agent.RunOpts) (*agent.Result, error) {
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestReviewLensHelperSubprocess$")
		cmd.Env = append(os.Environ(), "DRILL_REVIEW_LENS_HELPER=1")
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		pid.Store(int64(cmd.Process.Pid))
		err := cmd.Wait()
		reaped.Store(cmd.ProcessState != nil)
		return nil, err
	}}
	snapshot := newReviewSnapshot("", "", base, head, "", nil, "", "", "", "")
	results := runReviewSpecialists(context.Background(), a, dir, snapshot, 1, 100*time.Millisecond, nil)
	if results[0].Err == nil || pid.Load() == 0 || results[0].Duration <= 0 || !reaped.Load() {
		t.Fatalf("child cleanup result=%#v pid=%d reaped=%v", results[0], pid.Load(), reaped.Load())
	}
}

func TestSpecializedReviewBatch_CancellationAndTimeoutReleaseResources(t *testing.T) {
	dir, base, head := setupGitRepo(t)
	tempRoot := t.TempDir()
	t.Setenv("TMPDIR", tempRoot)
	t.Setenv("TMP", tempRoot)
	t.Setenv("TEMP", tempRoot)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	a := controlledReviewAgent{run: func(ctx context.Context, _ agent.RunOpts) (*agent.Result, error) { <-ctx.Done(); return nil, ctx.Err() }}
	snapshot := newReviewSnapshot("", "", base, head, "", nil, "", "", "", "")
	results := runReviewSpecialists(ctx, a, dir, snapshot, 2, time.Second, nil)
	for _, result := range results {
		if result.Err == nil {
			t.Fatalf("cancelled lens reported success: %#v", result)
		}
	}
	var active atomic.Int32
	timed := controlledReviewAgent{run: func(ctx context.Context, _ agent.RunOpts) (*agent.Result, error) {
		active.Add(1)
		defer active.Add(-1)
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	before, _ := filepath.Glob(filepath.Join(tempRoot, "drill-review-lens-*"))
	results = runReviewSpecialists(context.Background(), timed, dir, snapshot, 1, time.Millisecond, nil)
	for _, result := range results {
		if result.Err == nil || result.Duration <= 0 {
			t.Fatalf("timeout lacks error/duration: %#v", result)
		}
	}
	if active.Load() != 0 {
		t.Fatalf("lens goroutine remained active: %d", active.Load())
	}
	after, _ := filepath.Glob(filepath.Join(tempRoot, "drill-review-lens-*"))
	if len(after) != len(before) {
		t.Fatalf("temporary lens directories leaked: before=%d after=%d", len(before), len(after))
	}
}
