package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// fakeManager replays a scripted unit record, so classification and capture are
// assertable without a live manager.
type fakeManager struct {
	version    string
	versionErr error

	startRes commandResult
	startErr error

	state    unitState
	stateErr error

	cgroup    string
	cgroupErr error

	cgroupCalls int

	forgotten []string
}

func (f *fakeManager) Version(context.Context) (string, error) {
	return f.version, f.versionErr
}

func (f *fakeManager) Start(context.Context, unitSpec) (commandResult, error) {
	return f.startRes, f.startErr
}

func (f *fakeManager) Show(context.Context, string) (unitState, error) {
	return f.state, f.stateErr
}

func (f *fakeManager) ControlGroup(context.Context, string) (string, error) {
	f.cgroupCalls++
	return f.cgroup, f.cgroupErr
}

func (f *fakeManager) Forget(_ context.Context, unit string) error {
	f.forgotten = append(f.forgotten, unit)
	return nil
}

func TestStartPassesTheContainmentContract(t *testing.T) {
	m := newSystemdManager()
	var gotName string
	var gotArgs []string
	m.run = func(_ context.Context, name string, args []string, _ []string) (commandResult, error) {
		gotName = name
		gotArgs = args
		return commandResult{}, nil
	}
	spec := unitSpec{
		Unit:      "sq-op-demo.service",
		Deadline:  30 * time.Second,
		StopGrace: 5 * time.Second,
		Stdout:    "/tmp/out",
		Stderr:    "/tmp/err",
		Command:   []string{"/bin/echo", "hi"},
	}
	if _, err := m.Start(context.Background(), spec); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if gotName != "systemd-run" {
		t.Fatalf("manager program = %q, want systemd-run", gotName)
	}
	joined := strings.Join(gotArgs, " ")
	for _, want := range []string{
		"--user",
		"--unit=sq-op-demo.service",
		"--wait",
		"--property=Type=exec",
		"--property=KillMode=control-group",
		"--property=SendSIGKILL=yes",
		"--property=RuntimeMaxSec=30s",
		"--property=TimeoutStopSec=5s",
		"--property=CollectMode=inactive",
		"--property=StandardOutput=truncate:/tmp/out",
		"--property=StandardError=truncate:/tmp/err",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("systemd-run argv is missing %q; got %q", want, joined)
		}
	}
	// A collected unit loses Result and ExecMainStatus, which are the only
	// durable proof of how the operation ended.
	if strings.Contains(joined, "CollectMode=inactive-or-failed") {
		t.Errorf("the unit must not be collected before its result is read: %q", joined)
	}
	commandStart := -1
	for i, a := range gotArgs {
		if a == "--" {
			commandStart = i
		}
	}
	if commandStart < 0 {
		t.Fatalf("the command must be separated from manager flags by --, got %q", gotArgs)
	}
	if strings.Join(gotArgs[commandStart+1:], " ") != "/bin/echo hi" {
		t.Errorf("command after -- = %q, want the caller's argv verbatim", gotArgs[commandStart+1:])
	}
}

func TestVersionRefusesWithoutAnAnsweringManager(t *testing.T) {
	m := newSystemdManager()
	m.run = func(_ context.Context, _ string, _ []string, _ []string) (commandResult, error) {
		return commandResult{Stderr: "Failed to connect to bus: No such file or directory", ExitCode: 1}, nil
	}
	_, err := m.Version(context.Background())
	if err == nil {
		t.Fatal("Version accepted a manager that did not answer")
	}
	if !strings.Contains(err.Error(), "Failed to connect to bus") {
		t.Errorf("the refusal must quote the manager's own diagnostic, got %v", err)
	}
}

