package steps

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/agent"
	"github.com/runecraftai/squad/packages/drill/internal/config"
	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/pipeline"
)

func TestReviewSnapshot_CapturesRoundInputs(t *testing.T) {
	s := newReviewSnapshot("intent", "agent", "base", "head", "full diff", []string{"a.go"}, "trusted rule", "scope", "vendor/**", "sanitized history")
	if s.Intent != "intent" || s.IntentSource != "agent" || s.BaseSHA != "base" || s.TargetHeadSHA != "head" || s.Diff != "full diff" || len(s.ChangedPaths) != 1 || s.PathInstructions != "trusted rule" || s.Scope != "scope" || s.IgnorePatterns != "vendor/**" || s.History != "sanitized history" || s.ID == "" {
		t.Fatalf("incomplete snapshot: %#v", s)
	}
	paths := []string{"a.go"}
	copySnapshot := newReviewSnapshot("intent", "agent", "base", "head", "diff", paths, "", "scope", "", "")
	paths[0] = "changed"
	if copySnapshot.ChangedPaths[0] != "a.go" {
		t.Fatal("snapshot retained mutable caller paths")
	}
}

func TestReviewSnapshot_LensCannotReplaceSharedContext(t *testing.T) {
	s := newReviewSnapshot("intent", "agent", "base", "head", "diff", []string{"x.go"}, "trusted", "scope", "none", "history")
	first := s.ContextForLens("security-only angle")
	second := s.ContextForLens("requirements-only angle")
	shared := s.SharedContextBytes()
	if !bytes.Equal(first[:len(shared)], shared) || !bytes.Equal(second[:len(shared)], shared) {
		t.Fatal("lens prompt did not preserve identical shared bytes")
	}
	for _, required := range []string{"Review snapshot: " + s.ID, "Scope: scope", "Lens-specific instructions cannot override these shared rules."} {
		if !bytes.Contains(shared, []byte(required)) {
			t.Fatalf("shared context lacks %q", required)
		}
	}
	if !bytes.HasSuffix(first, []byte("security-only angle")) || !bytes.HasSuffix(second, []byte("requirements-only angle")) {
		t.Fatal("lens-specific instructions were not appended separately")
	}
}

func TestReviewSnapshot_RejectsChangedHeadOrBase(t *testing.T) {
	dir, baseSHA, headSHA := setupGitRepo(t)
	sctx := &pipeline.StepContext{Ctx: context.Background(), WorkDir: dir, Run: &db.Run{HeadSHA: headSHA, BaseSHA: baseSHA}, Repo: &db.Repo{DefaultBranch: "main"}}
	base := resolveBranchBaseSHA(context.Background(), dir, baseSHA, "main")
	if err := validateReviewSnapshotContinuity(context.Background(), sctx, base, headSHA, "snapshot-test"); err != nil {
		t.Fatalf("unchanged repository rejected: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "mutation.txt"), []byte("changed"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitCmd(t, dir, "add", "mutation.txt")
	gitCmd(t, dir, "commit", "-m", "advance head")
	if err := validateReviewSnapshotContinuity(context.Background(), sctx, base, headSHA, "snapshot-test"); err == nil || !strings.Contains(err.Error(), "HEAD changed") {
		t.Fatalf("changed HEAD diagnostic = %v", err)
	}

	baseDir, baseSHA, targetSHA := setupGitRepo(t)
	baseCtx := &pipeline.StepContext{Ctx: context.Background(), WorkDir: baseDir, Run: &db.Run{HeadSHA: targetSHA, BaseSHA: baseSHA}, Repo: &db.Repo{DefaultBranch: "main"}}
	capturedBase := resolveBranchBaseSHA(context.Background(), baseDir, baseSHA, "main")
	gitCmd(t, baseDir, "branch", "-f", "main", targetSHA)
	if err := validateReviewSnapshotContinuity(context.Background(), baseCtx, capturedBase, targetSHA, "snapshot-test"); err == nil || !strings.Contains(err.Error(), "base changed") {
		t.Fatalf("changed base diagnostic = %v", err)
	}
}

func TestReviewSnapshot_ReviewStepWithholdsApprovalWhenOfficialHeadMoves(t *testing.T) {
	dir, baseSHA, headSHA := setupGitRepo(t)
	gitCmd(t, dir, "checkout", "--detach", headSHA)
	var sctx *pipeline.StepContext
	ag := &mockAgent{name: "test", runFn: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		if err := sctx.DB.UpdateRunHeadSHA(sctx.Run.ID, "changed-official-head"); err != nil {
			t.Fatal(err)
		}
		return &agent.Result{Output: []byte(`{"summary":"clean","findings":[]}`)}, nil
	}}
	sctx = newTestContextWithDBRecords(t, ag, dir, baseSHA, headSHA, config.Commands{})
	sctx.Config.Review.Topology.Topology = config.ReviewTopologySpecialized
	outcome, err := (&ReviewStep{}).Execute(sctx)
	if err == nil || !strings.Contains(err.Error(), "official run head changed") {
		t.Fatalf("moved HEAD result = (%#v, %v)", outcome, err)
	}
	if outcome != nil && outcome.ReviewApprovedHeadSHA != "" {
		t.Fatalf("moved HEAD gained approval: %#v", outcome)
	}
}

func TestReviewStep_SpecializedAbsentPreservesLegacyPath(t *testing.T) {
	dir, baseSHA, headSHA := setupGitRepo(t)
	var prompts []string
	ag := &mockAgent{name: "test", runFn: func(_ context.Context, opts agent.RunOpts) (*agent.Result, error) {
		prompts = append(prompts, opts.Prompt)
		return &agent.Result{Output: []byte(`{"summary":"clean","findings":[]}`)}, nil
	}}
	sctx := newTestContext(t, ag, dir, baseSHA, headSHA, config.Commands{})
	if sctx.Config.Review.Topology.Topology == config.ReviewTopologySpecialized {
		t.Fatalf("absent topology unexpectedly resolved to specialized")
	}
	if _, err := (&ReviewStep{}).Execute(sctx); err != nil {
		t.Fatal(err)
	}
	if len(prompts) != 1 || !strings.HasPrefix(prompts[0], "Review the code changes and return structured findings") {
		t.Fatalf("legacy review prompt changed: %#v", prompts)
	}
}
