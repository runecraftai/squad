// Package executionpolicy confines repository-controlled programs to the
// daemon's per-run execution copy. The host daemon remains outside the sandbox.
package executionpolicy

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/runecraftai/squad/packages/drill/internal/shellenv"
)

const Name = "drill-repository-execution-v1"

// ExecutionPolicy is the mandatory process and configured-command boundary.
type ExecutionPolicy interface {
	Command(*exec.Cmd) error
	RunCommand(context.Context, string, []string) ([]byte, int, error)
	Sync() error
	Close() error
}

// Policy is one short-lived, run-scoped sandbox with its own Git database.
type Policy struct {
	workDir    string
	root       string
	gitDir     string
	gitFile    string
	syncedHead string
	closed     bool
	mu         sync.Mutex
	syncMu     sync.Mutex
}

// New acknowledges the mandatory execution policy before any repository
// command or code-executing agent is started. Unsupported hosts and broken
// namespace setup return a named error; callers must not retry without it.
func New(workDir string) (*Policy, error) {
	if runtime.GOOS != "linux" {
		return nil, fmt.Errorf("%s: unsupported operating system %q (Linux with Bubblewrap is required)", Name, runtime.GOOS)
	}
	abs, err := filepath.Abs(workDir)
	if err != nil {
		return nil, fmt.Errorf("%s: resolve execution copy: %w", Name, err)
	}
	if info, err := os.Stat(abs); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("%s: execution copy is unavailable: %s", Name, abs)
	}
	bubblewrap, err := exec.LookPath("bwrap")
	if err != nil {
		return nil, fmt.Errorf("%s: Bubblewrap is required but unavailable", Name)
	}
	root, err := os.MkdirTemp("", "drill-execution-policy-")
	if err != nil {
		return nil, fmt.Errorf("%s: create private execution metadata: %w", Name, err)
	}
	fail := func(err error) (*Policy, error) {
		_ = os.RemoveAll(root)
		return nil, err
	}
	initialHead, err := gitOutput(abs, "rev-parse", "HEAD")
	if err != nil {
		return fail(fmt.Errorf("%s: resolve execution-copy head: %w", Name, err))
	}
	gitCommon, err := gitOutput(abs, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return fail(fmt.Errorf("%s: cannot locate repository history: %w", Name, err))
	}
	gitDir := filepath.Join(root, "git")
	if _, err := gitOutput("", "clone", "--bare", "--no-hardlinks", "--no-local", gitCommon, gitDir); err != nil {
		return fail(fmt.Errorf("%s: cannot create task-private Git database: %w", Name, err))
	}
	if _, err := gitOutput(gitDir, "config", "core.bare", "false"); err != nil {
		return fail(fmt.Errorf("%s: configure task-private Git database: %w", Name, err))
	}
	if _, err := gitOutput(gitDir, "config", "core.worktree", abs); err != nil {
		return fail(fmt.Errorf("%s: configure task-private Git worktree: %w", Name, err))
	}
	if _, err := gitOutput(gitDir, "update-ref", "refs/heads/drill-execution", initialHead); err != nil {
		return fail(fmt.Errorf("%s: initialize task-private Git head: %w", Name, err))
	}
	if _, err := gitOutput(gitDir, "symbolic-ref", "HEAD", "refs/heads/drill-execution"); err != nil {
		return fail(fmt.Errorf("%s: initialize task-private Git branch: %w", Name, err))
	}
	gitFile := filepath.Join(root, "git-pointer")
	if err := os.WriteFile(gitFile, []byte("gitdir: /run/drill-execution/git\n"), 0o400); err != nil {
		return fail(fmt.Errorf("%s: prepare private Git pointer: %w", Name, err))
	}
	p := &Policy{workDir: abs, root: root, gitDir: gitDir, gitFile: gitFile, syncedHead: initialHead}
	if err := p.acknowledge(bubblewrap); err != nil {
		return fail(err)
	}
	return p, nil
}

