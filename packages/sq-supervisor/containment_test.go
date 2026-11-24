package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// requireManager skips the suite's real-containment cases on a host that cannot
// honour strict Linux mode. It never fakes the guarantee.
func requireManager(t *testing.T) string {
	t.Helper()
	if !strictPlatform() {
		t.Skip("strict Linux mode requires linux")
	}
	ctx, cancel := context.WithTimeout(context.Background(), managerProbeBound)
	defer cancel()
	version, err := newSystemdManager().Version(ctx)
	if err != nil {
		t.Skipf("systemd user manager unavailable: %v", err)
	}
	return version
}

func runContained(t *testing.T, stateDir string, deadline, grace time.Duration, script string, args ...string) (outcome, int) {
	t.Helper()
	stdoutPath := filepath.Join(stateDir, "stdout.txt")
	stderrPath := filepath.Join(stateDir, "stderr.txt")
	argv := append([]string{
		"run",
		"--operation-id", "test-" + strconv.FormatInt(time.Now().UnixNano(), 36),
		"--state-dir", stateDir,
		"--deadline", deadline.String(),
		"--stop-grace", grace.String(),
		"--stdout", stdoutPath,
		"--stderr", stderrPath,
		"--", script,
	}, args...)
	var stdout, stderr strings.Builder
	code := run(argv, &stdout, &stderr)
	var oc outcome
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout.String())), &oc); err != nil {
		t.Fatalf("outcome is not JSON: %v (stdout=%q stderr=%q)", err, stdout.String(), stderr.String())
	}
	return oc, code
}

func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	// Signal 0 probes existence without affecting the process.
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// TestContainmentSurvivesSecondSessionAndGroup is the incident case: a backend
// forks a TERM-resistant descendant into its own session and process group, so a
// shell process-group kill cannot reach it. The cgroup must still take it.
func TestContainmentSurvivesSecondSessionAndGroup(t *testing.T) {
	requireManager(t)
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "descendant.pid")
	body := fmt.Sprintf(`#!/bin/bash
setsid bash -c 'trap "" TERM; exec sleep 300' &
echo "$!" > %q
trap "" TERM
sleep 300
`, pidFile)
	script := filepath.Join(dir, "backend.sh")
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write backend: %v", err)
	}

	started := time.Now()
	oc, code := runContained(t, dir, 2*time.Second, 2*time.Second, script)
	elapsed := time.Since(started)

	descendant, _ := strconv.Atoi(strings.TrimSpace(readFileOrEmpty(pidFile)))
	if descendant == 0 {
		t.Fatalf("the backend never recorded its descendant pid; stderr=%q", readFileOrEmpty(filepath.Join(dir, "stderr.txt")))
	}
	if code != exitTimeout || oc.State != stateTimeout {
		t.Fatalf("state = %q (exit %d), want timeout", oc.State, code)
	}
	if !oc.Contained {
		t.Fatalf("outcome does not prove containment: %+v", oc)
	}
	if len(oc.Survivors) != 0 {
		t.Fatalf("survivors = %v, want none", oc.Survivors)
	}
	if alive(descendant) {
		// Leave no runaway process behind from a failed assertion.
		_ = syscall.Kill(descendant, syscall.SIGKILL)
		t.Fatalf("the TERM-resistant second-session descendant (pid %d) outlived the operation", descendant)
	}
	// RuntimeMaxSec plus TimeoutStopSec, with a bounded margin for manager
	// round-trips. A process group kill cannot even be timed here.
	if elapsed > 20*time.Second {
		t.Fatalf("the operation took %s, want it bounded near the 4s deadline+grace", elapsed)
	}
	if oc.Cgroup == "" {
		t.Fatal("the outcome must record the unit cgroup it proved empty")
	}
	t.Logf("contained by %s on systemd %s in %s; descendant pid %d is gone", oc.Cgroup, oc.Manager, elapsed, descendant)
}

// TestContainmentCoversSecondGroupInSameSession is the round-5 finding: bash job
// control starts a child in a new process group inside the same session.
func TestContainmentCoversSecondGroupInSameSession(t *testing.T) {
	requireManager(t)
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "descendant.pid")
	body := fmt.Sprintf(`#!/bin/bash
set -m
bash -c 'trap "" TERM; exec sleep 300' &
echo "$!" > %q
set +m
trap "" TERM
sleep 300
`, pidFile)
	script := filepath.Join(dir, "backend.sh")
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write backend: %v", err)
	}
	oc, code := runContained(t, dir, 2*time.Second, 2*time.Second, script)
	descendant, _ := strconv.Atoi(strings.TrimSpace(readFileOrEmpty(pidFile)))
	if descendant == 0 {
		t.Fatalf("the backend never recorded its descendant pid; stderr=%q", readFileOrEmpty(filepath.Join(dir, "stderr.txt")))
	}
	if code != exitTimeout || !oc.Contained || len(oc.Survivors) != 0 {
		t.Fatalf("state=%q exit=%d contained=%v survivors=%v", oc.State, code, oc.Contained, oc.Survivors)
	}
	if alive(descendant) {
		_ = syscall.Kill(descendant, syscall.SIGKILL)
		t.Fatalf("the second-group descendant (pid %d) outlived the operation", descendant)
	}
}

