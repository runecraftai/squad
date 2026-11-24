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
var newManager = func(stdout, stderr io.Writer) manager { return newSystemdManager(stdout, stderr) }

// runOperation implements `sq-supervisor run`. The operation's own streams are
// the caller's streams: nothing but the operation's bytes reach stdout, and the
// outcome is reported through its durable record and this process's exit status.
func runOperation(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(stderr)
	operationID := fs.String("operation-id", "", "stable identity for this operation")
	stateDir := fs.String("state-dir", "", "directory for intent and outcome records")
	deadline := fs.Duration("deadline", 0, "hard bound for the operation")
	stopGrace := fs.Duration("stop-grace", 0, "TERM grace before SIGKILL")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	command := fs.Args()

	if err := validateOperation(*operationID, *stateDir, *deadline, *stopGrace, command); err != nil {
		fmt.Fprintf(stderr, "sq-supervisor: %s\n", err)
		usage(stderr)
		return exitUsage
	}

	workingDirectory, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(stderr, "sq-supervisor: the caller's working directory could not be read: %v\n", err)
		return exitUsage
	}

	started := time.Now().UTC()
	manager := newManager(stdout, stderr)

	probeCtx, cancelProbe := context.WithTimeout(context.Background(), managerProbeBound)
	managerVersion, probeErr := manager.Version(probeCtx)
	cancelProbe()
	if probeErr != nil {
		return emitRefusal(*operationID, *stateDir, probeErr, started, stderr)
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
		Unit:             unit,
		Deadline:         *deadline,
		StopGrace:        *stopGrace,
		WorkingDirectory: workingDirectory,
		Environment:      relayableEnvironment(os.Environ()),
		NoExpandEnv:      supportsExpandEnvironment(managerVersion),
		Command:          command,
	}

	// The manager clears ControlGroup once the unit is dead, so membership can
	// only be proved empty by a path captured while the unit was alive. The
	// capture therefore runs beside the blocking start, never before it.
	budget := *deadline + *stopGrace + stopSlack
	capture := startControlGroupCapture(manager, unit, budget)

	runCtx, cancelRun := context.WithTimeout(context.Background(), budget)
	startRes, startErr := manager.Start(runCtx, spec)
	cancelRun()

	cgroup, cgroupErr := capture.stop()

	showCtx, cancelShow := context.WithTimeout(context.Background(), managerProbeBound)
	unitRecord, showErr := manager.Show(showCtx, unit)
	cancelShow()

	forgetCtx, cancelForget := context.WithTimeout(context.Background(), managerProbeBound)
	_ = manager.Forget(forgetCtx, unit)
	cancelForget()

	members, seen, membersErr := cgroupMembers(cgroup)
	inspectionErr := cgroupErr
	if membersErr != nil {
		inspectionErr = membersErr
	}

	oc := outcome{
		Schema:       outcomeSchema,
		OperationID:  *operationID,
		Unit:         unit,
		Manager:      managerVersion,
		StartedAt:    started.Format(time.RFC3339Nano),
		EndedAt:      time.Now().UTC().Format(time.RFC3339Nano),
		Cgroup:       cgroup,
		IntentRecord: intentPath,
		Survivors:    members,
		Contained:    false,
		UnitResult:   unitRecord.Result,
	}

	oc.State, oc.ExitCode, oc.Signal, oc.Detail = classify(startRes, startErr, unitRecord, showErr)
	// The manager's streams are the operation's streams under --pipe, so nothing
	// it wrote there is attributable to the manager; only the call itself is.
	if startErr != nil {
		oc.Detail = appendDetail(oc.Detail, startErr.Error())
	}
	if len(members) == 0 {
		oc.Survivors = []int{}
	}

	// Containment is claimed only from evidence. A captured cgroup whose
	// membership was inspected and is empty proves it; so does a captured cgroup
	// the kernel has removed, but only under a real cgroup v2 root and only when
	// the unit itself is gone. A unit the manager no longer knows also owns no
	// cgroup. Anything else stays unproven rather than assumed.
	unitGone := unitRecord.LoadState == "not-found" ||
		unitRecord.ActiveState == "inactive" || unitRecord.ActiveState == "failed"
	contained, containmentDetail := containmentProved(cgroup, members, seen, unitGone, unifiedCgroupRoot(), inspectionErr)
	oc.Contained = contained
	oc.Detail = appendDetail(oc.Detail, containmentDetail)
	if len(members) > 0 {
		oc.Contained = false
		if oc.State == stateCompleted || oc.State == stateTimeout {
			oc.State = stateCleanupPending
			oc.Detail = appendDetail(oc.Detail, fmt.Sprintf("%d process(es) remained in the unit group after the stop grace", len(members)))
		}
	}

	outcomePath := filepath.Join(*stateDir, *operationID+".outcome.json")
	oc.OutcomeRecord = outcomePath
	oc.DurationMS = time.Since(started).Milliseconds()
	if err := writeJSONRecord(outcomePath, oc); err != nil {
		fmt.Fprintf(stderr, "sq-supervisor: cannot record the operation outcome: %v\n", err)
	}

	return exitForState(oc.State)
}

