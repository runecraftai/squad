package agent

import "github.com/runecraftai/squad/packages/drill/internal/git"

// GateRoleEnvVar is exported into every spawned gate agent's environment as an
// coarse diagnostic marker that the process is a drill gate agent (a
// review/fix/document/test/lint/rebase/pr/ci invocation), NOT a workspace operator.
// It is defense in depth only: it can be removed, forged, or inherited, so
// runtime authorization uses canonical managed Git identity plus authenticated
// daemon peer process ancestry. Its purpose is containment: when the target repository is itself an
// agent-orchestration harness (for example a gate-agent checkout), the target's project
// agent-instruction file can otherwise convince the gate agent it is the workspace
// commander and drive it to spawn operators and reset the shared branch it is
// validating (see the ambient-authority incident). A cooperating harness reads
// this marker and its workspace-lifecycle entrypoints fail closed. It is deliberately
// coarse (`=1`): presence is the whole signal.
const GateRoleEnvVar = "DRILL_GATE"

// gitSafeEnv returns the environment for a spawned agent subprocess with git
// forced into non-interactive mode. Agents shell out to git directly (for
// example `git rebase --continue` during conflict resolution), which would
// otherwise open $EDITOR and hang in the headless subprocess until the agent
// times out.
//
// It also stamps GateRoleEnvVar so a cooperating orchestration harness in the
// target repo can recognize the gate agent and refuse to let it act as the workspace driver
// operator. Appended last so it wins over any ambient value.
//
// dir must be the value assigned to cmd.Dir so PWD stays coupled to the working
// directory; see git.NonInteractiveEnv for why this matters.
func gitSafeEnv(dir string) []string {
	return append(git.NonInteractiveEnv(dir), GateRoleEnvVar+"=1")
}
