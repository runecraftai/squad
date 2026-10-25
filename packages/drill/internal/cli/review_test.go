package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/agent"
	"github.com/runecraftai/squad/packages/drill/internal/config"
	"github.com/runecraftai/squad/packages/drill/internal/executionpolicy"
)

type standaloneReviewTestAgent struct {
	fail    bool
	block   bool
	started chan struct{}
	once    *sync.Once
}

func (a standaloneReviewTestAgent) Name() string { return "test" }
func (a standaloneReviewTestAgent) Close() error { return nil }
func (a standaloneReviewTestAgent) Run(ctx context.Context, opts agent.RunOpts) (*agent.Result, error) {
	if a.fail {
		return nil, errors.New("test agent failure")
	}
	if a.block {
		a.once.Do(func() { close(a.started) })
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if opts.Purpose == "review-consolidator" {
		return &agent.Result{Output: json.RawMessage(`{"findings":[{"severity":"low","description":"Example finding","action":"Inspect","review_scope":"requested"}],"inspected_files":["file.txt"]}`)}, nil
	}
	return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":["file.txt"]}`)}, nil
}

func reviewGitOutput(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func prepareStandaloneReviewRepo(t *testing.T) (root, base, head string) {
	t.Helper()
	root = setupTestRepo(t)
	if resolved, err := filepath.EvalSymlinks(root); err == nil {
		root = resolved
	}
	base = reviewGitOutput(t, root, "rev-parse", "HEAD")
	if err := os.WriteFile(filepath.Join(root, "file.txt"), []byte("review me\n"), 0600); err != nil {
		t.Fatal(err)
	}
	run(t, root, "git", "add", "file.txt")
	run(t, root, "git", "commit", "-m", "add review fixture")
	head = reviewGitOutput(t, root, "rev-parse", "HEAD")
	return root, base, head
}

func executeStandaloneReviewCmd(args ...string) (string, error) {
	return executeStandaloneReviewCmdContext(context.Background(), args...)
}

func executeStandaloneReviewCmdContext(ctx context.Context, args ...string) (string, error) {
	cmd := newRootCmd()
	buf := new(bytes.Buffer)
	cmd.SetOut(buf)
	cmd.SetErr(io.Discard)
	cmd.SetArgs(args)
	cmd.SetContext(ctx)
	err := cmd.Execute()
	return buf.String(), err
}

func installStandaloneReviewTestAgent(t *testing.T, fail bool) {
	t.Helper()
	previous := standaloneReviewAgentFactory
	standaloneReviewAgentFactory = func(context.Context, *config.Config) (agent.Agent, error) {
		return standaloneReviewTestAgent{fail: fail}, nil
	}
	t.Cleanup(func() { standaloneReviewAgentFactory = previous })
}

func TestReviewCommandHelpDocumentsLocalRange(t *testing.T) {
	out, err := executeCmd("review", "--help")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"--base", "--head", "--intent", "--format", "specialized read-only review engine"} {
		if !strings.Contains(out, want) {
			t.Errorf("help missing %q: %s", want, out)
		}
	}
}

func TestReviewCommandRejectsUnknownAndIdenticalRefs(t *testing.T) {
	root, base, _ := prepareStandaloneReviewRepo(t)
	installStandaloneReviewTestAgent(t, false)
	if out, err := executeStandaloneReviewCmd("review", "--base", "missing-base", "--head", "HEAD"); err == nil || !strings.Contains(err.Error(), "resolve base ref") {
		t.Fatalf("unknown ref: out=%s err=%v", out, err)
	}
	if out, err := executeStandaloneReviewCmd("review", "--base", base, "--head", base); err == nil || !strings.Contains(err.Error(), "same commit") {
		t.Fatalf("identical refs: out=%s err=%v", out, err)
	}
	if got := reviewGitOutput(t, root, "status", "--porcelain"); got != "" {
		t.Fatalf("invalid refs changed checkout: %q", got)
	}
}

func TestReviewCommandRequiresLocalRangeAndValidFormat(t *testing.T) {
	setupTestRepo(t)
	if out, err := executeCmd("review"); err == nil || !strings.Contains(err.Error(), "--base and --head are required") {
		t.Fatalf("missing range: out=%s err=%v", out, err)
	}
	if out, err := executeCmd("review", "--base", "HEAD", "--head", "HEAD", "--format", "yaml"); err == nil || !strings.Contains(err.Error(), "--format must be text or json") {
		t.Fatalf("invalid format: out=%s err=%v", out, err)
	}
}

func TestReviewCommandReportsRepositoryAndReviewedSHAs(t *testing.T) {
	root, base, head := prepareStandaloneReviewRepo(t)
	installStandaloneReviewTestAgent(t, false)
	out, err := executeStandaloneReviewCmd("review", "--base", base, "--head", head, "--format", "json")
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Repository string `json:"repository"`
		BaseSHA    string `json:"base_sha"`
		HeadSHA    string `json:"head_sha"`
		Findings   struct {
			Items []struct {
				Description string `json:"description"`
			} `json:"findings"`
		} `json:"findings"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("JSON output: %v: %s", err, out)
	}
	if got.Repository != root || got.BaseSHA != base || got.HeadSHA != head {
		t.Fatalf("result identity = %+v", got)
	}
	if len(got.Findings.Items) != 1 || got.Findings.Items[0].Description != "Example finding" {
		t.Fatalf("native findings missing: %+v", got.Findings)
	}
}

func TestStandaloneReviewLensesCannotReadOutsideExecutionCopy(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("drill-repository-execution-v1 requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	previousPolicyFactory := newReviewExecutionPolicy
	newReviewExecutionPolicy = func(workDir string) (reviewExecutionPolicy, error) {
		return executionpolicy.New(workDir)
	}
	t.Cleanup(func() { newReviewExecutionPolicy = previousPolicyFactory })
	root, base, head := prepareStandaloneReviewRepo(t)
	outsideDir, err := os.MkdirTemp("/var/tmp", "drill-review-outside-")
	if err != nil {
		t.Skipf("cannot create outside canary: %v", err)
	}
	defer os.RemoveAll(outsideDir)
	outside := filepath.Join(outsideDir, "synthetic-secret")
	if err := os.WriteFile(outside, []byte("review-lens-outside-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	previous := standaloneReviewAgentFactory
	testAgent := &standaloneReviewPolicyTestAgent{outside: outside}
	standaloneReviewAgentFactory = func(context.Context, *config.Config) (agent.Agent, error) {
		return testAgent, nil
	}
	t.Cleanup(func() { standaloneReviewAgentFactory = previous })
	out, err := executeStandaloneReviewCmd("review", "--base", base, "--head", head, "--format", "json")
	if err != nil {
		t.Fatalf("review command: %v", err)
	}
	if len(testAgent.inside) == 0 || !strings.Contains(testAgent.inside[0], "review-lens-inside-marker") {
		t.Fatalf("review lens never read its own execution copy: %q", testAgent.inside)
	}
	if len(testAgent.escaped) != 0 {
		t.Fatalf("review lens read a synthetic file outside its execution copy: %q", testAgent.escaped)
	}
	if strings.Contains(out, "review-lens-outside-secret") {
		t.Fatalf("review lens read a synthetic file outside its execution copy: %s", out)
	}
	if got := reviewGitOutput(t, root, "status", "--porcelain"); got != "" {
		t.Fatalf("review changed source checkout: %q", got)
	}
}

type standaloneReviewPolicyTestAgent struct {
	outside string
	mu      sync.Mutex
	inside  []string
	escaped []string
}

func (a *standaloneReviewPolicyTestAgent) Name() string { return "test" }
func (a *standaloneReviewPolicyTestAgent) Close() error { return nil }
func (a *standaloneReviewPolicyTestAgent) Run(ctx context.Context, opts agent.RunOpts) (*agent.Result, error) {
	if opts.ExecutionPolicy == nil {
		return nil, errors.New("review lens has no execution policy")
	}
	insideFile := filepath.Join(opts.CWD, "lens-inside-canary")
	if err := os.WriteFile(insideFile, []byte("review-lens-inside-marker"), 0o600); err != nil {
		return nil, err
	}
	insideCmd := exec.CommandContext(ctx, "cat", insideFile)
	insideCmd.Dir = opts.CWD
	if err := opts.ExecutionPolicy.Command(insideCmd); err != nil {
		return nil, err
	}
	inside, err := insideCmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("review lens could not read its own execution copy: %w: %s", err, inside)
	}
	a.mu.Lock()
	a.inside = append(a.inside, string(inside))
	a.mu.Unlock()
	cmd := exec.CommandContext(ctx, "cat", a.outside)
	cmd.Dir = opts.CWD
	if err := opts.ExecutionPolicy.Command(cmd); err != nil {
		return nil, err
	}
	output, err := cmd.CombinedOutput()
	if err == nil || strings.Contains(string(output), "review-lens-outside-secret") {
		a.mu.Lock()
		a.escaped = append(a.escaped, string(output))
		a.mu.Unlock()
	}
	if opts.Purpose == "review-consolidator" {
		return &agent.Result{Output: json.RawMessage(`{"findings":[],"inspected_files":[],"risk_level":"low","risk_rationale":"clean","risk_scope":"source-or-external"}`)}, nil
	}
	return &agent.Result{Output: json.RawMessage(`{"candidates":[],"inspected_files":["file.txt"]}`)}, nil
}

func TestReviewCommandEmitsNativeAndHumanFindings(t *testing.T) {
	_, base, head := prepareStandaloneReviewRepo(t)
	installStandaloneReviewTestAgent(t, false)
	out, err := executeStandaloneReviewCmd("review", "--base", base, "--head", head)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Repository:", "Base: " + base, "Head: " + head, "Example finding", "Findings JSON:"} {
		if !strings.Contains(out, want) {
			t.Errorf("text output missing %q: %s", want, out)
		}
	}
}

func TestReviewCommandPreservesCheckoutRefsAndRemote(t *testing.T) {
	root, base, head := prepareStandaloneReviewRepo(t)
	installStandaloneReviewTestAgent(t, false)
	statusBefore := reviewGitOutput(t, root, "status", "--porcelain")
	refsBefore := reviewGitOutput(t, root, "show-ref")
	remoteBefore := reviewGitOutput(t, root, "ls-remote", "origin")
	if _, err := executeStandaloneReviewCmd("review", "--base", base, "--head", head, "--format", "json"); err != nil {
		t.Fatal(err)
	}
	if got := reviewGitOutput(t, root, "status", "--porcelain"); got != statusBefore {
		t.Fatalf("worktree changed: %q -> %q", statusBefore, got)
	}
	if got := reviewGitOutput(t, root, "show-ref"); got != refsBefore {
		t.Fatalf("refs changed: %q -> %q", refsBefore, got)
	}
	if got := reviewGitOutput(t, root, "ls-remote", "origin"); got != remoteBefore {
		t.Fatalf("remote changed: %q -> %q", remoteBefore, got)
	}
	if got := reviewGitOutput(t, root, "worktree", "list", "--porcelain"); strings.Count(got, "worktree ") != 1 {
		t.Fatalf("temporary checkout leaked: %s", got)
	}
}

func TestStandaloneReviewCancellationCleansDisposableCheckout(t *testing.T) {
	root, base, head := prepareStandaloneReviewRepo(t)
	statusBefore := reviewGitOutput(t, root, "status", "--porcelain")
	refsBefore := reviewGitOutput(t, root, "show-ref")
	remoteBefore := reviewGitOutput(t, root, "ls-remote", "origin")
	started := make(chan struct{})
	previous := standaloneReviewAgentFactory
	standaloneReviewAgentFactory = func(context.Context, *config.Config) (agent.Agent, error) {
		return standaloneReviewTestAgent{block: true, started: started, once: &sync.Once{}}, nil
	}
	t.Cleanup(func() { standaloneReviewAgentFactory = previous })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := executeStandaloneReviewCmdContext(ctx, "review", "--base", base, "--head", head)
		result <- err
	}()
	<-started
	cancel()
	if err := <-result; err == nil {
		t.Fatal("expected cancellation")
	}
	if got := reviewGitOutput(t, root, "worktree", "list", "--porcelain"); strings.Count(got, "worktree ") != 1 {
		t.Fatalf("temporary checkout leaked after cancellation: %s", got)
	}
	assertStandaloneReviewRepoUnchanged(t, root, statusBefore, refsBefore, remoteBefore)
}

func assertStandaloneReviewRepoUnchanged(t *testing.T, root, status, refs, remote string) {
	t.Helper()
	if got := reviewGitOutput(t, root, "status", "--porcelain"); got != status {
		t.Fatalf("worktree changed: %q -> %q", status, got)
	}
	if got := reviewGitOutput(t, root, "show-ref"); got != refs {
		t.Fatalf("refs changed: %q -> %q", refs, got)
	}
	if got := reviewGitOutput(t, root, "ls-remote", "origin"); got != remote {
		t.Fatalf("remote changed: %q -> %q", remote, got)
	}
}

func TestStandaloneReviewFailureCleansDisposableCheckout(t *testing.T) {
	root, base, head := prepareStandaloneReviewRepo(t)
	statusBefore := reviewGitOutput(t, root, "status", "--porcelain")
	refsBefore := reviewGitOutput(t, root, "show-ref")
	remoteBefore := reviewGitOutput(t, root, "ls-remote", "origin")
	installStandaloneReviewTestAgent(t, true)
	if _, err := executeStandaloneReviewCmd("review", "--base", base, "--head", head); err == nil {
		t.Fatal("expected review failure")
	}
	if got := reviewGitOutput(t, root, "worktree", "list", "--porcelain"); strings.Count(got, "worktree ") != 1 {
		t.Fatalf("temporary checkout leaked after failure: %s", got)
	}
	assertStandaloneReviewRepoUnchanged(t, root, statusBefore, refsBefore, remoteBefore)
}
