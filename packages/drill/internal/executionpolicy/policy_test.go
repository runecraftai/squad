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
	out, code, err = policy.RunCommand(context.Background(), "printf changed > confined.txt && git add confined.txt && GIT_AUTHOR_NAME='Sandbox Agent' GIT_AUTHOR_EMAIL=sandbox@example.invalid GIT_COMMITTER_NAME='Sandbox Agent' GIT_COMMITTER_EMAIL=sandbox@example.invalid git commit -m sandbox-commit", nil)
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

func TestStandardCloneLayoutRunsConfinedCommandsOnPrivateGit(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("drill-repository-execution-v1 requires Linux and Bubblewrap; unsupported hosts must refuse execution")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable in this test environment; production policy acknowledgement must fail")
	}
	root := t.TempDir()
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
	repo := filepath.Join(root, "clone")
	git(t, root, "clone", "-q", source, repo)
	if info, err := os.Stat(filepath.Join(repo, ".git")); err != nil || !info.IsDir() {
		t.Fatalf("standard clone layout unavailable: info=%v err=%v", info, err)
	}
	configBefore, err := os.ReadFile(filepath.Join(repo, ".git", "config"))
	if err != nil {
		t.Fatal(err)
	}
	policy, err := New(repo)
	if err != nil {
		t.Fatalf("mandatory policy setup on standard clone: %v", err)
	}
	defer policy.Close()
	out, code, err := policy.RunCommand(context.Background(), "git log -1 --format=%s", nil)
	if err != nil || code != 0 || strings.TrimSpace(string(out)) != "fixture" {
		t.Fatalf("private Git history unavailable: output=%q code=%d err=%v", out, code, err)
	}
	if _, code, err := policy.RunCommand(context.Background(), "printf compromised >> .git/config", nil); err != nil || code == 0 {
		t.Fatalf("sandbox rewrote private Git config: code=%d err=%v", code, err)
	}
	configAfter, err := os.ReadFile(filepath.Join(repo, ".git", "config"))
	if err != nil || string(configBefore) != string(configAfter) {
		t.Fatalf("confined command changed host Git config: err=%v", err)
	}
	original := git(t, repo, "rev-parse", "HEAD")
	commit := "printf changed > confined.txt && git add confined.txt && GIT_AUTHOR_NAME='Sandbox Agent' GIT_AUTHOR_EMAIL=sandbox@example.invalid GIT_COMMITTER_NAME='Sandbox Agent' GIT_COMMITTER_EMAIL=sandbox@example.invalid git commit -m sandbox-commit"
	if out, code, err := policy.RunCommand(context.Background(), commit, nil); err != nil || code != 0 {
		t.Fatalf("confined git commit failed: output=%q code=%d err=%v", out, code, err)
	}
	if got := git(t, repo, "rev-parse", "HEAD"); got == original {
		t.Fatal("authorized private commit was not imported into the standard clone")
	}
}

