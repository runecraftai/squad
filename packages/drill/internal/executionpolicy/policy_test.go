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

func TestFixtureAccessIsGatedByBuildNotExecutableName(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	root := t.TempDir()
	repo := createExecutionCopy(t, root)
	fixture := filepath.Join(root, "synthetic-fixture.yaml")
	if err := os.WriteFile(fixture, []byte("scenario: synthetic\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	policy, err := New(repo)
	if err != nil {
		t.Skipf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()
	for _, name := range []string{"fakeagent", "synthetic-agent"} {
		fake := filepath.Join(root, name)
		if err := os.WriteFile(fake, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(fake)
		cmd.Dir = repo
		cmd.Env = []string{"FAKEAGENT_FIXTURE=" + fixture}
		if err := policy.Command(cmd); err != nil {
			t.Fatal(err)
		}
		granted := strings.Contains(strings.Join(cmd.Args, "\x00"), fixture)
		if granted != e2eBuild {
			t.Fatalf("binary %q fixture access = %t, want %t (e2e build = %t): args=%q", name, granted, e2eBuild, e2eBuild, cmd.Args)
		}
	}
}

func TestEachCommandGetsAFreshCredentialHome(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	root := t.TempDir()
	repo := createExecutionCopy(t, root)
	home := filepath.Join(root, "host-home")
	credential := filepath.Join(home, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credential), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credential, []byte(`{"token":"host-token"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	claude := filepath.Join(root, "claude")
	if err := os.WriteFile(claude, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	policy, err := New(repo)
	if err != nil {
		t.Skipf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()
	launchHomes := make([]string, 0, 2)
	for i := 0; i < 2; i++ {
		cmd := exec.Command(claude)
		cmd.Dir = repo
		if err := policy.Command(cmd); err != nil {
			t.Fatal(err)
		}
		launchHome := boundLaunchHome(t, cmd.Args)
		launchHomes = append(launchHomes, launchHome)
		if i == 0 {
			marker := filepath.Join(launchHome, "previous-launch-secret")
			if err := os.WriteFile(marker, []byte("previous launch token"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	if launchHomes[0] == launchHomes[1] {
		t.Fatalf("launch homes = %q, want distinct homes", launchHomes)
	}
	if _, err := os.Stat(filepath.Join(launchHomes[1], "previous-launch-secret")); !os.IsNotExist(err) {
		t.Fatalf("previous launch secret is reachable from next launch home: err=%v", err)
	}
	for i, launchHome := range launchHomes {
		if data, err := os.ReadFile(filepath.Join(launchHome, ".claude", ".credentials.json")); err != nil || !strings.Contains(string(data), "host-token") {
			t.Fatalf("launch home %d lacks its provider credential: data=%q err=%v", i, data, err)
		}
	}
}

func boundLaunchHome(t *testing.T, args []string) string {
	t.Helper()
	for i := 0; i+2 < len(args); i++ {
		if args[i] == "--bind" && args[i+2] == "/run/drill-execution/home" {
			return args[i+1]
		}
	}
	t.Fatal("sandbox arguments do not bind a launch home")
	return ""
}

func createExecutionCopy(t *testing.T, root string) string {
	t.Helper()
	source := filepath.Join(root, "source")
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
	repo := filepath.Join(root, "repo")
	git(t, source, "worktree", "add", "--detach", repo, "HEAD")
	return repo
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
