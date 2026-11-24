package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// commandResult is one bounded external invocation of a manager program.
type commandResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// commandRunner runs one manager program. Tests inject a fake so the exact
// argv this binary would hand systemd is assertable without a live manager.
type commandRunner func(ctx context.Context, name string, args []string, env []string) (commandResult, error)

// manager is the operation's kernel-ownership authority.
type manager interface {
	// Version reports the user manager version, or an error when strict Linux
	// mode cannot be honoured on this host.
	Version(ctx context.Context) (string, error)
	// Start launches the operation and blocks until the unit is gone or ctx ends.
	Start(ctx context.Context, spec unitSpec) (commandResult, error)
	// Show reads the unit's durable completion record.
	Show(ctx context.Context, unit string) (unitState, error)
	// ControlGroup reports the unit's cgroup path while it is active.
	ControlGroup(ctx context.Context, unit string) (string, error)
	// Forget removes a failed unit so it cannot collide with a later operation.
	Forget(ctx context.Context, unit string) error
}

// unitSpec is one transient service definition. Every field here is part of the
// containment contract: the group is killed as a unit, never as a process group.
type unitSpec struct {
	Unit             string
	Deadline         time.Duration
	StopGrace        time.Duration
	WorkingDirectory string
	Environment      []string
	NoExpandEnv      bool
	Command          []string
}

// unitState is the manager's own record of how the unit ended.
type unitState struct {
	LoadState      string
	ActiveState    string
	Result         string
	ExecMainCode   int
	ExecMainStatus int
}

// commandFor builds one manager program invocation with the caller's streams.
func commandFor(ctx context.Context, name string, args, env []string, stdout, stderr io.Writer) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd
}

func finishRun(ctx context.Context, name string, cmd *exec.Cmd) (commandResult, error) {
	var res commandResult
	err := cmd.Run()
	if err == nil {
		return res, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		res.ExitCode = exitErr.ExitCode()
		return res, nil
	}
	// A context deadline is reported as an error and never as an exit status,
	// so a manager call that never answered cannot be read as a refusal.
	if ctxErr := ctx.Err(); ctxErr != nil {
		return res, fmt.Errorf("%s: %w", name, ctxErr)
	}
	return res, fmt.Errorf("%s: %w", name, err)
}

// boundedRunner runs a program with the caller's context as the only deadline.
func boundedRunner(ctx context.Context, name string, args []string, env []string) (commandResult, error) {
	var out, errb strings.Builder
	res, err := finishRun(ctx, name, commandFor(ctx, name, args, env, &out, &errb))
	res.Stdout = out.String()
	res.Stderr = errb.String()
	return res, err
}

// streamRunner runs the operation's own manager call with the caller's streams
// attached, so the operation's stdout and stderr are relayed as they are
// produced. The manager speaks through those same streams under --pipe, so the
// relayed bytes cannot be attributed to the manager and are never kept here.
func streamRunner(ctx context.Context, name string, args []string, stdout, stderr io.Writer) (commandResult, error) {
	return finishRun(ctx, name, commandFor(ctx, name, args, nil, stdout, stderr))
}

// systemdManager is the real manager: systemd --user transient services.
type systemdManager struct {
	run    commandRunner
	stdout io.Writer
	stderr io.Writer
}

func newSystemdManager(stdout, stderr io.Writer) *systemdManager {
	return &systemdManager{run: boundedRunner, stdout: stdout, stderr: stderr}
}

// Version proves the host can honour strict Linux mode. It requires Linux, a
// booted systemd (its runtime marker), and an answering user bus; a host that
// merely has the binaries installed is not a manager.
func (m *systemdManager) Version(ctx context.Context) (string, error) {
	if !strictPlatform() {
		return "", fmt.Errorf("strict Linux mode requires linux with a systemd user manager; this host is %s", platformName())
	}
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return "", fmt.Errorf("strict Linux mode requires a booted systemd (/run/systemd/system is absent)")
	}
	res, err := m.run(ctx, "systemctl", []string{"--user", "show", "-p", "Version", "--value"}, nil)
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(res.Stdout)
	if res.ExitCode != 0 || v == "" {
		detail := strings.TrimSpace(res.Stderr)
		if detail == "" {
			detail = "no version reported"
		}
		return "", fmt.Errorf("strict Linux mode requires a working systemd user manager (%s)", detail)
	}
	return v, nil
}

// Start launches the transient service and waits for the manager to finish with
// it. The service is created inactive-collected rather than collected outright:
// a collected unit loses Result and ExecMainStatus, which are the only durable
// proof of how the operation ended.
func (m *systemdManager) Start(ctx context.Context, spec unitSpec) (commandResult, error) {
	return streamRunner(ctx, "systemd-run", startArgs(spec), m.stdout, m.stderr)
}