func (p *Policy) acknowledge(bwrap string) error {
	home, err := os.MkdirTemp(p.root, "ack-home-")
	if err != nil {
		return fmt.Errorf("%s: prepare sandbox acknowledgement home: %w", Name, err)
	}
	defer os.RemoveAll(home)
	args := p.baseArgs(home)
	args = append(args, "--", "/bin/true")
	cmd := exec.Command(bwrap, args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%s: sandbox capability check failed: %s", Name, strings.TrimSpace(string(output)))
	}
	return nil
}

func (p *Policy) baseArgs(home string) []string {
	args := []string{"--unshare-all", "--unshare-user", "--unshare-pid", "--share-net", "--die-with-parent", "--new-session", "--disable-userns", "--cap-drop", "ALL", "--clearenv"}
	for _, dir := range []string{"/usr", "/bin", "/sbin", "/lib", "/lib64"} {
		info, err := os.Lstat(dir)
		if err != nil {
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(dir)
			if err == nil {
				args = append(args, "--symlink", target, dir)
			}
		} else {
			args = append(args, "--ro-bind", dir, dir)
		}
	}
	if _, err := os.Stat("/etc/ssl/certs"); err == nil {
		args = append(args, "--ro-bind", "/etc/ssl/certs", "/etc/ssl/certs")
	}
	args = append(args, "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--dir", "/run", "--dir", "/run/drill-execution")
	toolDirs := managedToolDirs()
	for _, root := range toolDirs.roots {
		args = append(args, "--ro-bind", root, root)
	}
	args = append(args, "--bind", p.workDir, p.workDir,
		"--bind", p.gitDir, "/run/drill-execution/git",
		"--ro-bind", p.gitFile, filepath.Join(p.workDir, ".git"),
		"--bind", home, "/run/drill-execution/home",
		"--setenv", "HOME", "/run/drill-execution/home", "--setenv", "TMPDIR", "/tmp",
		"--setenv", "PATH", strings.Join(append(toolDirs.bins, "/usr/local/bin", "/usr/bin", "/bin"), string(os.PathListSeparator)))
	for _, key := range []string{"LANG", "LC_ALL", "TERM", "CI"} {
		if value, ok := os.LookupEnv(key); ok {
			args = append(args, "--setenv", key, value)
		}
	}
	return args
}

// Command rewrites a process launch to execute inside the policy. Only the
// execution copy is writable; the host gate, daemon runtime, and host home are
// absent from the sandbox mount namespace.
func (p *Policy) Command(cmd *exec.Cmd) error {
	if p == nil || p.isClosed() {
		return errors.New(Name + ": execution policy is unavailable")
	}
	if cmd == nil || cmd.Path == "" {
		return errors.New(Name + ": cannot confine an empty command")
	}
	bwrap, err := exec.LookPath("bwrap")
	if err != nil {
		return fmt.Errorf("%s: Bubblewrap is required but unavailable", Name)
	}
	cwd := cmd.Dir
	if cwd == "" {
		cwd = p.workDir
	}
	absCwd, err := filepath.Abs(cwd)
	if err != nil || absCwd != p.workDir && !strings.HasPrefix(absCwd, p.workDir+string(filepath.Separator)) {
		return fmt.Errorf("%s: process working directory is outside the execution copy", Name)
	}
	if err := p.Sync(); err != nil {
		return err
	}
	argv := cmd.Args
	if len(argv) == 0 {
		argv = []string{cmd.Path}
	}
	home, err := os.MkdirTemp(p.root, "launch-home-")
	if err != nil {
		return fmt.Errorf("%s: create fresh launch home: %w", Name, err)
	}
	if err := os.Chmod(home, 0o700); err != nil {
		_ = os.RemoveAll(home)
		return fmt.Errorf("%s: secure fresh launch home: %w", Name, err)
	}
	if err := p.mountAgentCredentials(filepath.Base(cmd.Path), home); err != nil {
		return err
	}
	args := p.baseArgs(home)
	schemaBinds, err := executionSchemaAccess(argv)
	if err != nil {
		return err
	}
	args = append(args, schemaBinds...)
	tool := cmd.Path
	if !filepath.IsAbs(tool) {
		tool, err = exec.LookPath(tool)
		if err != nil {
			return fmt.Errorf("%s: command executable is unavailable: %w", Name, err)
		}
	}
	if resolved, resolveErr := filepath.EvalSymlinks(tool); resolveErr == nil {
		tool = resolved
	}
	if !isSystemPath(tool) {
		root := installationRoot(tool)
		if root != "" {
			args = append(args, "--ro-bind", root, root)
		} else {
			info, err := os.Stat(tool)
			if err != nil || !info.Mode().IsRegular() {
				return fmt.Errorf("%s: configured executable is not a regular file: %s", Name, tool)
			}
			args = append(args, "--ro-bind", tool, tool)
		}
	}
	allowedEnv := sandboxEnv(cmd.Env)
	if e2eBuild && filepath.Base(tool) == "fakeagent" {
		fixtureArgs, fixtureEnv, err := fakeAgentFixtureAccess(p.workDir, cmd.Env)
		if err != nil {
			return err
		}
		args = append(args, fixtureArgs...)
		allowedEnv = append(allowedEnv, fixtureEnv...)
	}
	for _, entry := range allowedEnv {
		key, value, _ := strings.Cut(entry, "=")
		args = append(args, "--setenv", key, value)
	}
	args = append(args, "--chdir", absCwd, "--argv0", argv[0], "--", tool)
	args = append(args, argv[1:]...)
	cmd.Path = bwrap
	cmd.Args = append([]string{bwrap}, args...)
	cmd.Dir = p.workDir
	cmd.Env = []string{"PATH=/usr/bin:/bin"}
	return nil
}

