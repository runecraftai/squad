#!/usr/bin/env bash
# Print the tail of a operator endpoint (bounded, for cheap diagnosis).
# Usage: sq-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy sq-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_HOME="${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_HOME/state}"

# shellcheck source=bin/sq-backend.sh
. "$SCRIPT_DIR/sq-backend.sh"

"$SCRIPT_DIR/sq-guard.sh" || true

RAW_TARGET=$1
T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
N=${2:-40}

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
