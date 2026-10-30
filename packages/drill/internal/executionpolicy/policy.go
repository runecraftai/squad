// Package executionpolicy confines repository-controlled programs to the
// daemon's per-run execution copy. The host daemon remains outside the sandbox.
package executionpolicy

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
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
	OnClose(stop func()) error
	Close() error
}

// Policy is one short-lived, run-scoped sandbox with its own Git database.
type Policy struct {
	workDir      string
	root         string
	gitDir       string
	evidenceDir  string
	configDigest [sha256.Size]byte
	gitFile      string
	gitLink      string
	gitLinkIsDir bool
	syncedHead   string
	closing      bool
	closed       bool
	onClose      []func()
	mu           sync.Mutex
	syncMu       sync.Mutex
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
	if _, err := gitOutput(gitDir, "read-tree", initialHead); err != nil {
		return fail(fmt.Errorf("%s: initialize task-private Git index: %w", Name, err))
	}
	if err := os.WriteFile(filepath.Join(gitDir, "commondir"), []byte("\n"), 0o600); err != nil {
		return fail(fmt.Errorf("%s: seal task-private Git common directory: %w", Name, err))
	}
	configDigest, err := fileDigest(filepath.Join(gitDir, "config"))
	if err != nil {
		return fail(fmt.Errorf("%s: record task-private Git configuration: %w", Name, err))
	}
	cacheDir := filepath.Join(root, "cache")
	if err := os.Mkdir(cacheDir, 0o700); err != nil {
		return fail(fmt.Errorf("%s: create task-private build cache: %w", Name, err))
	}
	evidenceDir := filepath.Join(os.TempDir(), "drill-evidence")
	if err := os.MkdirAll(evidenceDir, 0o755); err != nil {
		return fail(fmt.Errorf("%s: prepare run evidence directory: %w", Name, err))
	}
	if err := os.MkdirAll(filepath.Join(gitDir, "objects", "info"), 0o700); err != nil {
		return fail(fmt.Errorf("%s: prepare task-private Git object metadata: %w", Name, err))
	}
	for _, name := range sealedObjectStorageFiles {
		if err := os.WriteFile(filepath.Join(gitDir, "objects", "info", name), nil, 0o600); err != nil {
			return fail(fmt.Errorf("%s: seal task-private Git object storage: %w", Name, err))
		}
	}
	gitLink := filepath.Join(abs, ".git")
	gitLinkIsDir := false
	if info, statErr := os.Stat(gitLink); statErr == nil && info.IsDir() {
		gitLinkIsDir = true
	}
	gitFile := ""
	if !gitLinkIsDir {
		gitFile = filepath.Join(root, "git-pointer")
		if err := os.WriteFile(gitFile, []byte("gitdir: /run/drill-execution/git\n"), 0o400); err != nil {
			return fail(fmt.Errorf("%s: prepare private Git pointer: %w", Name, err))
		}
	}
	p := &Policy{workDir: abs, root: root, gitDir: gitDir, evidenceDir: evidenceDir, configDigest: configDigest, gitFile: gitFile, gitLink: gitLink, gitLinkIsDir: gitLinkIsDir, syncedHead: initialHead}
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

// sealedObjectStorageFiles are the Git object-store redirection files the
// policy creates empty and binds read-only inside the sandbox, so
// repository-controlled programs cannot point host Git at an object database
// the policy never proved.
var sealedObjectStorageFiles = []string{"alternates", "http-alternates"}

func sealedObjectStorage(gitRoot, gitDir string) []string {
	var args []string
	for _, name := range sealedObjectStorageFiles {
		source := filepath.Join(gitDir, "objects", "info", name)
		args = append(args, "--ro-bind", source, filepath.Join(gitRoot, "objects", "info", name))
	}
	return args
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
		args = append(args, certificateTargetBinds("")...)
	}
	args = append(args, "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--dir", "/run", "--dir", "/run/drill-execution")
	for _, path := range []string{"/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf", "/etc/host.conf", "/etc/gai.conf"} {
		if _, err := os.Stat(path); err != nil {
			continue
		}
		args = append(args, "--ro-bind", path, path)
		if resolved, err := filepath.EvalSymlinks(path); err == nil && resolved != path {
			args = append(args, "--ro-bind", path, resolved)
		}
	}
	toolDirs := managedToolDirs()
	for _, root := range toolDirs.roots {
		args = append(args, "--ro-bind", root, root)
	}
	args = append(args, "--bind", p.workDir, p.workDir, "--bind", p.gitDir, "/run/drill-execution/git",
		"--ro-bind", filepath.Join(p.gitDir, "config"), "/run/drill-execution/git/config",
		"--ro-bind", filepath.Join(p.gitDir, "commondir"), "/run/drill-execution/git/commondir")
	args = append(args, sealedObjectStorage("/run/drill-execution/git", p.gitDir)...)
	if p.gitLinkIsDir {
		args = append(args, "--bind", p.gitDir, p.gitLink,
			"--ro-bind", filepath.Join(p.gitDir, "config"), filepath.Join(p.gitLink, "config"),
			"--ro-bind", filepath.Join(p.gitDir, "commondir"), filepath.Join(p.gitLink, "commondir"))
		args = append(args, sealedObjectStorage(p.gitLink, p.gitDir)...)
	} else {
		args = append(args, "--ro-bind", p.gitFile, p.gitLink)
	}
	args = append(args, "--bind", filepath.Join(p.root, "cache"), "/run/drill-execution/cache",
		"--bind", home, "/run/drill-execution/home",
		"--bind", p.evidenceDir, p.evidenceDir,
		"--setenv", "HOME", "/run/drill-execution/home", "--setenv", "TMPDIR", "/tmp",
		"--setenv", "GOCACHE", "/run/drill-execution/cache/go-build",
		"--setenv", "GOMODCACHE", "/run/drill-execution/cache/go-mod",
		"--setenv", "GIT_EDITOR", "true", "--setenv", "GIT_SEQUENCE_EDITOR", "true",
		"--setenv", "GIT_TERMINAL_PROMPT", "0", "--setenv", "GIT_OPTIONAL_LOCKS", "0",
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
	launched := false
	defer func() {
		if !launched {
			_ = os.RemoveAll(home)
		}
	}()
	if err := os.Chmod(home, 0o700); err != nil {
		return fmt.Errorf("%s: secure fresh launch home: %w", Name, err)
	}
	if err := p.mountAgentCredentials(filepath.Base(cmd.Path), home); err != nil {
		return err
	}
	args := p.baseArgs(home)
	args = append(args, "--setenv", "PWD", absCwd)
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
		root := toolInstallRoot(tool)
		if root != "" && !exposesHostCredentials(root) {
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
	if e2eBuild {
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
	launched = true
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
		if path == os.TempDir() || isSystemPath(path) || exposesHostCredentials(path) {
			continue
		}
		info, err := os.Stat(path)
		if err != nil || !info.IsDir() {
			continue
		}
		if root := installRootForBin(path); root != "" && !seenRoots[root] && root != os.TempDir() && !exposesHostCredentials(root) {
			seenRoots[root] = true
			result.roots = append(result.roots, root)
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
		root := toolInstallRoot(path)
		if root == "" || exposesHostCredentials(root) {
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
		"PWD": true, "GOFLAGS": true, "GOTOOLCHAIN": true, "DRILL_GATE": true,
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

// installRootTools maps a tool that cannot run from its bin directory alone to
// a directory that marks its install root (Go resolves GOROOT from the binary
// location and needs src beside bin).
var installRootTools = map[string]string{"go": "src"}

// installRootForBin returns the install root of a bin directory holding a tool
// that needs more than bin, or "" when binDir is not such a directory. The tool
// must resolve inside the root so a symlink into another tree never widens the
// mount.
func installRootForBin(binDir string) string {
	root := filepath.Dir(binDir)
	if filepath.Base(binDir) != "bin" || root == string(filepath.Separator) || root == "." {
		return ""
	}
	for tool, marker := range installRootTools {
		exe, err := filepath.EvalSymlinks(filepath.Join(binDir, tool))
		if err != nil || !strings.HasPrefix(exe, root+string(filepath.Separator)) {
			continue
		}
		if info, err := os.Stat(filepath.Join(root, marker)); err == nil && info.IsDir() {
			return root
		}
	}
	return ""
}

// toolInstallRoot is the directory to mount for a resolved executable outside
// the system paths: its managed installation root, or the install root of a
// tool that needs more than its bin directory.
func toolInstallRoot(tool string) string {
	if root := installationRoot(tool); root != "" {
		return root
	}
	return installRootForBin(filepath.Dir(tool))
}

// certificateTargetBinds makes TLS roots reachable at the absolute path a
// client would open on the host. Entries of /etc/ssl/certs are often symlinks
// into another tree (for example /etc/ca-certificates/extracted), and binding
// only /etc/ssl/certs leaves them dangling. hostRoot prefixes host lookups and
// is empty outside tests. Targets under system paths are already mounted, and
// anything shallower than two path elements or exposing host credentials is
// never bound.
func certificateTargetBinds(hostRoot string) []string {
	certs := filepath.Join(hostRoot, "/etc/ssl/certs")
	entries, err := os.ReadDir(certs)
	if err != nil {
		return nil
	}
	var dirs []string
	for _, entry := range entries {
		resolved, err := filepath.EvalSymlinks(filepath.Join(certs, entry.Name()))
		if err != nil {
			continue
		}
		guest := strings.TrimPrefix(resolved, hostRoot)
		dir := filepath.Dir(guest)
		if strings.HasPrefix(guest+"/", "/etc/ssl/certs/") || isSystemPath(guest) ||
			strings.Count(dir, string(filepath.Separator)) < 2 || exposesHostCredentials(dir) {
			continue
		}
		dirs = append(dirs, dir)
	}
	sort.Strings(dirs)
	var args []string
	var last string
	for _, dir := range dirs {
		if last != "" && (dir == last || strings.HasPrefix(dir, last+string(filepath.Separator))) {
			continue
		}
		last = dir
		args = append(args, "--ro-bind", filepath.Join(hostRoot, dir), dir)
	}
	return args
}

var providerCredentialFiles = map[string][]string{
	"pi":       {".pi/agent/auth.json", ".pi/agent/models.json"},
	"claude":   {".claude/.credentials.json"},
	"codex":    {".codex/auth.json"},
	"opencode": {".local/share/opencode/auth.json"},
	"copilot":  {".config/github-copilot/hosts.json"},
}

// exposesHostCredentials reports whether binding path read-only would expose
// the host home or any provider credential file. Unknown home is treated as
// exposed so no host directory is mounted without a proven-safe check.
func exposesHostCredentials(path string) bool {
	home, err := os.UserHomeDir()
	if err != nil {
		return true
	}
	targets := []string{home}
	for _, files := range providerCredentialFiles {
		for _, relative := range files {
			targets = append(targets, filepath.Join(home, relative))
		}
	}
	for _, target := range targets {
		rel, err := filepath.Rel(path, target)
		if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func (p *Policy) mountAgentCredentials(executable, home string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return errors.New(Name + ": execution policy is unavailable")
	}
	files := providerCredentialFiles[executable]
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
	privateHead, err := p.privateGit("rev-parse", "HEAD")
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
	if _, err := p.privateGit("fetch", "--no-write-fetch-head", "--no-tags", p.workDir, hostHead); err != nil {
		return fmt.Errorf("%s: import host execution-copy objects into private Git: %w", Name, err)
	}
	if _, err := p.privateGit("merge-base", "--is-ancestor", privateHead, hostHead); err == nil {
		if _, err := p.privateGit("update-ref", "refs/heads/drill-execution", hostHead, privateHead); err != nil {
			return fmt.Errorf("%s: import host execution-copy commit into private Git: %w", Name, err)
		}
		if _, err := p.privateGit("reset", "--mixed", hostHead); err != nil {
			return fmt.Errorf("%s: refresh private Git index: %w", Name, err)
		}
		p.syncedHead = hostHead
		return nil
	}
	if _, err := p.privateGit("merge-base", "--is-ancestor", hostHead, privateHead); err != nil {
		if privateHead != p.syncedHead {
			return fmt.Errorf("%s: host and private Git histories diverged", Name)
		}
		if _, err := p.privateGit("update-ref", "refs/heads/drill-execution", hostHead, privateHead); err != nil {
			return fmt.Errorf("%s: align private Git after host history rewrite: %w", Name, err)
		}
		if _, err := p.privateGit("reset", "--mixed", hostHead); err != nil {
			return fmt.Errorf("%s: refresh private Git index after host history rewrite: %w", Name, err)
		}
		p.syncedHead = hostHead
		return nil
	}
	if err := p.verifyPrivateGit(); err != nil {
		return err
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

// OnClose registers stop to run when the policy closes, before the execution
// metadata and every copied launch home are removed.
func (p *Policy) OnClose(stop func()) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closing || p.closed {
		return errors.New(Name + ": execution policy is unavailable")
	}
	p.onClose = append(p.onClose, stop)
	return nil
}

// Close stops registered owners, then removes task-private Git objects,
// execution metadata, and all copied provider credentials.
func (p *Policy) Close() error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	if p.closing {
		p.mu.Unlock()
		return nil
	}
	p.closing = true
	stops := p.onClose
	p.onClose = nil
	p.mu.Unlock()
	for i := len(stops) - 1; i >= 0; i-- {
		stops[i]()
	}
	p.syncMu.Lock()
	defer p.syncMu.Unlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
	return os.RemoveAll(p.root)
}

func gitOutput(dir string, args ...string) (string, error) {
	argv := append([]string{
		"-c", "core.hooksPath=/dev/null",
		"-c", "core.fsmonitor=false",
		"-c", "protocol.allow=never",
		"-c", "protocol.file.allow=always",
		"-c", "protocol.ext.allow=never",
		"-c", "protocol.ssh.allow=never",
		"-c", "protocol.git.allow=never",
		"-c", "protocol.http.allow=never",
		"-c", "protocol.https.allow=never",
		"-c", "protocol.ftp.allow=never",
		"-c", "protocol.ftps.allow=never",
	}, args...)
	cmd := exec.Command("git", argv...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = append(os.Environ(),
		"GIT_TERMINAL_PROMPT=0",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_CONFIG_GLOBAL=/dev/null",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %s: %w", strings.Join(args, " "), strings.TrimSpace(string(out)), err)
	}
	return strings.TrimSpace(string(out)), nil
}

func fileDigest(path string) ([sha256.Size]byte, error) {
	var digest [sha256.Size]byte
	data, err := os.ReadFile(path)
	if err != nil {
		return digest, err
	}
	return sha256.Sum256(data), nil
}

// privateGit runs a host-side command against the task-private Git database
// only after proving the database still carries the sealed control files the
// policy created, so a writable-control-file regression cannot redirect host
// Git into executing repository-authored programs.
func (p *Policy) privateGit(args ...string) (string, error) {
	if err := p.verifyPrivateGit(); err != nil {
		return "", err
	}
	return gitOutput(p.gitDir, args...)
}

func (p *Policy) verifyPrivateGit() error {
	commondir, err := os.ReadFile(filepath.Join(p.gitDir, "commondir"))
	if err != nil || len(strings.TrimSpace(string(commondir))) != 0 {
		return fmt.Errorf("%s: task-private Git common directory was redirected", Name)
	}
	for _, name := range sealedObjectStorageFiles {
		data, err := os.ReadFile(filepath.Join(p.gitDir, "objects", "info", name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil || len(strings.TrimSpace(string(data))) != 0 {
			return fmt.Errorf("%s: task-private Git object storage was redirected", Name)
		}
	}
	digest, err := fileDigest(filepath.Join(p.gitDir, "config"))
	if err != nil || digest != p.configDigest {
		return fmt.Errorf("%s: task-private Git configuration was modified", Name)
	}
	return nil
}
