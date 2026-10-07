//go:build linux

package pipeline

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestStepProcessState_DetectsZombieWhenPSUnavailable proves the zombie
// detection does not depend on the ps binary: with ps pointed at a path that
// cannot exist, the Linux probe still reads /proc/<pid>/stat and reports the
// unreaped child as a zombie.
func TestStepProcessState_DetectsZombieWhenPSUnavailable(t *testing.T) {
	cmd := exec.Command("true")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start zombie: %v", err)
	}
	defer cmd.Wait()

	prev := stepPSExecutable
	stepPSExecutable = func() string { return filepath.Join(t.TempDir(), "missing-ps") }
	defer func() { stepPSExecutable = prev }()

	deadline := time.Now().Add(3 * time.Second)
	for {
		alive, state, err := stepProcessState(cmd.Process.Pid)
		if err != nil {
			t.Fatalf("stepProcessState: %v", err)
		}
		if !alive && strings.HasPrefix(state, "Z") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("zombie pid %d not detected via /proc with ps unavailable: alive=%v state=%q", cmd.Process.Pid, alive, state)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