// emitRefusal reports strict-mode refusal. Nothing was launched, so there is no
// unit and no intent record: the caller keeps its old behaviour reachable. The
// refusal itself is still recorded, so the reason survives the caller.
func emitRefusal(operationID, stateDir string, reason error, started time.Time, stderr io.Writer) int {
	oc := outcome{
		Schema:        outcomeSchema,
		OperationID:   operationID,
		State:         stateManagerDisabled,
		Contained:     false,
		Survivors:     []int{},
		StartedAt:     started.Format(time.RFC3339Nano),
		EndedAt:       time.Now().UTC().Format(time.RFC3339Nano),
		DurationMS:    time.Since(started).Milliseconds(),
		OutcomeRecord: filepath.Join(stateDir, operationID+".outcome.json"),
		Detail:        reason.Error(),
	}
	fmt.Fprintf(stderr, "sq-supervisor: %s\n", reason.Error())
	if err := writeJSONRecord(oc.OutcomeRecord, oc); err != nil {
		fmt.Fprintf(stderr, "sq-supervisor: cannot record the operation outcome: %v\n", err)
	}
	return exitManagerUnavailable
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

// capturePollStart and capturePollMax bound the poll rate: a manager that keeps
// reporting an empty path must not cost one subprocess per tick for the whole
// operation.
const (
	capturePollStart = 50 * time.Millisecond
	capturePollMax   = 2 * time.Second
)

func startControlGroupCapture(m manager, unit string, budget time.Duration) *controlGroupCapture {
	capture := &controlGroupCapture{
		stopPoller: make(chan struct{}),
		result:     make(chan controlGroupResult, 1),
	}
	go func() {
		var lastErr error
		gaveUp := time.NewTimer(budget)
		defer gaveUp.Stop()
		interval := capturePollStart
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
			delay := time.NewTimer(interval)
			select {
			case <-capture.stopPoller:
				delay.Stop()
				capture.result <- controlGroupResult{err: lastErr}
				return
			case <-gaveUp.C:
				delay.Stop()
				capture.result <- controlGroupResult{err: lastErr}
				return
			case <-delay.C:
			}
			interval *= 2
			if interval > capturePollMax {
				interval = capturePollMax
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

func validateOperation(operationID, stateDir string, deadline, stopGrace time.Duration, command []string) error {
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
	if len(command) == 0 {
		return errors.New("a command is required after --")
	}
	return nil
}

// relayableEnvironment keeps the caller's assignments that a manager accepts.
// An exported bash function lands in the environment under a name containing
// `%%`, which systemd rejects outright; dropping such entries keeps the launch
// working while every ordinary variable is relayed verbatim.
func relayableEnvironment(environ []string) []string {
	relayed := make([]string, 0, len(environ))
	for _, assignment := range environ {
		name, _, ok := strings.Cut(assignment, "=")
		if !ok || !validEnvironmentName(name) {
			continue
		}
		relayed = append(relayed, assignment)
	}
	return relayed
}

func validEnvironmentName(name string) bool {
	for i, r := range name {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r == '_':
		case i > 0 && r >= '0' && r <= '9':
		default:
			return false
		}
	}
	return name != ""
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
	if extra == "" {
		return existing
	}
	if existing == "" {
		return extra
	}
	return existing + "; " + extra
}

// unifiedCgroupRoot reports whether the unit cgroup paths the manager reports
// live under a real unified cgroup v2 root. Without that, a missing unit path
// proves nothing: it may simply not exist on this mount.
func unifiedCgroupRoot() bool {
	_, err := os.Stat(filepath.Join(cgroupRootDir, "cgroup.controllers"))
	return err == nil
}

// containmentProved decides, from recorded evidence only, whether the unit's
// group provably holds no process. An uninspected group is never treated as
// empty.
func containmentProved(cgroup string, members []int, seen, unitGone, unifiedRoot bool, inspectionErr error) (bool, string) {
	if inspectionErr != nil {
		return false, "the unit control group could not be inspected: " + inspectionErr.Error()
	}
	if len(members) > 0 {
		return false, ""
	}
	if cgroup == "" {
		if unitGone {
			return true, "the unit cgroup was already collected, so containment is proved by the unit being gone rather than by an inspected membership"
		}
		return false, ""
	}
	if seen {
		return true, ""
	}
	if unitGone && unifiedRoot {
		return true, "the unit cgroup was already removed by the kernel, so containment is proved by the unit being gone rather than by an inspected membership"
	}
	return false, "the captured unit cgroup was never inspected on this host, so containment is unproven"
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
	manager := newManager(io.Discard, io.Discard)
	ctx, cancel := context.WithTimeout(context.Background(), managerProbeBound)
	defer cancel()
	version, err := manager.Version(ctx)
	caps := map[string]any{
		"schema":    "sq-supervisor.capabilities.v1",
		"platform":  platformName(),
		"strict":    strictPlatform(),
		"available": err == nil,
		"manager":   version,
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
