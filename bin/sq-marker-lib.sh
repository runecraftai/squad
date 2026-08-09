#!/usr/bin/env bash
# sq-marker-lib.sh - compatibility entry point for from-squad routing.
#
# bin/sq-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and the established from-squad compatibility
# carrier. Existing callers source this path so they do not need a flag-day
# migration. No side effects on source. set -u / set -e safe.

_SQUAD_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-operational-input.sh
. "$_SQUAD_MARKER_LIB_DIR/sq-operational-input.sh"
unset _SQUAD_MARKER_LIB_DIR
