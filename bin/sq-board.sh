#!/usr/bin/env bash
# sq-board.sh - mission-planning board (delegates to packages/operation-board).
# See packages/operation-board/bin/sq-board.sh for full documentation.
set -euo pipefail
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
exec "$SCRIPT_DIR/../packages/operation-board/bin/sq-board.sh" "$@"
