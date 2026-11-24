// sq-supervisor - the single owner of contained external operations for Squad.
//
// Squad runs backend CLIs, terminal adapters and vendor probes that fork helper
// processes, change session or process group, and ignore TERM. A shell process
// group is not a containment domain for those, so this binary places each
// operation in its own systemd user transient service and lets the kernel own
// membership. State (the away-mode ledger and the return transaction) is not
// owned here.
//
// Usage:
//
//	sq-supervisor run --operation-id <id> --state-dir <dir> \
//	                  --deadline <duration> --stop-grace <duration> \
//	                  -- <command> [args...]
//	sq-supervisor capabilities
//	sq-supervisor --version
//
// `run` runs the command inside its own transient service with the caller's
// environment, working directory and stdin/stdout/stderr, and writes one JSON
// outcome record to <state-dir>/<operation-id>.outcome.json. Its own stdout and
// stderr carry the operation's bytes and nothing else. Its exit status is from
// the outcome enum below. A completed operation is reported from the unit's own
// completion record when the manager still has it, and from the manager's own
// start status when the unit succeeded and was already collected; a timed-out
// operation is never reported as the command's own exit status.
//
// The caller's environment is relayed through <state-dir>/<operation-id>.env,
// created 0600 and removed once the unit has started; it never enters this
// process's argv or a unit property, so no value is visible to a local reader of
// the manager's command line. The intent and outcome records live only as long
// as --state-dir does: bin/sq-op-contain.sh creates a temporary directory and
// removes it on exit unless the caller passes --state-dir, so a caller that must
// reconcile the two records later has to supply a durable directory.
//
// Exit status:
//
//	0   operation completed; the command's own status is in the outcome record
//	2   usage error
//	3   the deadline was reached and the operation was stopped by the manager
//	4   the unit's result could not be read (unknown-result; do not retry blind)
//	5   the unit's group still holds processes after the stop grace
//	78  strict Linux mode is required and no working systemd user manager exists
package main

import (
	"fmt"
	"io"
	"os"
)

// version is stamped at build time by bin/sq-install-supervisor.sh.
var version = "dev"

// Outcome status codes, mirrored by bin/sq-op-contain.sh.
const (
	exitCompleted          = 0
	exitUsage              = 2
	exitTimeout            = 3
	exitUnknownResult      = 4
	exitCleanupPending     = 5
	exitManagerUnavailable = 78
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		usage(stderr)
		return exitUsage
	}
	switch args[0] {
	case "run":
		return runOperation(args[1:], stdout, stderr)
	case envRelayMode:
		return runExecEnv(args[1:], stderr)
	case "capabilities":
		return reportCapabilities(stdout, stderr)
	case "--version", "version":
		fmt.Fprintf(stdout, "sq-supervisor %s\n", version)
		return exitCompleted
	case "-h", "--help", "help":
		usage(stdout)
		return exitCompleted
	default:
		fmt.Fprintf(stderr, "sq-supervisor: unknown command %q\n", args[0])
		usage(stderr)
		return exitUsage
	}
}

func usage(w io.Writer) {
	fmt.Fprint(w, `usage:
  sq-supervisor run --operation-id <id> --state-dir <dir> \
                    --deadline <duration> --stop-grace <duration> \
                    -- <command> [args...]
  sq-supervisor capabilities
  sq-supervisor --version
`)
}
