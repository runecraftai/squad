#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine Squad
# primary whose current harness session has not already acquired the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_HOME="${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_HOME/state}"

# shellcheck source=bin/sq-gate-refuse-lib.sh
. "$SCRIPT_DIR/sq-gate-refuse-lib.sh"
# shellcheck source=bin/sq-primary-scope-lib.sh
. "$SCRIPT_DIR/sq-primary-scope-lib.sh"
# shellcheck source=bin/sq-operational-input.sh
. "$SCRIPT_DIR/sq-operational-input.sh"

fm_is_gate_agent "$SQUAD_ROOT" && exit 0
fm_primary_scope_matches "$SQUAD_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

lock_is_in_ancestry && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/sq-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