func TestClassify(t *testing.T) {
	cases := []struct {
		name       string
		startRes   commandResult
		startErr   error
		state      unitState
		showErr    error
		wantState  string
		wantExit   int
		wantSignal int
	}{
		{
			name:      "success",
			state:     unitState{LoadState: "loaded", ActiveState: "inactive", Result: "success"},
			wantState: stateCompleted,
			wantExit:  0,
		},
		{
			name:      "non-zero exit is the command's own status",
			state:     unitState{LoadState: "loaded", ActiveState: "failed", Result: "exit-code", ExecMainStatus: 42},
			wantState: stateCompleted,
			wantExit:  42,
		},
		{
			name:      "timeout is never reported as exit 1",
			startRes:  commandResult{ExitCode: 1},
			state:     unitState{LoadState: "loaded", ActiveState: "failed", Result: "timeout", ExecMainStatus: 15},
			wantState: stateTimeout,
		},
		{
			name:       "signal",
			state:      unitState{LoadState: "loaded", ActiveState: "failed", Result: "signal", ExecMainCode: 2, ExecMainStatus: 9},
			wantState:  stateCompleted,
			wantExit:   137,
			wantSignal: 9,
		},
		{
			name:      "success unit collected before its record",
			startRes:  commandResult{ExitCode: 0},
			state:     unitState{LoadState: "not-found"},
			wantState: stateCompleted,
			wantExit:  0,
		},
		{
			name:      "collected failed unit is unknown, never success",
			startRes:  commandResult{ExitCode: 1},
			state:     unitState{LoadState: "not-found"},
			wantState: stateUnknownResult,
		},
		{
			name:      "still active means cleanup pending",
			startRes:  commandResult{ExitCode: 1},
			state:     unitState{LoadState: "loaded", ActiveState: "deactivating"},
			wantState: stateCleanupPending,
		},
		{
			name:      "unreadable record is unknown",
			state:     unitState{},
			showErr:   context.DeadlineExceeded,
			wantState: stateUnknownResult,
		},
		{
			name:      "manager call that never completed is unknown",
			startErr:  context.DeadlineExceeded,
			state:     unitState{LoadState: "loaded", ActiveState: "inactive"},
			wantState: stateUnknownResult,
		},
		{
			name:      "unrecognised result is unknown",
			state:     unitState{LoadState: "loaded", ActiveState: "failed", Result: "oom-kill"},
			wantState: stateUnknownResult,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotState, gotExit, gotSignal, _ := classify(tc.startRes, tc.startErr, tc.state, tc.showErr)
			if gotState != tc.wantState {
				t.Fatalf("state = %q, want %q", gotState, tc.wantState)
			}
			if tc.wantState == stateCompleted {
				if gotExit == nil || *gotExit != tc.wantExit {
					t.Fatalf("exit = %v, want %d", gotExit, tc.wantExit)
				}
			} else if gotExit != nil && tc.wantState != stateCompleted {
				t.Fatalf("exit = %v, want nil for %q", *gotExit, tc.wantState)
			}
			if tc.wantSignal != 0 {
				if gotSignal == nil || *gotSignal != tc.wantSignal {
					t.Fatalf("signal = %v, want %d", gotSignal, tc.wantSignal)
				}
			}
		})
	}
}

func TestParseUnitState(t *testing.T) {
	got := parseUnitState("LoadState=loaded\nActiveState=failed\nResult=exit-code\nExecMainCode=1\nExecMainStatus=42\n")
	want := unitState{LoadState: "loaded", ActiveState: "failed", Result: "exit-code", ExecMainCode: 1, ExecMainStatus: 42}
	if got != want {
		t.Fatalf("parseUnitState = %+v, want %+v", got, want)
	}
}

func TestDurationSpec(t *testing.T) {
	cases := map[time.Duration]string{
		0:                       "infinity",
		30 * time.Second:        "30s",
		1500 * time.Millisecond: "1.500s",
	}
	for in, want := range cases {
		if got := durationSpec(in); got != want {
			t.Errorf("durationSpec(%s) = %q, want %q", in, got, want)
		}
	}
}

