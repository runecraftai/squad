package steps

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/pipeline"
)

func TestRunStepShellCommandRefusesWithoutAcknowledgedPolicy(t *testing.T) {
	_, _, err := runStepShellCommand(&pipeline.StepContext{}, "touch should-not-run")
	if err == nil || !strings.Contains(err.Error(), "drill-repository-execution-v1") {
		t.Fatalf("missing policy should be named and refused: %v", err)
	}
}

func TestRunShellCommandWithEnv_UsesShAndIgnoresUserShell(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows uses cmd.exe; SHELL is only honored on POSIX")
	}
	workDir := t.TempDir()
	marker := filepath.Join(t.TempDir(), "user-shell-used")
	shellPath := filepath.Join(t.TempDir(), "bash")
	script := "#!/bin/sh\nprintf used > \"$USER_SHELL_MARKER\"\nexit 99\n"
	if err := os.WriteFile(shellPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", shellPath)
	t.Setenv("USER_SHELL_MARKER", marker)

	output, exitCode, err := runShellCommandWithEnv(context.Background(), workDir, []string{"STEP_SPECIAL=from-step"}, "printf %s \"$STEP_SPECIAL\"")
	if err != nil {
		t.Fatal(err)
	}
	if exitCode != 0 {
		t.Fatalf("exitCode = %d", exitCode)
	}
	if output != "from-step" {
		t.Fatalf("output = %q", output)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("expected custom user shell to be ignored")
	}
}
