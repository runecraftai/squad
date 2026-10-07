//go:build windows

package pipeline

// stepProcessState is a no-op liveness probe on Windows: job objects already
// contain and terminate the whole process tree on cancellation, so the
// dead-direct-process-with-a-live-descendant gap this watchdog targets does
// not arise the same way there. Reporting alive unconditionally means the
// watchdog never fails a run from an unsupported platform check.
func stepProcessState(pid int) (alive bool, state string, err error) {
	return true, "unknown", nil
}
