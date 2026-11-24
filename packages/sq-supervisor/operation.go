package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Outcome states. A caller may act on "completed" and "timeout" and must treat
// every other state as unknown, never as success.
const (
	stateCompleted       = "completed"
	stateTimeout         = "timeout"
	stateUnknownResult   = "unknown-result"
	stateCleanupPending  = "cleanup-pending"
	stateManagerDisabled = "manager-unavailable"
)

const outcomeSchema = "sq-supervisor.operation.v1"

// managerProbeBound bounds the capability probe so a wedged bus cannot hang a
// caller that asked for a bounded operation.
const managerProbeBound = 5 * time.Second

// stopSlack is added to deadline+stop grace for the manager call itself. It
// covers manager round-trips, not the operation: the operation's own bound is
// RuntimeMaxSec, enforced by the kernel.
const stopSlack = 10 * time.Second

// maxDeadline keeps a caller from asking for an operation that can outlive any
// supervisor cycle that would be waiting on it.
const maxDeadline = 30 * time.Minute

// outcome is the one durable, machine-readable result of an operation.
type outcome struct {
	Schema        string `json:"schema"`
	OperationID   string `json:"operation_id"`
	State         string `json:"state"`
	ExitCode      *int   `json:"exit_code"`
	Signal        *int   `json:"signal"`
	Unit          string `json:"unit,omitempty"`
	Manager       string `json:"manager,omitempty"`
	UnitResult    string `json:"unit_result,omitempty"`
	Contained     bool   `json:"contained"`
	Survivors     []int  `json:"survivors"`
	Cgroup        string `json:"cgroup,omitempty"`
	StartedAt     string `json:"started_at"`
	EndedAt       string `json:"ended_at"`
	DurationMS    int64  `json:"duration_ms"`
	IntentRecord  string `json:"intent_record,omitempty"`
	OutcomeRecord string `json:"outcome_record,omitempty"`
	Detail        string `json:"detail,omitempty"`
}

// intentRecord is written before the unit exists, so a crash between launch and
// result leaves durable evidence of what was started. A caller reconciles that
// exact intent; it never retries a non-idempotent operation blind.
type intentRecord struct {
	Schema      string   `json:"schema"`
	OperationID string   `json:"operation_id"`
	Unit        string   `json:"unit"`
	Command     []string `json:"command"`
	DeadlineMS  int64    `json:"deadline_ms"`
	StopGraceMS int64    `json:"stop_grace_ms"`
	StartedAt   string   `json:"started_at"`
}

// newManager builds the operation's manager. It is a variable so the refusal and
// recovery paths can be exercised against a scripted manager.
var newManager = func() manager { return newSystemdManager() }