// startArgs spells the transient service. A contained operation must be a drop-in
// for the caller's own command, so it runs in the caller's working directory,
// with the caller's environment, and with its streams connected to the caller's
// through --pipe rather than to manager-opened files.
func startArgs(spec unitSpec) []string {
	args := []string{
		"--user",
		"--unit=" + spec.Unit,
		"--quiet",
		"--wait",
		"--pipe",
		"--property=Type=exec",
		"--property=KillMode=control-group",
		"--property=SendSIGKILL=yes",
		"--property=RuntimeMaxSec=" + durationSpec(spec.Deadline),
		"--property=TimeoutStopSec=" + durationSpec(spec.StopGrace),
		"--property=CollectMode=inactive",
		"--property=WorkingDirectory=" + spec.WorkingDirectory,
	}
	if spec.NoExpandEnv {
		args = append(args, "--expand-environment=no")
	}
	for _, assignment := range spec.Environment {
		args = append(args, "--setenv="+assignment)
	}
	args = append(args, "--")
	return append(args, spec.Command...)
}

// Show reads the unit's completion record. Every property is requested in one
// call so the record is one consistent read, not four racing ones.
func (m *systemdManager) Show(ctx context.Context, unit string) (unitState, error) {
	res, err := m.run(ctx, "systemctl", []string{
		"--user", "show", unit,
		"-p", "LoadState",
		"-p", "ActiveState",
		"-p", "Result",
		"-p", "ExecMainCode",
		"-p", "ExecMainStatus",
	}, nil)
	if err != nil {
		return unitState{}, err
	}
	if res.ExitCode != 0 {
		return unitState{}, fmt.Errorf("reading the unit result failed: %s", strings.TrimSpace(res.Stderr))
	}
	return parseUnitState(res.Stdout), nil
}

func (m *systemdManager) ControlGroup(ctx context.Context, unit string) (string, error) {
	res, err := m.run(ctx, "systemctl", []string{"--user", "show", unit, "-p", "ControlGroup", "--value"}, nil)
	if err != nil {
		return "", err
	}
	if res.ExitCode != 0 {
		return "", fmt.Errorf("reading the unit control group failed: %s", strings.TrimSpace(res.Stderr))
	}
	return strings.TrimSpace(res.Stdout), nil
}

func (m *systemdManager) Forget(ctx context.Context, unit string) error {
	_, err := m.run(ctx, "systemctl", []string{"--user", "reset-failed", unit}, nil)
	return err
}

func parseUnitState(out string) unitState {
	var st unitState
	for _, line := range strings.Split(out, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch key {
		case "LoadState":
			st.LoadState = value
		case "ActiveState":
			st.ActiveState = value
		case "Result":
			st.Result = value
		case "ExecMainCode":
			st.ExecMainCode, _ = strconv.Atoi(value)
		case "ExecMainStatus":
			st.ExecMainStatus, _ = strconv.Atoi(value)
		}
	}
	return st
}

// supportsExpandEnvironment reports whether this manager understands
// --expand-environment=no, which systemd gained in version 254. Older managers
// expand `$VAR` text inside the command's own arguments before the command sees
// it, so that limit is stated in the tool contract rather than assumed away.
func supportsExpandEnvironment(version string) bool {
	digits := 0
	for digits < len(version) && version[digits] >= '0' && version[digits] <= '9' {
		digits++
	}
	if digits == 0 {
		return false
	}
	major, err := strconv.Atoi(version[:digits])
	if err != nil {
		return false
	}
	return major >= 254
}

// durationSpec spells a duration the way systemd's time parser accepts it.
func durationSpec(d time.Duration) string {
	if d <= 0 {
		return "infinity"
	}
	// systemd reads a bare number as seconds, which is unambiguous and keeps the
	// property readable in `systemctl show` output.
	if d%time.Second == 0 {
		return strconv.Itoa(int(d/time.Second)) + "s"
	}
	return fmt.Sprintf("%.3fs", d.Seconds())
}

// cgroupRootDir is the unified cgroup v2 mount the manager's unit paths live
// under on a host that can honour strict Linux mode.
const cgroupRootDir = "/sys/fs/cgroup"

// cgroupMembers lists the pids still in a unit cgroup. A path the kernel has
// already removed is empty by construction.
func cgroupMembers(cgroupPath string) ([]int, bool, error) {
	return cgroupMembersAt(cgroupRootDir, cgroupPath)
}

func cgroupMembersAt(root, cgroupPath string) ([]int, bool, error) {
	if cgroupPath == "" {
		return nil, false, nil
	}
	body, err := os.ReadFile(filepath.Join(root, cgroupPath, "cgroup.procs"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, false, nil
		}
		return nil, false, err
	}
	var pids []int
	for _, field := range strings.Fields(string(body)) {
		pid, convErr := strconv.Atoi(field)
		if convErr != nil {
			continue
		}
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	return pids, true, nil
}
