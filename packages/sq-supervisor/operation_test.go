package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runFake(t *testing.T, m manager, operationID, stateDir string) (outcome, int, string) {
	t.Helper()
	previous := newManager
	t.Cleanup(func() { newManager = previous })
	newManager = func(io.Writer, io.Writer) manager { return m }

	var stdout, stderr strings.Builder
	code := run([]string{
		"run",
		"--operation-id", operationID,
		"--state-dir", stateDir,
		"--deadline", "5s",
		"--stop-grace", "1s",
		"--", "/bin/true",
	}, &stdout, &stderr)
	body, err := os.ReadFile(filepath.Join(stateDir, operationID+".outcome.json"))
	if err != nil {
		t.Fatalf("read the outcome record: %v (stdout=%q stderr=%q)", err, stdout.String(), stderr.String())
	}
	var oc outcome
	if err := json.Unmarshal(body, &oc); err != nil {
		t.Fatalf("outcome record is not JSON: %v (%q)", err, body)
	}
	if stdout.Len() != 0 {
		t.Fatalf("the runner must not print its own output on stdout, got %q", stdout.String())
	}
	return oc, code, stderr.String()
}

// A contained operation is a drop-in for the caller's own command, so the
// manager must receive the caller's environment and working directory rather
// than a clean execution environment.
func TestOperationSpecRelaysTheCallersEnvironmentAndDirectory(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SQ_SUPERVISOR_RELAY_PROBE", "relayed value")
	m := &fakeManager{
		version: "262.1-1-arch",
		state:   unitState{LoadState: "loaded", ActiveState: "inactive", Result: "success"},
	}
	if _, code, _ := runFake(t, m, "relay", dir); code != exitCompleted {
		t.Fatalf("exit = %d, want %d", code, exitCompleted)
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getcwd: %v", err)
	}
	if m.spec.WorkingDirectory != cwd {
		t.Errorf("working directory = %q, want the caller's %q", m.spec.WorkingDirectory, cwd)
	}
	found := false
	for _, assignment := range m.spec.Environment {
		if assignment == "SQ_SUPERVISOR_RELAY_PROBE=relayed value" {
			found = true
		}
	}
	if !found {
		t.Errorf("the caller's environment was not relayed; got %d assignments", len(m.spec.Environment))
	}
	if !m.spec.NoExpandEnv {
		t.Error("a manager that supports --expand-environment=no must be told to stop expanding the caller's argv")
	}
	if strings.Join(m.spec.Command, " ") != "/bin/true" {
		t.Errorf("command = %q, want the caller's argv", m.spec.Command)
	}
}

// relayableEnvironment is the boundary between the caller's environment and a
// manager that rejects names it cannot represent.
func TestRelayableEnvironmentKeepsEveryOrdinaryAssignment(t *testing.T) {
	got := relayableEnvironment([]string{
		"PATH=/usr/bin",
		"HOME=/home/user",
		"with_1=value=with=equals",
		"BASH_FUNC_probe%%=() { :; }",
		"1LEADING=bad",
		"no separator",
		"=empty",
	})
	want := []string{"PATH=/usr/bin", "HOME=/home/user", "with_1=value=with=equals"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("relayed environment = %q, want %q", got, want)
	}
}

// A completed operation must keep the caller's own non-zero status, and it must
// not be re-printed by the runner on stdout.
func TestCompletedOperationReportsItsOwnStatus(t *testing.T) {
	dir := t.TempDir()
	m := &fakeManager{
		version:  "262.1-1-arch",
		startRes: commandResult{ExitCode: 42},
		state:    unitState{LoadState: "loaded", ActiveState: "failed", Result: "exit-code", ExecMainStatus: 42},
	}
	oc, code, _ := runFake(t, m, "own-status", dir)
	if code != exitCompleted {
		t.Fatalf("exit = %d, want %d", code, exitCompleted)
	}
	if oc.ExitCode == nil || *oc.ExitCode != 42 {
		t.Fatalf("reported exit = %v, want the command's own 42", oc.ExitCode)
	}
}

// The manager and the operation share their streams under --pipe, so a streamed
// tail cannot be attributed to the manager and must never be copied into the
// durable record as the operation's command output.
func TestStreamedOutputIsNotCopiedIntoTheOutcome(t *testing.T) {
	dir := t.TempDir()
	leaked := "a line the command wrote that belongs only on its own stderr"
	m := &fakeManager{
		version:  "262.1-1-arch",
		startRes: commandResult{ExitCode: 1, Stderr: leaked},
		state:    unitState{LoadState: "not-found"},
	}
	oc, code, _ := runFake(t, m, "diagnostic", dir)
	if code != exitUnknownResult {
		t.Fatalf("exit = %d, want %d", code, exitUnknownResult)
	}
	if strings.Contains(oc.Detail, leaked) {
		t.Fatalf("detail = %q, want the operation's output kept out of the record", oc.Detail)
	}
}

// A manager call that never returned is its own cause, and it must survive into
// the record even when the unit is already gone.
func TestStartFailureCauseReachesTheOutcome(t *testing.T) {
	dir := t.TempDir()
	m := &fakeManager{
		version:  "262.1-1-arch",
		startErr: context.DeadlineExceeded,
		state:    unitState{LoadState: "not-found"},
	}
	oc, code, _ := runFake(t, m, "start-failure", dir)
	if code != exitUnknownResult {
		t.Fatalf("exit = %d, want %d", code, exitUnknownResult)
	}
	if !strings.Contains(oc.Detail, context.DeadlineExceeded.Error()) {
		t.Fatalf("detail = %q, want it to carry the start failure", oc.Detail)
	}
}

// The durable record is what a later recovery reads, so it must agree with the
// object the caller was handed.
func TestDurableOutcomeRecordMatchesReportedOutcome(t *testing.T) {
	dir := t.TempDir()
	m := &fakeManager{
		version: "262.1-1-arch",
		state:   unitState{LoadState: "loaded", ActiveState: "inactive", Result: "success"},
	}
	oc, code, _ := runFake(t, m, "durable", dir)
	if code != exitCompleted {
		t.Fatalf("exit = %d, want %d", code, exitCompleted)
	}
	if oc.OutcomeRecord == "" {
		t.Fatal("the reported outcome must name its durable record")
	}
	body, err := os.ReadFile(oc.OutcomeRecord)
	if err != nil {
		t.Fatalf("read the durable outcome: %v", err)
	}
	var durable outcome
	if err := json.Unmarshal(body, &durable); err != nil {
		t.Fatalf("the durable outcome is not JSON: %v", err)
	}
	if durable.OutcomeRecord != oc.OutcomeRecord {
		t.Errorf("durable outcome_record = %q, want %q", durable.OutcomeRecord, oc.OutcomeRecord)
	}
	if durable.DurationMS != oc.DurationMS {
		t.Errorf("durable duration_ms = %d, want the reported %d", durable.DurationMS, oc.DurationMS)
	}
}