// runOperation implements `sq-supervisor run`.
func runOperation(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(stderr)
	operationID := fs.String("operation-id", "", "stable identity for this operation")
	stateDir := fs.String("state-dir", "", "directory for intent and outcome records")
	deadline := fs.Duration("deadline", 0, "hard bound for the operation")
	stopGrace := fs.Duration("stop-grace", 0, "TERM grace before SIGKILL")
	stdoutPath := fs.String("stdout", "", "file receiving the operation's stdout")
	stderrPath := fs.String("stderr", "", "file receiving the operation's stderr")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	command := fs.Args()

	if err := validateOperation(*operationID, *stateDir, *deadline, *stopGrace, *stdoutPath, *stderrPath, command); err != nil {
		fmt.Fprintf(stderr, "sq-supervisor: %s\n", err)
		usage(stderr)
		return exitUsage
	}

	started := time.Now().UTC()
	manager := newManager()

	probeCtx, cancelProbe := context.WithTimeout(context.Background(), managerProbeBound)
	managerVersion, probeErr := manager.Version(probeCtx)
	cancelProbe()
	if probeErr != nil {
		return emitRefusal(*operationID, probeErr, started, stdout, stderr)
	}

	unit := unitName(*operationID)
	intentPath := filepath.Join(*stateDir, *operationID+".intent.json")
	intent := intentRecord{
		Schema:      "sq-supervisor.intent.v1",
		OperationID: *operationID,
		Unit:        unit,
		Command:     command,
		DeadlineMS:  deadline.Milliseconds(),
		StopGraceMS: stopGrace.Milliseconds(),
		StartedAt:   started.Format(time.RFC3339Nano),
	}
	if err := writeJSONRecord(intentPath, intent); err != nil {
		fmt.Fprintf(stderr, "sq-supervisor: cannot record the operation intent: %v\n", err)
		return exitUnknownResult
	}

	spec := unitSpec{
		Unit:      unit,
		Deadline:  *deadline,
		StopGrace: *stopGrace,
		Stdout:    *stdoutPath,
		Stderr:    *stderrPath,
		Command:   command,
	}

	// The manager clears ControlGroup once the unit is dead, so membership can
	// only be proved empty by a path captured while the unit was alive. The
	// capture therefore runs beside the blocking start, never before it.
	capture := startControlGroupCapture(manager, unit)

	runCtx, cancelRun := context.WithTimeout(context.Background(), *deadline+*stopGrace+stopSlack)
	startRes, startErr := manager.Start(runCtx, spec)
	cancelRun()

	cgroup, cgroupErr := capture.stop()

	showCtx, cancelShow := context.WithTimeout(context.Background(), managerProbeBound)
	unitRecord, showErr := manager.Show(showCtx, unit)
	cancelShow()

	forgetCtx, cancelForget := context.WithTimeout(context.Background(), managerProbeBound)
	_ = manager.Forget(forgetCtx, unit)
	cancelForget()

	members, _, membersErr := cgroupMembers(cgroup)
	if membersErr != nil && members == nil {
		// The cgroup listing itself failed. That is not proof of containment.
		cgroupErr = membersErr
	}

	oc := outcome{
		Schema:        outcomeSchema,
		OperationID:   *operationID,
		Unit:          unit,
		Manager:       managerVersion,
		StartedAt:     started.Format(time.RFC3339Nano),
		EndedAt:       time.Now().UTC().Format(time.RFC3339Nano),
		Cgroup:        cgroup,
		IntentRecord:  intentPath,
		Survivors:     members,
		Contained:     len(members) == 0,
		UnitResult:    unitRecord.Result,
	}

	oc.State, oc.ExitCode, oc.Signal, oc.Detail = classify(startRes, startErr, unitRecord, showErr)

	// Containment is claimed only from evidence. A captured cgroup that the kernel
	// has already removed, or one whose membership is empty, proves it; a unit the
	// manager no longer knows also owns no cgroup. Anything else stays unproven and
	// is reported as such rather than assumed.
	unitGone := unitRecord.LoadState == "not-found" ||
		unitRecord.ActiveState == "inactive" || unitRecord.ActiveState == "failed"
	oc.Contained = (cgroup != "" && len(members) == 0) || (cgroup == "" && unitGone && membersErr == nil)
	if cgroup == "" && oc.Contained {
		oc.Detail = appendDetail(oc.Detail, "the unit cgroup was already collected, so containment is proved by the unit being gone rather than by an inspected membership")
	}
	if cgroupErr != nil {
		oc.Contained = false
		oc.Detail = appendDetail(oc.Detail, "the unit control group could not be inspected: "+cgroupErr.Error())
	}
	if len(members) > 0 {
		oc.Contained = false
		if oc.State == stateCompleted || oc.State == stateTimeout {
			oc.State = stateCleanupPending
			oc.Detail = appendDetail(oc.Detail, fmt.Sprintf("%d process(es) remained in the unit group after the stop grace", len(members)))
		}
	}

	outcomePath := filepath.Join(*stateDir, *operationID+".outcome.json")
	if err := writeJSONRecord(outcomePath, oc); err != nil {
		fmt.Fprintf(stderr, "sq-supervisor: cannot record the operation outcome: %v\n", err)
	}
	oc.OutcomeRecord = outcomePath
	oc.DurationMS = time.Since(started).Milliseconds()

	emit(oc, stdout)
	return exitForState(oc.State)
}