func TestCgroupMembersReadsTheUnitGroup(t *testing.T) {
	root := t.TempDir()
	if pids, seen, err := cgroupMembersAt(root, "/gone.slice/unit.service"); err != nil || seen || pids != nil {
		t.Fatalf("a removed cgroup must read as empty, got pids=%v seen=%v err=%v", pids, seen, err)
	}
	dir := root + "/live.slice/unit.service"
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(dir+"/cgroup.procs", []byte("12\n7\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	pids, seen, err := cgroupMembersAt(root, "/live.slice/unit.service")
	if err != nil || !seen {
		t.Fatalf("a live cgroup must be reported as seen, got seen=%v err=%v", seen, err)
	}
	if len(pids) != 2 || pids[0] != 7 || pids[1] != 12 {
		t.Fatalf("survivors = %v, want the sorted pids that remained", pids)
	}
}

func TestOperationIDsAndUnitNames(t *testing.T) {
	for _, ok := range []string{"demo", "away.stop.1", "a_b-c"} {
		if !validOperationID(ok) {
			t.Errorf("%q must be a valid operation id", ok)
		}
	}
	for _, bad := range []string{"", "with space", "semi;colon", strings.Repeat("x", 97)} {
		if validOperationID(bad) {
			t.Errorf("%q must be rejected as an operation id", bad)
		}
	}
	if unit := unitName("away.stop"); !strings.HasPrefix(unit, "sq-op-away.stop-") || !strings.HasSuffix(unit, ".service") {
		t.Errorf("unit name = %q, want a sq-op- prefixed .service unit", unit)
	}
	if a, b := unitName("same"), unitName("same"); a == b {
		t.Errorf("two attempts must not share a unit name: %q", a)
	}
}

func TestContainmentNeedsInspectedOrRemovedMembership(t *testing.T) {
	cases := []struct {
		name          string
		cgroup        string
		members       []int
		seen          bool
		unitGone      bool
		unifiedRoot   bool
		inspectionErr error
		want          bool
	}{
		{
			name:        "inspected empty group proves containment",
			cgroup:      "/user.slice/unit.service",
			seen:        true,
			unifiedRoot: true,
			want:        true,
		},
		{
			name:        "removed group under a unified root with the unit gone proves containment",
			cgroup:      "/user.slice/unit.service",
			unitGone:    true,
			unifiedRoot: true,
			want:        true,
		},
		{
			name:        "missing group under a non-unified root proves nothing",
			cgroup:      "/user.slice/unit.service",
			unitGone:    true,
			unifiedRoot: false,
			want:        false,
		},
		{
			name:        "missing group with the unit still active proves nothing",
			cgroup:      "/user.slice/unit.service",
			unifiedRoot: true,
			want:        false,
		},
		{
			name:        "remaining members are never containment",
			cgroup:      "/user.slice/unit.service",
			members:     []int{12},
			seen:        true,
			unifiedRoot: true,
			want:        false,
		},
		{
			name:          "an inspection failure is never containment",
			cgroup:        "/user.slice/unit.service",
			seen:          true,
			unifiedRoot:   true,
			inspectionErr: os.ErrPermission,
			want:          false,
		},
		{
			name:     "no captured group with the unit gone proves containment",
			unitGone: true,
			want:     true,
		},
		{
			name: "no captured group with the unit still active proves nothing",
			want: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, _ := containmentProved(tc.cgroup, tc.members, tc.seen, tc.unitGone, tc.unifiedRoot, tc.inspectionErr)
			if got != tc.want {
				t.Fatalf("containmentProved = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestControlGroupCaptureBacksOffAndGivesUp(t *testing.T) {
	m := &fakeManager{}
	capture := startControlGroupCapture(m, "sq-op-test.service", 600*time.Millisecond)
	// Let the budget expire with a manager that never reports a path.
	time.Sleep(700 * time.Millisecond)
	path, err := capture.stop()
	if path != "" || err != nil {
		t.Fatalf("capture = (%q, %v), want an empty path and no error", path, err)
	}
	// A fixed 50ms tick would be about thirteen probes in this window; the
	// backed-off capture makes a handful.
	if m.cgroupCalls < 2 || m.cgroupCalls > 6 {
		t.Fatalf("ControlGroup was probed %d times, want a backed-off handful", m.cgroupCalls)
	}
}
