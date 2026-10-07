//go:build linux

package pipeline

import (
	"bytes"
	"fmt"
	"os"
)

// stepProcessStatState prefers the kernel's /proc/<pid>/stat, which needs no
// external binary, and falls back to ps only when /proc cannot answer.
func stepProcessStatState(pid int) (string, error) {
	if stat, err := stepProcStatState(pid); err == nil {
		return stat, nil
	}
	return stepPSStatState(pid)
}

// stepProcStatState parses field 3 (the state character) from
// /proc/<pid>/stat. The comm field (field 2) is wrapped in parentheses and
// may itself contain spaces or parentheses, so the state is the first
// non-space byte after the last ')'.
func stepProcStatState(pid int) (string, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return "", err
	}
	closeParen := bytes.LastIndexByte(data, ')')
	if closeParen < 0 || closeParen+2 >= len(data) {
		return "", fmt.Errorf("unexpected /proc/%d/stat format", pid)
	}
	rest := bytes.TrimSpace(data[closeParen+1:])
	if len(rest) == 0 {
		return "", fmt.Errorf("missing state in /proc/%d/stat", pid)
	}
	return string(rest[:1]), nil
}