// emitRefusal reports strict-mode refusal. Nothing was launched, so there is no
// unit and no intent record: the caller keeps its old behaviour reachable.
func emitRefusal(operationID string, reason error, started time.Time, stdout, stderr io.Writer) int {
	oc := outcome{
		Schema:      outcomeSchema,
		OperationID: operationID,
		State:       stateManagerDisabled,
		Contained:   false,
		Survivors:   []int{},
		StartedAt:   started.Format(time.RFC3339Nano),
		EndedAt:     time.Now().UTC().Format(time.RFC3339Nano),
		Detail:      reason.Error(),
	}
	fmt.Fprintf(stderr, "sq-supervisor: %s\n", reason.Error())
	emit(oc, stdout)
	return exitManagerUnavailable
}

func emit(oc outcome, w io.Writer) {
	body, err := json.Marshal(oc)
	if err != nil {
		fmt.Fprintf(w, `{"schema":%q,"state":%q}`+"\n", outcomeSchema, oc.State)
		return
	}
	fmt.Fprintf(w, "%s\n", body)
}

// classify reads the manager's own completion record. The start call's exit
// status is a fallback signal only: systemd-run reports 1 both for a failed
// command and for a timeout, so it can never distinguish them by itself.
func classify(startRes commandResult, startErr error, st unitState, showErr error) (string, *int, *int, string) {
	if showErr != nil {
		return stateUnknownResult, nil, nil, "the unit result could not be read: " + showErr.Error()
	}
	if st.LoadState == "not-found" {
		// A successful transient unit is collected as soon as it exits, so its
		// record is gone. Its start status is authoritative only for success,
		// because a failed unit stays loaded and would have been readable.
		if startErr == nil && startRes.ExitCode == 0 {
			return stateCompleted, intPtr(0), nil, "the unit succeeded and was collected before its record could be read"
		}
		return stateUnknownResult, nil, nil, "the unit record was already collected and its start status is not a completion record"
	}
	switch st.Result {
	case "success":
		return stateCompleted, intPtr(0), nil, ""
	case "exit-code":
		return stateCompleted, intPtr(st.ExecMainStatus), nil, ""
	case "signal":
		sig := st.ExecMainStatus
		return stateCompleted, intPtr(128 + sig), intPtr(sig), "the operation was killed by signal"
	case "timeout":
		return stateTimeout, nil, nil, "the operation reached its deadline and the manager stopped its group"
	case "start-limit-hit", "resources", "oom-kill", "watchdog":
		return stateUnknownResult, nil, nil, "the manager reports result " + st.Result
	}
	if st.ActiveState == "active" || st.ActiveState == "activating" || st.ActiveState == "deactivating" {
		return stateCleanupPending, nil, nil, "the unit was still " + st.ActiveState + " when the operation bound expired"
	}
	if startErr != nil {
		return stateUnknownResult, nil, nil, "the manager call did not complete: " + startErr.Error()
	}
	return stateUnknownResult, nil, nil, "the manager reports an unrecognised result " + fmt.Sprintf("%q", st.Result)
}

// controlGroupCapture polls for the unit's cgroup path for as long as the
// operation runs, and reports the last path it saw.
type controlGroupCapture struct {
	stopPoller chan struct{}
	result     chan controlGroupResult
}

type controlGroupResult struct {
	path string
	err  error
}

func startControlGroupCapture(m manager, unit string) *controlGroupCapture {
	capture := &controlGroupCapture{
		stopPoller: make(chan struct{}),
		result:     make(chan controlGroupResult, 1),
	}
	go func() {
		var lastErr error
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for {
			ctx, cancel := context.WithTimeout(context.Background(), managerProbeBound)
			path, err := m.ControlGroup(ctx, unit)
			cancel()
			if err != nil {
				lastErr = err
			} else if path != "" {
				capture.result <- controlGroupResult{path: path}
				return
			}
			select {
			case <-capture.stopPoller:
				capture.result <- controlGroupResult{err: lastErr}
				return
			case <-ticker.C:
			}
		}
	}()
	return capture
}

// stop ends the capture and reports what it saw. A path already gone is not an
// error: the kernel removes the cgroup with its last member.
func (c *controlGroupCapture) stop() (string, error) {
	close(c.stopPoller)
	select {
	case res := <-c.result:
		return res.path, res.err
	case <-time.After(managerProbeBound):
		return "", errors.New("the unit control group could not be read before the operation ended")
	}
}