type toolDirectories struct {
	roots []string
	bins  []string
}

func managedToolDirs() toolDirectories {
	var result toolDirectories
	seenRoots := map[string]bool{}
	seenBins := map[string]bool{}
	for _, entry := range filepath.SplitList(os.Getenv("PATH")) {
		if entry == "" {
			continue
		}
		path, err := filepath.Abs(entry)
		if err != nil {
			continue
		}
		if resolved, resolveErr := filepath.EvalSymlinks(path); resolveErr == nil {
			path = resolved
		}
		if path == os.TempDir() || isSystemPath(path) {
			continue
		}
		info, err := os.Stat(path)
		if err != nil || !info.IsDir() {
			continue
		}
		if !seenRoots[path] {
			seenRoots[path] = true
			result.roots = append(result.roots, path)
		}
		if !seenBins[path] {
			seenBins[path] = true
			result.bins = append(result.bins, path)
		}
	}
	for _, name := range []string{"go", "node", "bun", "npm", "python3", "shellcheck", "jq"} {
		path, err := exec.LookPath(name)
		if err == nil {
			if resolved, resolveErr := filepath.EvalSymlinks(path); resolveErr == nil {
				path = resolved
			}
		}
		if err != nil || isSystemPath(path) {
			continue
		}
		root := installationRoot(path)
		if root == "" {
			continue
		}
		if !seenRoots[root] {
			seenRoots[root] = true
			result.roots = append(result.roots, root)
		}
		bin := filepath.Dir(path)
		if !seenBins[bin] {
			seenBins[bin] = true
			result.bins = append(result.bins, bin)
		}
	}
	return result
}

