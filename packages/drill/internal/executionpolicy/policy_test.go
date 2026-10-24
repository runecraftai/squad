package executionpolicy

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestRepositoryCommandCannotReadOutsideExecutionCopy(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("drill-repository-execution-v1 requires Linux and Bubblewrap; unsupported hosts must refuse execution")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable in this test environment; production policy acknowledgement must fail")
	}
	parent := t.TempDir()
	source := filepath.Join(parent, "source")
	if err := os.Mkdir(source, 0o700); err != nil {
		t.Fatal(err)
	}
	git(t, source, "init", "-q")
	git(t, source, "config", "user.name", "Policy Test")
	git(t, source, "config", "user.email", "policy@example.invalid")
	if err := os.WriteFile(filepath.Join(source, "tracked.txt"), []byte("tracked\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "fixture")
	repo := filepath.Join(parent, "execution-copy")
	git(t, source, "worktree", "add", "--detach", repo, "HEAD")

	outside := filepath.Join(parent, "outside-canary")
	if err := os.WriteFile(outside, []byte("outside-secret-marker"), 0o600); err != nil {
		t.Fatal(err)
	}
	gate := filepath.Join(parent, "shared-gate")
	if err := os.Mkdir(gate, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gate, "private-ref"), []byte("gate-only-marker"), 0o600); err != nil {
		t.Fatal(err)
	}
	socketDir, err := os.MkdirTemp("/tmp", "drill-sock-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(socketDir)
	socket := filepath.Join(socketDir, "daemon.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	policy, err := New(repo)
	if err != nil {
		t.Fatalf("mandatory policy setup: %v", err)
	}
	defer policy.Close()
	for _, path := range []string{outside, filepath.Join(gate, "private-ref"), socket} {
		out, code, err := policy.RunCommand(context.Background(), "cat "+shellQuote(path), nil)
		if err != nil {
			t.Fatalf("confined read %q: %v", path, err)
		}
		if code == 0 || strings.Contains(string(out), "outside-secret-marker") || strings.Contains(string(out), "gate-only-marker") {
			t.Fatalf("confined command read outside execution copy %q: %q", path, out)
		}
	}
	if _, code, err := policy.RunCommand(context.Background(), "printf compromised > "+shellQuote(outside), nil); err != nil || code != 0 {
		t.Fatalf("confined write should stay in the private sandbox: code=%d err=%v", code, err)
	}
	if data, err := os.ReadFile(outside); err != nil || string(data) != "outside-secret-marker" {
		t.Fatalf("confined command modified host file: data=%q err=%v", data, err)
	}
	out, code, err := policy.RunCommand(context.Background(), "git log -1 --format=%s", nil)
	if err != nil || code != 0 || strings.TrimSpace(string(out)) != "fixture" {
		t.Fatalf("private Git history unavailable: output=%q code=%d err=%v", out, code, err)
	}
	original := git(t, source, "rev-parse", "HEAD")
	out, code, err = policy.RunCommand(context.Background(), "git config user.name 'Sandbox Agent' && git config user.email sandbox@example.invalid && printf changed > confined.txt && git add confined.txt && git commit -m sandbox-commit", nil)
	if err != nil || code != 0 {
		t.Fatalf("confined git commit failed: output=%q code=%d err=%v", out, code, err)
	}
	if got := git(t, repo, "rev-parse", "HEAD"); got == original {
		t.Fatal("authorized private commit was not imported into the execution copy")
	}
	if got := git(t, source, "rev-parse", "HEAD"); got != original {
		t.Fatalf("private commit changed source repository ref: got %s, want %s", got, original)
	}
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	} else {
		return strings.TrimSpace(string(output))
	}
	return ""
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
