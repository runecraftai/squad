package main

import (
	"context"
	"errors"
	"fmt"
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
	Unit      string
	Deadline  time.Duration
	StopGrace time.Duration
	Stdout    string
	Stderr    string
	Command   []string
}

// unitState is the manager's own record of how the unit ended.
type unitState struct {
	LoadState      string
	ActiveState    string
	Result         string
	ExecMainCode   int
	ExecMainStatus int
}

// boundedRunner runs a program with the caller's context as the only deadline.
func boundedRunner(ctx context.Context, name string, args []string, env []string) (commandResult, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	res := commandResult{Stdout: out.String(), Stderr: errb.String()}
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

// systemdManager is the real manager: systemd --user transient services.
type systemdManager struct {
	run commandRunner
}

func newSystemdManager() *systemdManager {
	return &systemdManager{run: boundedRunner}
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
	args := []string{
		"--user",
		"--unit=" + spec.Unit,
		"--quiet",
		"--wait",
		"--property=Type=exec",
		"--property=KillMode=control-group",
		"--property=SendSIGKILL=yes",
		"--property=RuntimeMaxSec=" + durationSpec(spec.Deadline),
		"--property=TimeoutStopSec=" + durationSpec(spec.StopGrace),
		"--property=CollectMode=inactive",
		"--property=StandardOutput=truncate:" + spec.Stdout,
		"--property=StandardError=truncate:" + spec.Stderr,
		"--",
	}
	args = append(args, spec.Command...)
	return m.run(ctx, "systemd-run", args, nil)
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
