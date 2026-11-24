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
//   sq-supervisor run --operation-id <id> --state-dir <dir> \
//                     --deadline <duration> --stop-grace <duration> \
//                     --stdout <file> --stderr <file> -- <command> [args...]
//   sq-supervisor capabilities
//   sq-supervisor --version
//
// `run` prints one JSON outcome object on stdout and exits with a status from
// the outcome enum below. It never reports a completed operation without the
// unit's own durable completion record, and never reports a timed-out operation
// as the command's own exit status.
//
// Exit status:
//   0   operation completed; the command's own status is in the outcome record
//   2   usage error
//   3   the deadline was reached and the operation was stopped by the manager
//   4   the unit's result could not be read (unknown-result; do not retry blind)
//   5   the unit's group still holds processes after the stop grace
//   78  strict Linux mode is required and no working systemd user manager exists
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
                    --stdout <file> --stderr <file> -- <command> [args...]
  sq-supervisor capabilities
  sq-supervisor --version
`)
}