// fakeAgentFixtureAccess gives the compiled e2e fixture only its declared
// read-only scenario data and explicit append-only observation files.
func fakeAgentFixtureAccess(workDir string, env []string) ([]string, []string, error) {
	var binds, variables []string
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if !ok || !strings.HasPrefix(key, "FAKEAGENT_") {
			continue
		}
		variables = append(variables, entry)
		if key != "FAKEAGENT_SCENARIO" && key != "FAKEAGENT_FIXTURE" && key != "FAKEAGENT_LOG" && key != "FAKEAGENT_GH_LOG" {
			continue
		}
		path := value
		if !filepath.IsAbs(path) {
			path = filepath.Join(workDir, path)
		}
		path = filepath.Clean(path)
		if key == "FAKEAGENT_LOG" || key == "FAKEAGENT_GH_LOG" {
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				return nil, nil, fmt.Errorf("%s: prepare fake-agent observation output: %w", Name, err)
			}
			file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
			if err != nil {
				return nil, nil, fmt.Errorf("%s: prepare fake-agent observation output: %w", Name, err)
			}
			_ = file.Close()
			binds = append(binds, "--bind", path, path)
		} else {
			if _, err := os.Stat(path); err != nil {
				return nil, nil, fmt.Errorf("%s: fake-agent fixture is unavailable: %w", Name, err)
			}
			binds = append(binds, "--ro-bind", path, path)
		}
	}
	return binds, variables, nil
}

func executionSchemaAccess(argv []string) ([]string, error) {
	var binds []string
	for _, arg := range argv {
		if !filepath.IsAbs(arg) || !strings.HasPrefix(filepath.Base(arg), "drill-codex-schema-") || !strings.HasSuffix(arg, ".json") || filepath.Dir(arg) != os.TempDir() {
			continue
		}
		info, err := os.Stat(arg)
		if err != nil || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("%s: generated agent schema is unavailable: %s", Name, arg)
		}
		binds = append(binds, "--ro-bind", arg, arg)
	}
	return binds, nil
}

func sandboxEnv(env []string) []string {
	allowed := map[string]bool{"LANG": true, "LC_ALL": true, "TERM": true, "CI": true,
		"OPENAI_API_KEY": true, "ANTHROPIC_API_KEY": true, "GEMINI_API_KEY": true,
		"GOOGLE_API_KEY": true, "XAI_API_KEY": true, "GROQ_API_KEY": true,
		"OPENROUTER_API_KEY": true, "KIMI_API_KEY": true}
	var result []string
	for _, entry := range env {
		key, _, ok := strings.Cut(entry, "=")
		if ok && allowed[key] {
			result = append(result, entry)
		}
	}
	return result
}

func isSystemPath(path string) bool {
	for _, prefix := range []string{"/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/"} {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

func installationRoot(path string) string {
	clean := filepath.Clean(path)
	parts := strings.Split(clean, string(filepath.Separator))
	for i := 0; i+3 < len(parts); i++ {
		if parts[i] == "mise" && parts[i+1] == "installs" {
			return filepath.Join(string(filepath.Separator), filepath.Join(parts[1:i+4]...))
		}
	}
	return ""
}

func (p *Policy) mountAgentCredentials(executable, home string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	layouts := map[string][]string{
		"pi":       {".pi/agent/auth.json", ".pi/agent/models.json"},
		"claude":   {".claude/.credentials.json"},
		"codex":    {".codex/auth.json"},
		"opencode": {".local/share/opencode/auth.json"},
		"copilot":  {".config/github-copilot/hosts.json"},
	}
	files := layouts[executable]
	if len(files) == 0 {
		return nil
	}
	hostHome, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("%s: resolve provider credentials: %w", Name, err)
	}
	for _, relative := range files {
		source := filepath.Join(hostHome, relative)
		info, err := os.Stat(source)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("%s: provider credential is not a regular file: %s", Name, source)
		}
		target := filepath.Join(home, relative)
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return fmt.Errorf("%s: prepare private credential directory: %w", Name, err)
		}
		data, err := os.ReadFile(source)
		if err != nil {
			return fmt.Errorf("%s: read provider credential: %w", Name, err)
		}
		if err := os.WriteFile(target, data, 0o600); err != nil {
			return fmt.Errorf("%s: copy provider credential: %w", Name, err)
		}
	}
	return nil
}

