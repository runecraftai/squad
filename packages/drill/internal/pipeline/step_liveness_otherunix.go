//go:build unix && !linux

package pipeline

func stepProcessStatState(pid int) (string, error) {
	return stepPSStatState(pid)
}
