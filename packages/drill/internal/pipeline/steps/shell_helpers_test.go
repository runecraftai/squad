package steps

import (
	"context"
	"fmt"
	"os/exec"
	"runtime"

	"github.com/runecraftai/squad/packages/drill/internal/shellenv"
)

// runShellCommand executes a shell command and returns stdout+stderr, exit code, and error.
// A non-zero exit code is not treated as an error - only exec failures return error.
func runShellCommand(ctx context.Context, dir, cmdStr string) (string, int, error) {
	return runShellCommandWithEnv(ctx, dir, nil, cmdStr)
}

// runShellCommandWithEnv is the unconfined host shell used only to exercise
// shellenv/mergeEnv semantics in tests; production steps execute repository
// commands through StepContext.ExecutionPolicy.
func runShellCommandWithEnv(ctx context.Context, dir string, env []string, cmdStr string) (string, int, error) {
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "cmd.exe", "/c", cmdStr)
	} else {
		cmd = exec.CommandContext(ctx, "sh", "-c", cmdStr)
	}
	shellenv.ConfigureShellCommand(cmd)
	cmd.Dir = dir
	if len(env) > 0 {
		cmd.Env = mergeEnv(env)
	}
	out, err := shellenv.CombinedOutputShellCommand(cmd)
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return string(out), ee.ExitCode(), nil
		}
		return "", -1, fmt.Errorf("run command %q: %w", cmdStr, err)
	}
	return string(out), 0, nil
}