// RunCommand applies the policy and runs a repository-configured shell command.
func (p *Policy) RunCommand(ctx context.Context, command string, env []string) ([]byte, int, error) {
	cmd := exec.CommandContext(ctx, "sh", "-c", command)
	cmd.Dir = p.workDir
	cmd.Env = env
	shellenv.ConfigureShellCommand(cmd)
	if err := p.Command(cmd); err != nil {
		return nil, -1, err
	}
	out, err := cmd.CombinedOutput()
	syncErr := p.Sync()
	if syncErr != nil {
		return out, -1, syncErr
	}
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return out, exitErr.ExitCode(), nil
		}
		return out, -1, fmt.Errorf("%s: confined command failed: %w", Name, err)
	}
	return out, 0, nil
}

// Sync imports only the run-private HEAD into its linked execution copy.
func (p *Policy) Sync() error {
	if p == nil || p.isClosed() {
		return errors.New(Name + ": execution policy is unavailable")
	}
	p.syncMu.Lock()
	defer p.syncMu.Unlock()
	if p.isClosed() {
		return errors.New(Name + ": execution policy is unavailable")
	}
	privateHead, err := gitOutput(p.gitDir, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("%s: read private Git head: %w", Name, err)
	}
	hostHead, err := gitOutput(p.workDir, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("%s: read host execution-copy head: %w", Name, err)
	}
	if privateHead == hostHead {
		p.syncedHead = hostHead
		return nil
	}
	if _, err := gitOutput(p.gitDir, "fetch", "--no-write-fetch-head", "--no-tags", p.workDir, hostHead); err != nil {
		return fmt.Errorf("%s: import host execution-copy objects into private Git: %w", Name, err)
	}
	if _, err := gitOutput(p.gitDir, "merge-base", "--is-ancestor", privateHead, hostHead); err == nil {
		if _, err := gitOutput(p.gitDir, "update-ref", "refs/heads/drill-execution", hostHead, privateHead); err != nil {
			return fmt.Errorf("%s: import host execution-copy commit into private Git: %w", Name, err)
		}
		if _, err := gitOutput(p.gitDir, "reset", "--mixed", hostHead); err != nil {
			return fmt.Errorf("%s: refresh private Git index: %w", Name, err)
		}
		p.syncedHead = hostHead
		return nil
	}
	if _, err := gitOutput(p.gitDir, "merge-base", "--is-ancestor", hostHead, privateHead); err != nil {
		if privateHead != p.syncedHead {
			return fmt.Errorf("%s: host and private Git histories diverged", Name)
		}
		if _, err := gitOutput(p.gitDir, "update-ref", "refs/heads/drill-execution", hostHead, privateHead); err != nil {
			return fmt.Errorf("%s: align private Git after host history rewrite: %w", Name, err)
		}
		if _, err := gitOutput(p.gitDir, "reset", "--mixed", hostHead); err != nil {
			return fmt.Errorf("%s: refresh private Git index after host history rewrite: %w", Name, err)
		}
		p.syncedHead = hostHead
		return nil
	}
	if _, err := gitOutput(p.workDir, "fetch", "--no-write-fetch-head", "--no-tags", p.gitDir, privateHead); err != nil {
		return fmt.Errorf("%s: import private Git result: %w", Name, err)
	}
	if _, err := gitOutput(p.workDir, "update-ref", "HEAD", privateHead, hostHead); err != nil {
		return fmt.Errorf("%s: update execution-copy head: %w", Name, err)
	}
	if _, err := gitOutput(p.workDir, "reset", "--mixed", privateHead); err != nil {
		return fmt.Errorf("%s: refresh execution-copy index: %w", Name, err)
	}
	p.syncedHead = privateHead
	return nil
}

func (p *Policy) isClosed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closed
}

// Close removes task-private Git objects and execution metadata.
func (p *Policy) Close() error {
	if p == nil {
		return nil
	}
	p.syncMu.Lock()
	defer p.syncMu.Unlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	p.closed = true
	return os.RemoveAll(p.root)
}

func gitOutput(dir string, args ...string) (string, error) {
	argv := append([]string{"-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.file.allow=always"}, args...)
	cmd := exec.Command("git", argv...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %s: %w", strings.Join(args, " "), strings.TrimSpace(string(out)), err)
	}
	return strings.TrimSpace(string(out)), nil
}
