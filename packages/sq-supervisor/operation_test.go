package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMain lets the test binary act as the unit's helper, exactly as
// systemd-run would start it.
func TestMain(m *testing.M) {
	if helperEntry(os.Args[1:], os.Getenv("SQ_SUPERVISOR_EXEC_ENV_CHILD")) {
		os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
	}
	os.Exit(m.Run())
}

func helperEntry(args []string, envMarker string) bool {
	if len(args) > 0 && args[0] == envRelayMode {
		return true
	}
	return envMarker == "1"
}

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
// manager must receive the caller's working directory and a path to the
// caller's recorded environment, never the values themselves.
func TestOperationSpecRelaysTheCallersEnvironmentAndDirectory(t *testing.T) {
	dir := t.TempDir()
	const sentinel = "relayed value %p\nwith \"quotes\" and $HOME"
	t.Setenv("SQ_SUPERVISOR_RELAY_PROBE", sentinel)
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
	wantEnvFile := filepath.Join(dir, "relay.env")
	if m.spec.EnvironmentFile != wantEnvFile {
		t.Fatalf("environment file = %q, want %q", m.spec.EnvironmentFile, wantEnvFile)
	}
	if m.spec.Helper == "" {
		t.Error("the unit must start the helper that exec()s the operation")
	}
	if m.envFileMode != 0o600 {
		t.Errorf("the environment file mode = %o, want 0600", m.envFileMode)
	}
	if !strings.Contains(string(m.envFileBody), "SQ_SUPERVISOR_RELAY_PROBE="+sentinel+"\x00") {
		t.Errorf("the environment file does not relay the caller's value byte-exactly: %q", m.envFileBody)
	}
	// No environment value may be visible on the manager's command line.
	argv := strings.Join(m.spec.Command, "\x00")
	for _, fragment := range []string{"relayed value", "%p", "$HOME", "quotes"} {
		if strings.Contains(argv, fragment) {
			t.Errorf("the operation argv carries an environment value (%q): %q", fragment, m.spec.Command)
		}
	}
	if strings.Join(m.spec.Command, " ") != "/bin/true" {
		t.Errorf("command = %q, want the caller's argv", m.spec.Command)
	}
	if !m.spec.NoExpandEnv {
		t.Error("a manager that supports --expand-environment=no must be told to stop expanding the caller's argv")
	}
}

// The recorded environment must reach the operation byte-exactly, including the
// `%` specifiers and newlines a value can legitimately contain, and the file
// must not outlive the launch.
func TestEnvironmentFileRelaysValuesByteExactToTheChild(t *testing.T) {
	dir := t.TempDir()
	envFile := filepath.Join(dir, "child.env")
	tricky := "50% %p %40\nsecond line ' \" $HOME ${not-a-var}"
	if err := writeEnvironmentFile(envFile, []string{
		"SQ_RELAY_TRICKY=" + tricky,
		"PATH=" + os.Getenv("PATH"),
	}); err != nil {
		t.Fatalf("writeEnvironmentFile: %v", err)
	}
	cmd := exec.Command(os.Args[0], envRelayMode, envFile, "sh", "-c", `printf '%s' "$SQ_RELAY_TRICKY"`)
	cmd.Env = []string{"SQ_SUPERVISOR_EXEC_ENV_CHILD=1"}
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("the relayed child failed: %v", err)
	}
	if string(out) != tricky {
		t.Fatalf("child saw %q, want %q", out, tricky)
	}
	if _, err := os.Stat(envFile); !os.IsNotExist(err) {
		t.Fatalf("the environment file must be unlinked once the unit starts, stat err = %v", err)
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

// The durable record is what a later recovery reads, so its own fields - not a
// second read of itself - must carry the reported outcome.
func TestDurableOutcomeRecordMatchesReportedOutcome(t *testing.T) {
	dir := t.TempDir()
	m := &fakeManager{
		version:    "262.1-1-arch",
		startDelay: 5 * time.Millisecond,
		state:      unitState{LoadState: "loaded", ActiveState: "inactive", Result: "success"},
	}
	oc, code, _ := runFake(t, m, "durable", dir)
	if code != exitCompleted {
		t.Fatalf("exit = %d, want %d", code, exitCompleted)
	}
	wantPath := filepath.Join(dir, "durable.outcome.json")
	if oc.OutcomeRecord != wantPath {
		t.Errorf("outcome_record = %q, want the durable %q", oc.OutcomeRecord, wantPath)
	}
	if oc.DurationMS <= 0 {
		t.Errorf("duration_ms = %d, want the measured duration", oc.DurationMS)
	}
	if oc.State != stateCompleted {
		t.Errorf("state = %q, want %q", oc.State, stateCompleted)
	}
	if oc.ExitCode == nil || *oc.ExitCode != 0 {
		t.Errorf("exit_code = %v, want the command's own 0", oc.ExitCode)
	}
}