// TestCompletedOperationPreservesExitStatus proves the ordinary path: the
// command's own status is reported, and it is not confused with a bound.
func TestCompletedOperationPreservesExitStatus(t *testing.T) {
	requireManager(t)
	dir := t.TempDir()
	script := filepath.Join(dir, "exit42.sh")
	if err := os.WriteFile(script, []byte("#!/bin/bash\necho out line\necho err line >&2\nexit 42\n"), 0o755); err != nil {
		t.Fatalf("write script: %v", err)
	}
	oc, code := runContained(t, dir, 20*time.Second, 2*time.Second, script)
	if code != exitCompleted || oc.State != stateCompleted {
		t.Fatalf("state = %q (exit %d), want completed", oc.State, code)
	}
	if oc.ExitCode == nil || *oc.ExitCode != 42 {
		t.Fatalf("exit code = %v, want the command's own 42", oc.ExitCode)
	}
	if !oc.Contained {
		t.Fatalf("outcome does not prove containment: %+v", oc)
	}
	if got := strings.TrimSpace(readFileOrEmpty(filepath.Join(dir, "stdout.txt"))); got != "out line" {
		t.Errorf("captured stdout = %q", got)
	}
	if got := strings.TrimSpace(readFileOrEmpty(filepath.Join(dir, "stderr.txt"))); got != "err line" {
		t.Errorf("captured stderr = %q", got)
	}
	if _, err := os.Stat(oc.IntentRecord); err != nil {
		t.Errorf("the intent record must survive the operation: %v", err)
	}
	if _, err := os.Stat(oc.OutcomeRecord); err != nil {
		t.Errorf("the outcome record must be durable: %v", err)
	}
}

// TestMissingManagerRefusesBeforeLaunch is D1=O1: strict mode refuses rather than
// silently degrading to a weaker guarantee, and it mutates nothing.
func TestMissingManagerRefusesBeforeLaunch(t *testing.T) {
	previous := newManager
	defer func() { newManager = previous }()
	newManager = func() manager {
		return &fakeManager{versionErr: errors.New("strict Linux mode requires a working systemd user manager (Failed to connect to bus)")}
	}
	dir := t.TempDir()
	marker := filepath.Join(dir, "ran")
	script := filepath.Join(dir, "noop.sh")
	if err := os.WriteFile(script, []byte("#!/bin/bash\ntouch "+marker+"\n"), 0o755); err != nil {
		t.Fatalf("write script: %v", err)
	}
	var stdout, stderr strings.Builder
	code := run([]string{
		"run",
		"--operation-id", "refusal",
		"--state-dir", dir,
		"--deadline", "5s",
		"--stop-grace", "1s",
		"--stdout", filepath.Join(dir, "out"),
		"--stderr", filepath.Join(dir, "err"),
		"--", script,
	}, &stdout, &stderr)

	if code != exitManagerUnavailable {
		t.Fatalf("exit = %d, want %d", code, exitManagerUnavailable)
	}
	var oc outcome
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout.String())), &oc); err != nil {
		t.Fatalf("outcome is not JSON: %v", err)
	}
	if oc.State != stateManagerDisabled || oc.Contained {
		t.Fatalf("outcome = %+v, want an uncontained refusal", oc)
	}
	if !strings.Contains(oc.Detail, "Failed to connect to bus") {
		t.Errorf("the refusal must quote the manager diagnostic, got %q", oc.Detail)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("strict mode launched the command without a manager")
	}
	if _, err := os.Stat(filepath.Join(dir, "refusal.intent.json")); err == nil {
		t.Fatal("a refusal must not leave an intent record for an operation that never started")
	}
}

// TestUnknownResultIsNotRetried proves the "reply lost after the backend accepted
// the action" case: the outcome is unknown, not success, and not a bound.
func TestUnknownResultIsNotRetried(t *testing.T) {
	previous := newManager
	defer func() { newManager = previous }()
	newManager = func() manager {
		return &fakeManager{
			version:  "262.1-1-arch",
			startRes: commandResult{ExitCode: 1},
			state:    unitState{LoadState: "not-found"},
		}
	}
	dir := t.TempDir()
	var stdout, stderr strings.Builder
	code := run([]string{
		"run",
		"--operation-id", "lost",
		"--state-dir", dir,
		"--deadline", "5s",
		"--stop-grace", "1s",
		"--stdout", filepath.Join(dir, "out"),
		"--stderr", filepath.Join(dir, "err"),
		"--", "/bin/true",
	}, &stdout, &stderr)
	if code != exitUnknownResult {
		t.Fatalf("exit = %d, want %d", code, exitUnknownResult)
	}
	var oc outcome
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout.String())), &oc); err != nil {
		t.Fatalf("outcome is not JSON: %v", err)
	}
	if oc.State != stateUnknownResult || oc.ExitCode != nil {
		t.Fatalf("outcome = %+v, want an unknown result with no exit code", oc)
	}
	if _, err := os.Stat(filepath.Join(dir, "lost.intent.json")); err != nil {
		t.Errorf("the intent record is what makes recovery possible: %v", err)
	}
}

func readFileOrEmpty(path string) string {
	body, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(body)
}