func validateOperation(operationID, stateDir string, deadline, stopGrace time.Duration, stdoutPath, stderrPath string, command []string) error {
	if operationID == "" {
		return errors.New("--operation-id is required")
	}
	if !validOperationID(operationID) {
		return fmt.Errorf("--operation-id %q must be 1-96 characters of [A-Za-z0-9._-]", operationID)
	}
	if stateDir == "" {
		return errors.New("--state-dir is required")
	}
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return fmt.Errorf("--state-dir %q is unusable: %w", stateDir, err)
	}
	if deadline <= 0 {
		return errors.New("--deadline must be positive")
	}
	if deadline > maxDeadline {
		return fmt.Errorf("--deadline %s exceeds the %s maximum", deadline, maxDeadline)
	}
	if stopGrace <= 0 {
		return errors.New("--stop-grace must be positive")
	}
	if stdoutPath == "" || stderrPath == "" {
		return errors.New("--stdout and --stderr are required")
	}
	if len(command) == 0 {
		return errors.New("a command is required after --")
	}
	return nil
}

func validOperationID(s string) bool {
	if len(s) == 0 || len(s) > 96 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '.', r == '_', r == '-':
		default:
			return false
		}
	}
	return true
}

// unitName derives a unique, valid systemd unit name. The random suffix keeps a
// retried operation from colliding with the leftover of a previous attempt.
func unitName(operationID string) string {
	sanitized := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		case r == '.', r == '_', r == '-':
			return r
		default:
			return '-'
		}
	}, operationID)
	if len(sanitized) > 48 {
		sanitized = sanitized[:48]
	}
	suffix := make([]byte, 3)
	if _, err := rand.Read(suffix); err != nil {
		return "sq-op-" + sanitized + ".service"
	}
	return "sq-op-" + sanitized + "-" + hex.EncodeToString(suffix) + ".service"
}

func exitForState(state string) int {
	switch state {
	case stateCompleted:
		return exitCompleted
	case stateTimeout:
		return exitTimeout
	case stateCleanupPending:
		return exitCleanupPending
	case stateManagerDisabled:
		return exitManagerUnavailable
	default:
		return exitUnknownResult
	}
}

func appendDetail(existing, extra string) string {
	if existing == "" {
		return extra
	}
	return existing + "; " + extra
}

func intPtr(v int) *int { return &v }

// writeJSONRecord writes one record atomically and flushes it, so a crash after
// this returns cannot leave a half-written or unflushed record behind.
func writeJSONRecord(path string, value any) error {
	body, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	body = append(body, '\n')
	dir := filepath.Dir(path)
	temp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp.")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer func() { _ = os.Remove(tempName) }()
	if _, err := temp.Write(body); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempName, path); err != nil {
		return err
	}
	if handle, err := os.Open(dir); err == nil {
		_ = handle.Sync()
		_ = handle.Close()
	}
	return nil
}

// reportCapabilities answers whether strict Linux mode can be honoured here. It
// mutates nothing and is safe to call from a health check.
func reportCapabilities(stdout, stderr io.Writer) int {
	manager := newManager()
	ctx, cancel := context.WithTimeout(context.Background(), managerProbeBound)
	defer cancel()
	version, err := manager.Version(ctx)
	caps := map[string]any{
		"schema":     "sq-supervisor.capabilities.v1",
		"platform":   platformName(),
		"strict":     strictPlatform(),
		"available":  err == nil,
		"manager":    version,
		"containment": map[string]any{
			"mechanism":       "systemd-user-transient-service",
			"kill_mode":       "control-group",
			"send_sigkill":    true,
			"second_group":    true,
			"second_session":  true,
			"backend_servers": "not contained; reconcile the exact recorded target instead",
		},
	}
	if err != nil {
		caps["reason"] = err.Error()
		fmt.Fprintf(stderr, "sq-supervisor: %s\n", err.Error())
	}
	body, marshalErr := json.Marshal(caps)
	if marshalErr != nil {
		fmt.Fprintf(stderr, "sq-supervisor: %v\n", marshalErr)
		return exitUnknownResult
	}
	fmt.Fprintf(stdout, "%s\n", body)
	if err != nil {
		return exitManagerUnavailable
	}
	return exitCompleted
}
