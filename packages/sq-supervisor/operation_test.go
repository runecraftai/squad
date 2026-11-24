package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runFake(t *testing.T, m manager, operationID, stateDir, stdoutPath, stderrPath string) (outcome, int, string) {
	t.Helper()
	previous := newManager
	t.Cleanup(func() { newManager = previous })
	newManager = func() manager { return m }

	var stdout, stderr strings.Builder
	code := run([]string{
		"run",
		"--operation-id", operationID,
		"--state-dir", stateDir,
		"--deadline", "5s",
		"--stop-grace", "1s",
		"--stdout", stdoutPath,
		"--stderr", stderrPath,
		"--", "/bin/true",
	}, &stdout, &stderr)
	var oc outcome
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout.String())), &oc); err != nil {
		t.Fatalf("outcome is not JSON: %v (stdout=%q stderr=%q)", err, stdout.String(), stderr.String())
	}
	return oc, code, stderr.String()
}

// A relative stream path is accepted by the flag set but rejected by systemd, so
// it must be caught before anything is launched.
func TestRelativeStreamPathsAreUsageErrors(t *testing.T) {
	dir := t.TempDir()
	var stdout, stderr strings.Builder
	code := run([]string{
		"run",
		"--operation-id", "relative",
		"--state-dir", dir,
		"--deadline", "5s",
		"--stop-grace", "1s",
		"--stdout", "out",
		"--stderr", filepath.Join(dir, "err"),
		"--", "/bin/true",
	}, &stdout, &stderr)
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "absolute") {
		t.Errorf("the usage error must name the absolute-path requirement, got %q", stderr.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "relative.intent.json")); err == nil {
		t.Fatal("a usage error must not leave an intent record")
	}
}

// The manager's own launch diagnostic is the only operator-visible cause when a
// unit never starts, so it must reach the outcome rather than be discarded.
func TestStartDiagnosticReachesTheOutcome(t *testing.T) {
	dir := t.TempDir()
	diagnostic := "Failed to start transient service unit: Standard output type file requires an absolute path"
	m := &fakeManager{
		version:  "262.1-1-arch",
		startRes: commandResult{ExitCode: 1, Stderr: diagnostic},
		state:    unitState{LoadState: "not-found"},
	}
	oc, code, _ := runFake(t, m, "diagnostic", dir, filepath.Join(dir, "out"), filepath.Join(dir, "err"))
	if code != exitUnknownResult {
		t.Fatalf("exit = %d, want %d", code, exitUnknownResult)
	}
	if !strings.Contains(oc.Detail, diagnostic) {
		t.Fatalf("detail = %q, want it to quote the manager diagnostic", oc.Detail)
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
	oc, code, _ := runFake(t, m, "durable", dir, filepath.Join(dir, "out"), filepath.Join(dir, "err"))
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
