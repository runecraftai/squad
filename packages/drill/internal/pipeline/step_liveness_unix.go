//go:build unix

package pipeline

import (
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"syscall"
)

// stepProcessStat reads the raw process state through the first source that
// can answer (on Linux /proc/<pid>/stat, elsewhere ps). It is a variable so
// the unreadable-state path can be exercised in tests.
var stepProcessStat = stepProcessStatState

// stepProcessState reports whether pid is still alive and, when it can be
// read, its raw process state (e.g. "R", "S", "Z"). A zombie ("Z"-prefixed
// stat state) is reported as not alive: its agent has already exited and
// nothing will ever resume progress, even though its pid has not been reaped
// yet. A pid owned by another user (EPERM) is reported alive since drill
// could not have started it and has no basis to call it dead. When the pid
// exists but its state cannot be read through any available source, it is
// reported not alive and logged: an unreadable state is not proof of life,
// and treating it as one would leave the indefinite hang this probe exists
// to detect.
func stepProcessState(pid int) (alive bool, state string, err error) {
	if pid <= 0 {
		return false, "", nil
	}
	if sigErr := syscall.Kill(pid, 0); sigErr != nil {
		if errors.Is(sigErr, syscall.ESRCH) {
			return false, "gone", nil
		}
		if errors.Is(sigErr, syscall.EPERM) {
			return true, "unknown", nil
		}
		return true, "", sigErr
	}
	stat, statErr := stepProcessStat(pid)
	if statErr != nil {
		slog.Warn("step liveness probe could not read process state; treating pid as not alive", "pid", pid, "error", statErr)
		return false, "unreadable", nil
	}
	if stat == "" {
		slog.Warn("step liveness probe read no process state; treating pid as not alive", "pid", pid)
		return false, "unreadable", nil
	}
	if strings.HasPrefix(stat, "Z") {
		return false, stat, nil
	}
	return true, stat, nil
}

func stepPSStatState(pid int) (string, error) {
	cmd := exec.Command(stepPSExecutable(), "-p", fmt.Sprintf("%d", pid), "-o", "stat=")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

var stepPSExecutable = func() string {
	if path, err := exec.LookPath("ps"); err == nil {
		return path
	}
	return "ps"
}
