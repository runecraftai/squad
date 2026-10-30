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

func TestRunEvidenceDirectoryIsSharedWithTheHostFromInsideTheSandbox(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	root := t.TempDir()
	hostTemp := filepath.Join(root, "host-tmp")
	if err := os.Mkdir(hostTemp, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", hostTemp)
	repoRoot := filepath.Join(root, "repo-root")
	if err := os.Mkdir(repoRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	repo := createExecutionCopy(t, repoRoot)
	policy, err := New(repo)
	if err != nil {
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()

	evidenceDir := filepath.Join(os.TempDir(), "drill-evidence", "run-123")
	artifact := filepath.Join(evidenceDir, "artifact.txt")
	write := "mkdir -p " + shellQuote(evidenceDir) + " && printf evidence > " + shellQuote(artifact)
	if out, code, err := policy.RunCommand(context.Background(), write, nil); err != nil || code != 0 {
		t.Fatalf("confined evidence write failed: output=%q code=%d err=%v", out, code, err)
	}
	if data, err := os.ReadFile(artifact); err != nil || string(data) != "evidence" {
		t.Fatalf("confined evidence write did not reach the host evidence directory: data=%q err=%v", data, err)
	}
	if out, code, err := policy.RunCommand(context.Background(), "cat "+shellQuote(artifact), nil); err != nil || code != 0 || strings.TrimSpace(string(out)) != "evidence" {
		t.Fatalf("evidence did not survive into the next launch: output=%q code=%d err=%v", out, code, err)
	}
}

func TestSandboxCannotRedirectPrivateGitObjectStorage(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	for _, layout := range []struct {
		name   string
		create func(*testing.T, string) string
	}{
		{"worktree", createExecutionCopy},
		{"standard-clone", createStandardClone},
	} {
		t.Run(layout.name, func(t *testing.T) {
			root := t.TempDir()
			repo := layout.create(t, root)
			policy, err := New(repo)
			if err != nil {
				t.Fatalf("execution sandbox unavailable: %v", err)
			}
			defer policy.Close()
			for _, gitRoot := range []string{"/run/drill-execution/git", filepath.Join(repo, ".git")} {
				plant := "printf " + shellQuote(filepath.Join(root, "host-objects")+"\\n") + " > " + shellQuote(filepath.Join(gitRoot, "objects", "info", "alternates"))
				if _, code, err := policy.RunCommand(context.Background(), plant, nil); err != nil || code == 0 {
					t.Fatalf("sandbox redirected private Git object storage via %s: code=%d err=%v", gitRoot, code, err)
				}
			}
			if _, err := os.Lstat(filepath.Join(policy.gitDir, "objects", "info", "alternates")); err != nil {
				t.Fatalf("sealed object storage file is missing: %v", err)
			}
			commit := "printf planted > planted.txt && git add planted.txt && GIT_AUTHOR_NAME='Sandbox Agent' GIT_AUTHOR_EMAIL=sandbox@example.invalid GIT_COMMITTER_NAME='Sandbox Agent' GIT_COMMITTER_EMAIL=sandbox@example.invalid git commit -q -m planted"
			if out, code, err := policy.RunCommand(context.Background(), commit, nil); err != nil || code != 0 {
				t.Fatalf("sandbox commit after refused redirect failed: output=%q code=%d err=%v", out, code, err)
			}
			alternates := filepath.Join(policy.gitDir, "objects", "info", "alternates")
			if data, err := os.ReadFile(alternates); err != nil || len(data) != 0 {
				t.Fatalf("sealed object storage file = %q err=%v, want empty", data, err)
			}
			if err := os.WriteFile(alternates, []byte(filepath.Join(root, "host-objects")+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := policy.Sync(); err == nil {
				t.Fatal("policy synchronized a private Git database with redirected object storage")
			}
		})
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
	repo := createStandardClone(t, root)
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
	for _, layout := range []struct {
		name   string
		create func(*testing.T, string) string
	}{
		{"worktree", createExecutionCopy},
		{"standard-clone", createStandardClone},
	} {
		t.Run(layout.name, func(t *testing.T) {
			root := t.TempDir()
			repo := layout.create(t, root)
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
		})
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
	script := "#!/bin/sh\ncat " + shellQuote(fixture) + "\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(fake)
	cmd.Dir = repo
	cmd.Env = []string{"FAKEAGENT_FIXTURE=" + fixture}
	if err := policy.Command(cmd); err != nil {
		t.Fatal(err)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("confined %s could not read the fixture: %v", name, err)
		return false
	}
	return strings.Contains(string(out), "scenario: synthetic")
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

func createStandardClone(t *testing.T, root string) string {
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
	repo := filepath.Join(root, "clone")
	git(t, root, "clone", "-q", source, repo)
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

func TestPrivateGitIndexMatchesItsHeadInsideTheSandbox(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	root := t.TempDir()
	source := filepath.Join(root, "source")
	if err := os.Mkdir(source, 0o700); err != nil {
		t.Fatal(err)
	}
	git(t, source, "init", "-q")
	git(t, source, "config", "user.name", "Policy Test")
	git(t, source, "config", "user.email", "policy@example.invalid")
	for _, name := range []string{"tracked.txt", "second.txt"} {
		if err := os.WriteFile(filepath.Join(source, name), []byte(name+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	git(t, source, "add", "tracked.txt", "second.txt")
	git(t, source, "commit", "-q", "-m", "fixture")
	repo := filepath.Join(root, "execution-copy")
	git(t, source, "worktree", "add", "--detach", repo, "HEAD")

	policy, err := New(repo)
	if err != nil {
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()

	out, code, err := policy.RunCommand(context.Background(), "git status --porcelain", nil)
	if err != nil || code != 0 {
		t.Fatalf("confined status: output=%q code=%d err=%v", out, code, err)
	}
	if strings.TrimSpace(string(out)) != "" {
		t.Fatalf("private Git index does not match its head: %q", out)
	}
	out, code, err = policy.RunCommand(context.Background(), "git diff --staged --name-only", nil)
	if err != nil || code != 0 || strings.TrimSpace(string(out)) != "" {
		t.Fatalf("private Git staged diff should be empty: output=%q code=%d err=%v", out, code, err)
	}

	commit := "printf one > one.txt && git add one.txt && GIT_AUTHOR_NAME='Sandbox Agent' GIT_AUTHOR_EMAIL=sandbox@example.invalid GIT_COMMITTER_NAME='Sandbox Agent' GIT_COMMITTER_EMAIL=sandbox@example.invalid git commit -q -m one-file"
	if out, code, err := policy.RunCommand(context.Background(), commit, nil); err != nil || code != 0 {
		t.Fatalf("confined git commit failed: output=%q code=%d err=%v", out, code, err)
	}
	out, code, err = policy.RunCommand(context.Background(), "git ls-tree --name-only HEAD", nil)
	if err != nil || code != 0 {
		t.Fatalf("confined ls-tree: output=%q code=%d err=%v", out, code, err)
	}
	tracked := strings.Fields(string(out))
	for _, want := range []string{"one.txt", "second.txt", "tracked.txt"} {
		found := false
		for _, name := range tracked {
			if name == want {
				found = true
			}
		}
		if !found {
			t.Fatalf("commit dropped tracked path %q: staged commit tree %v", want, tracked)
		}
	}
}

func TestSandboxResolvesHostnamesFromTheHostResolverConfiguration(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	resolver, err := os.ReadFile("/etc/resolv.conf")
	if err != nil {
		t.Skip("host has no /etc/resolv.conf")
	}
	root := t.TempDir()
	repo := createExecutionCopy(t, root)
	policy, err := New(repo)
	if err != nil {
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()

	out, code, err := policy.RunCommand(context.Background(), "cat /etc/resolv.conf", nil)
	if err != nil || code != 0 {
		t.Fatalf("confined resolver read: output=%q code=%d err=%v", out, code, err)
	}
	if string(out) != string(resolver) {
		t.Fatalf("sandbox resolver configuration differs from the host: got %q want %q", out, resolver)
	}
	out, code, err = policy.RunCommand(context.Background(), "getent hosts localhost", nil)
	if err != nil || code != 0 || strings.TrimSpace(string(out)) == "" {
		t.Fatalf("confined hostname lookup failed: output=%q code=%d err=%v", out, code, err)
	}
}

func TestSandboxKeepsNonInteractiveGitAndGateEnvironment(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	root := t.TempDir()
	repo := createExecutionCopy(t, root)
	policy, err := New(repo)
	if err != nil {
		t.Fatalf("execution sandbox unavailable: %v", err)
	}
	defer policy.Close()

	probe := filepath.Join(root, "probe")
	script := "#!/bin/sh\nprintf '%s|%s|%s|%s|%s' \"$GIT_EDITOR\" \"$GIT_SEQUENCE_EDITOR\" \"$GIT_TERMINAL_PROMPT\" \"$DRILL_GATE\" \"$PWD\"\n"
	if err := os.WriteFile(probe, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(probe)
	cmd.Dir = repo
	cmd.Env = []string{"GIT_EDITOR=vim", "GIT_SEQUENCE_EDITOR=vim", "GIT_TERMINAL_PROMPT=1", "DRILL_GATE=1"}
	if err := policy.Command(cmd); err != nil {
		t.Fatal(err)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("confined environment probe: output=%q err=%v", out, err)
	}
	want := "true|true|0|1|" + repo
	if strings.TrimSpace(string(out)) != want {
		t.Fatalf("confined environment = %q, want %q", out, want)
	}
	if _, code, err := policy.RunCommand(context.Background(), "mkdir -p \"$GOCACHE\" && printf cached > \"$GOCACHE/probe\"", nil); err != nil || code != 0 {
		t.Fatalf("confined build cache is not writable: code=%d err=%v", code, err)
	}
	if out, code, err := policy.RunCommand(context.Background(), "cat \"$GOCACHE/probe\"", nil); err != nil || code != 0 || strings.TrimSpace(string(out)) != "cached" {
		t.Fatalf("build cache did not persist across confined commands: output=%q code=%d err=%v", out, code, err)
	}
}

func TestSandboxCannotRedirectPrivateGitCommonDirectory(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	for _, layout := range []struct {
		name   string
		create func(*testing.T, string) string
	}{
		{"worktree", createExecutionCopy},
		{"standard-clone", createStandardClone},
	} {
		t.Run(layout.name, func(t *testing.T) {
			root := t.TempDir()
			repo := layout.create(t, root)
			marker := filepath.Join(root, "host-executed")
			policy, err := New(repo)
			if err != nil {
				t.Fatalf("execution sandbox unavailable: %v", err)
			}
			defer policy.Close()
			plant := "printf " + shellQuote(repo+"/.evil") + " > /run/drill-execution/git/commondir"
			if _, code, err := policy.RunCommand(context.Background(), plant, nil); err != nil || code == 0 {
				t.Fatalf("sandbox redirected the private Git common directory: code=%d err=%v", code, err)
			}
			if err := os.WriteFile(filepath.Join(repo, "host-change.txt"), []byte("host\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			git(t, repo, "add", "host-change.txt")
			git(t, repo, "commit", "-q", "-m", "host change")
			if err := policy.Sync(); err != nil {
				t.Fatalf("sync after a refused redirect: %v", err)
			}
			if _, err := os.Stat(marker); err == nil {
				t.Fatal("host Git executed a program reached through the private Git common directory")
			}
		})
	}
}

func TestHostGitRefusesTamperedPrivateGitControlFiles(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux and Bubblewrap")
	}
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("Bubblewrap unavailable")
	}
	for _, tamper := range []struct {
		name  string
		apply func(*testing.T, *Policy, string, string)
	}{
		{"common-directory-redirect", func(t *testing.T, policy *Policy, evil, script string) {
			if err := os.WriteFile(filepath.Join(policy.gitDir, "commondir"), []byte(evil+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}},
		{"config-transport-rewrite", func(t *testing.T, policy *Policy, evil, script string) {
			config := "[protocol \"ext\"]\n\tallow = always\n[url \"ext::sh -c '" + script + "' %S\"]\n\tinsteadOf = " + policy.workDir + "\n"
			file, err := os.OpenFile(filepath.Join(policy.gitDir, "config"), os.O_APPEND|os.O_WRONLY, 0o600)
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			if _, err := file.WriteString(config); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tamper.name, func(t *testing.T) {
			root := t.TempDir()
			repo := createExecutionCopy(t, root)
			marker := filepath.Join(root, "host-executed")
			script := filepath.Join(repo, "evil.sh")
			if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf pwned > "+shellQuote(marker)+"\nexec git \"$@\"\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			evil := filepath.Join(repo, ".evil")
			if err := os.Mkdir(evil, 0o700); err != nil {
				t.Fatal(err)
			}
			git(t, evil, "init", "-q", "--bare")
			git(t, evil, "config", "protocol.ext.allow", "always")
			git(t, evil, "config", "url.ext::sh -c '"+script+"' %S.insteadOf", repo)

			policy, err := New(repo)
			if err != nil {
				t.Fatalf("execution sandbox unavailable: %v", err)
			}
			defer policy.Close()
			tamper.apply(t, policy, evil, script)

			if _, err := gitOutput(policy.gitDir, "fetch", "--no-write-fetch-head", "--no-tags", policy.workDir, "HEAD"); err == nil {
				t.Fatal("host Git accepted a tampered private Git database")
			}
			if _, err := os.Stat(marker); err == nil {
				t.Fatal("host Git executed a repository-authored program from a tampered private Git database")
			}
			if err := policy.Sync(); err == nil {
				t.Fatal("policy synchronized a tampered private Git database")
			}
			if _, err := os.Stat(marker); err == nil {
				t.Fatal("policy Sync executed a repository-authored program from a tampered private Git database")
			}
		})
	}
}

func TestCertificateBundleSymlinkTargetIsBoundAtItsHostPath(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(root, "etc/ca-certificates/extracted/tls-ca-bundle.pem")
	link := filepath.Join(root, "etc/ssl/certs/ca-certificates.crt")
	for _, dir := range []string{filepath.Dir(bundle), filepath.Dir(link)} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(bundle, []byte("roots"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../ca-certificates/extracted/tls-ca-bundle.pem", link); err != nil {
		t.Fatal(err)
	}
	got := certificateTargetBinds(root)
	want := []string{"--ro-bind", filepath.Dir(bundle), "/etc/ca-certificates/extracted"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("certificate binds = %q, want %q", got, want)
	}
}

func TestCertificateBundleSymlinkChainIsMaterializedAtEveryHop(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(root, "nix/store/pkg/etc/ssl/certs/ca-bundle.crt")
	intermediate := filepath.Join(root, "etc/static/ssl/certs/ca-certificates.crt")
	link := filepath.Join(root, "etc/ssl/certs/ca-certificates.crt")
	for _, dir := range []string{filepath.Dir(bundle), filepath.Dir(intermediate), filepath.Dir(link)} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(bundle, []byte("roots"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../../../nix/store/pkg/etc/ssl/certs/ca-bundle.crt", intermediate); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../static/ssl/certs/ca-certificates.crt", link); err != nil {
		t.Fatal(err)
	}
	got := certificateTargetBinds(root)
	want := []string{
		"--ro-bind", filepath.Dir(bundle), "/nix/store/pkg/etc/ssl/certs",
		"--ro-bind", bundle, "/etc/static/ssl/certs/ca-certificates.crt",
	}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("certificate binds = %q, want %q", got, want)
	}
}

func TestCertificateBundleChainThroughAlternativesIsMaterialized(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(root, "usr/share/ca-certificates/mozilla/ca-certificates.crt")
	intermediate := filepath.Join(root, "etc/alternatives/ca-certificates.crt")
	link := filepath.Join(root, "etc/ssl/certs/ca-certificates.crt")
	for _, dir := range []string{filepath.Dir(bundle), filepath.Dir(intermediate), filepath.Dir(link)} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(bundle, []byte("roots"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../usr/share/ca-certificates/mozilla/ca-certificates.crt", intermediate); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../alternatives/ca-certificates.crt", link); err != nil {
		t.Fatal(err)
	}
	got := certificateTargetBinds(root)
	want := []string{"--ro-bind", bundle, "/etc/alternatives/ca-certificates.crt"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("certificate binds = %q, want %q", got, want)
	}
}

func TestCertificateShallowBundleTargetIsBoundAsFile(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(root, "etc/ca-bundle.pem")
	link := filepath.Join(root, "etc/ssl/certs/ca-certificates.crt")
	for _, dir := range []string{filepath.Dir(bundle), filepath.Dir(link)} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(bundle, []byte("roots"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../ca-bundle.pem", link); err != nil {
		t.Fatal(err)
	}
	got := certificateTargetBinds(root)
	want := []string{"--ro-bind", bundle, "/etc/ca-bundle.pem"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("certificate binds = %q, want %q", got, want)
	}
}

func TestCertificateDirectoryEntryDoesNotMaterializeDirectoryAsFile(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bundles := filepath.Join(root, "srv/certs/bundles")
	intermediate := filepath.Join(root, "etc/static/bundles")
	link := filepath.Join(root, "etc/ssl/certs/bundles")
	for _, dir := range []string{bundles, filepath.Dir(intermediate), filepath.Dir(link)} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(bundles, "bundle.pem"), []byte("roots"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../srv/certs/bundles", intermediate); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../static/bundles", link); err != nil {
		t.Fatal(err)
	}
	got := certificateTargetBinds(root)
	want := []string{"--ro-bind", filepath.Join(root, "srv/certs"), "/srv/certs"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("certificate binds = %q, want %q", got, want)
	}
}

func TestCertificateBindsAreEmptyWithoutCertificatePaths(t *testing.T) {
	root := t.TempDir()
	if got := certificateTargetBinds(root); len(got) != 0 {
		t.Fatalf("binds without /etc/ssl/certs = %q, want none", got)
	}
	if err := os.MkdirAll(filepath.Join(root, "etc/ssl/certs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc/ssl/certs/local.pem"), []byte("roots"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("missing.pem", filepath.Join(root, "etc/ssl/certs/dangling.pem")); err != nil {
		t.Fatal(err)
	}
	if got := certificateTargetBinds(root); len(got) != 0 {
		t.Fatalf("binds for in-place and dangling entries = %q, want none", got)
	}
}

func TestInstallRootIsAvailableForToolInstalledUnderBin(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	install := filepath.Join(root, "toolchain")
	for _, dir := range []string{filepath.Join(install, "bin"), filepath.Join(install, "src")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(install, "bin", "go"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", filepath.Join(install, "bin"))
	dirs := managedToolDirs()
	if !containsString(dirs.roots, install) || !containsString(dirs.roots, filepath.Join(install, "bin")) {
		t.Fatalf("roots = %q, want install root and bin", dirs.roots)
	}
	if !containsString(dirs.bins, filepath.Join(install, "bin")) {
		t.Fatalf("bins = %q, want bin directory", dirs.bins)
	}
	if got := toolInstallRoot(filepath.Join(install, "bin", "go")); got != install {
		t.Fatalf("toolInstallRoot = %q, want %q", got, install)
	}
}

func TestInstallRootIsNotWidenedForUnrelatedBinDirectories(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	elsewhere := filepath.Join(root, "elsewhere")
	other := filepath.Join(root, "other")
	for _, dir := range []string{filepath.Join(elsewhere, "bin"), filepath.Join(other, "bin"), filepath.Join(other, "src")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(elsewhere, "bin", "go"), []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(elsewhere, "bin", "go"), filepath.Join(other, "bin", "go")); err != nil {
		t.Fatal(err)
	}
	if got := installRootForBin(filepath.Join(elsewhere, "bin")); got != "" {
		t.Fatalf("root without src marker = %q, want none", got)
	}
	if got := installRootForBin(filepath.Join(other, "bin")); got != "" {
		t.Fatalf("root for symlink leaving the tree = %q, want none", got)
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
