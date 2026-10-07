//go:build unix

package pipeline

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

// stepProcessState reports whether pid is still alive and, when it can be
// read, its raw process state (e.g. "R", "S", "Z"). A zombie ("Z"-prefixed
// stat state) is reported as not alive: its agent has already exited and
// nothing will ever resume progress, even though its pid has not been
// reaped yet. A pid owned by another user (EPERM) is reported alive since
// drill could not have started it and has no basis to call it dead; an
// unreadable stat after a successful signal probe is the same - kill(pid, 0)
// just proved the pid exists, so a failed stat read is treated as a
// transient race with exit rather than invented evidence.
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
	stat, statErr := stepProcessStatState(pid)
	if statErr != nil {
		return true, "", nil
	}
	if strings.HasPrefix(stat, "Z") {
		return false, stat, nil
	}
	return true, stat, nil
}

func stepProcessStatState(pid int) (string, error) {
	cmd := exec.Command(stepPSExecutable(), "-p", fmt.Sprintf("%d", pid), "-o", "stat=")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func stepPSExecutable() string {
	if path, err := exec.LookPath("ps"); err == nil {
		return path
	}
	return "ps"
}