func TestSandboxCannotPlantHostGitHookInPrivateConfig(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	root := t.TempDir()
	repo := createExecutionCopy(t, root)
	marker := filepath.Join(root, "hook-ran")
	hook := filepath.Join(root, "hook.sh")
	if err := os.WriteFile(hook, []byte("#!/bin/sh\nprintf pwned > "+shellQuote(marker)+"\nexec git \"$@\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	policy, err := New(repo)
	if err != nil {
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()
	plant := "printf '[uploadpack]\\n\\tpackObjectsHook = %s\\n' " + shellQuote(hook) + " >> /run/drill-execution/git/config"
	if _, code, err := policy.RunCommand(context.Background(), plant, nil); err != nil || code == 0 {
		t.Fatalf("sandbox rewrote private Git config: code=%d err=%v", code, err)
	}
	commit := "printf planted > planted.txt && git add planted.txt && GIT_AUTHOR_NAME='Sandbox Agent' GIT_AUTHOR_EMAIL=sandbox@example.invalid GIT_COMMITTER_NAME='Sandbox Agent' GIT_COMMITTER_EMAIL=sandbox@example.invalid git commit -q -m planted"
	if out, code, err := policy.RunCommand(context.Background(), commit, nil); err != nil || code != 0 {
		t.Fatalf("sandbox commit failed: output=%q code=%d err=%v", out, code, err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("host Git executed a hook planted from the sandbox into private Git config")
	}
}

func TestExecutionPolicyDoesNotMountCredentialBearingPathEntries(t *testing.T) {
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
	t.Setenv("PATH", home+string(os.PathListSeparator)+os.Getenv("PATH"))
	policy, err := New(repo)
	if err != nil {
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()
	out, code, err := policy.RunCommand(context.Background(), "cat "+shellQuote(credential), nil)
	if err != nil {
		t.Fatalf("confined read: %v", err)
	}
	if code == 0 || strings.Contains(string(out), "host-token") {
		t.Fatalf("credential-bearing PATH entry exposed host credential: code=%d output=%q", code, out)
	}
}

func TestRegularBuildGivesFakeagentNamedBinaryNoFixtureAccess(t *testing.T) {
	if e2eBuild {
		t.Skip("fixture access is granted by the e2e build tag")
	}
	policy, root, repo, fixture := newFixtureAccessFixture(t)
	if fixtureGrantedToNamedBinary(t, policy, root, repo, fixture, "fakeagent") {
		t.Fatal("regular build granted fixture access to a binary named fakeagent")
	}
}

func newFixtureAccessFixture(t *testing.T) (*Policy, string, string, string) {
	t.Helper()
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
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	t.Cleanup(func() { _ = policy.Close() })
	return policy, root, repo, fixture
}

func fixtureGrantedToNamedBinary(t *testing.T, policy *Policy, root, repo, fixture, name string) bool {
	t.Helper()
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
	return strings.Contains(strings.Join(cmd.Args, "\x00"), fixture)
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
	probeScript := "#!/bin/sh\ncat /run/drill-execution/home/.claude/.credentials.json; echo; echo own > /run/drill-execution/home/own-launch-marker; cat /run/drill-execution/home/own-launch-marker\n"
	if err := os.WriteFile(claude, []byte(probeScript), 0o700); err != nil {
		t.Fatal(err)
	}
	policy, err := New(repo)
	if err != nil {
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()
	first := exec.Command(claude)
	first.Dir = repo
	if err := policy.Command(first); err != nil {
		t.Fatal(err)
	}
	firstHome := boundLaunchHome(t, first.Args)
	if data, err := os.ReadFile(filepath.Join(firstHome, ".claude", ".credentials.json")); err != nil || !strings.Contains(string(data), "host-token") {
		t.Fatalf("launch home lacks its provider credential: data=%q err=%v", data, err)
	}
	firstCredential := filepath.Join(firstHome, ".claude", ".credentials.json")
	if err := os.WriteFile(firstCredential, []byte(`{"token":"previous-launch-token"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	probe := exec.Command(claude)
	probe.Dir = repo
	if err := policy.Command(probe); err != nil {
		t.Fatal(err)
	}
	secondHome := boundLaunchHome(t, probe.Args)
	if firstHome == secondHome {
		t.Fatalf("launch homes = %q, want distinct homes", firstHome)
	}
	out, err := probe.CombinedOutput()
	if err != nil {
		t.Fatalf("confined probe failed: output=%q err=%v", out, err)
	}
	if strings.Contains(string(out), "previous-launch-token") {
		t.Fatalf("previous launch credential is reachable from next launch home: output=%q", out)
	}
	if !strings.Contains(string(out), "host-token") {
		t.Fatalf("next launch home lacks a fresh provider credential: output=%q", out)
	}
	if data, err := os.ReadFile(filepath.Join(secondHome, "own-launch-marker")); err != nil || strings.TrimSpace(string(data)) != "own" {
		t.Fatalf("next launch home is not writable by its own launch: data=%q err=%v", data, err)
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
