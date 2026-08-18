#!/usr/bin/env bash
# sq-breaker.sh — Circuit-breaker CLI for Squad tasks.
#
# Reads recent status signals for a task and evaluates the circuit-breaker
# policy. Returns a verdict (healthy/steering/constrained/stopped) with reasons.
#
# Usage:
#   bin/sq-breaker.sh evaluate <task-id>          # evaluate from status file signals
#   bin/sq-breaker.sh status <task-id>            # print current breaker state
#   bin/sq-breaker.sh reset <task-id>             # reset breaker to healthy
#   bin/sq-breaker.sh evaluate --signals <args>   # direct signal input (for testing)
#
# Options for --signals:
#   --current-level <level>
#   --repeat-count <n>
#   --repeat-tool <name>
#   --error-count <n>
#   --no-progress-beats <n>
#   --progressing <0|1>
#
# Output format (evaluate): "<level> <action> <reason>"
# Output format (status):   "<level> <state-persisted>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # sourced at runtime
. "$SCRIPT_DIR/sq-breaker-lib.sh"

usage() {
  cat <<'EOF'
Usage: sq-breaker.sh <command> [args...]

Commands:
  evaluate <task-id>              Evaluate breaker from status file signals
  evaluate --signals [options]    Evaluate with explicit signal input
  status <task-id>                Print current breaker state
  reset <task-id>                 Reset breaker to healthy

Signal options (for --signals):
  --current-level <level>         Current breaker level (default: healthy)
  --repeat-count <n>              Consecutive identical tool calls (default: 0)
  --repeat-tool <name>            Name of the repeating tool (default: unknown)
  --error-count <n>               Consecutive errors (default: 0)
  --no-progress-beats <n>         Consecutive no-progress beats (default: 0)
  --progressing <0|1>             Recent forward progress? (default: 1)
EOF
}

# ── Derive signals from Squad status file ──────────────────────────────────

# Count consecutive identical trailing lines in a status file.
# Prints: repeat_count|repeat_tool_name
derive_repeat_signals() {
  local status_file=$1
  if [ ! -f "$status_file" ]; then
    echo "0|unknown"
    return
  fi

  local lines last_line count=1
  # Read last 20 lines (enough for pattern detection)
  lines=$(tail -20 "$status_file" 2>/dev/null || true)
  last_line=$(tail -1 "$status_file" 2>/dev/null || true)

  if [ -z "$last_line" ]; then
    echo "0|unknown"
    return
  fi

  # Count consecutive identical trailing lines
  local prev="$last_line"
  local total
  total=$(echo "$lines" | wc -l | tr -d ' ')
  count=1
  while [ "$count" -lt "$total" ] && [ "$count" -lt 20 ]; do
    local candidate
    candidate=$(echo "$lines" | tail -$((count + 1)) | head -1)
    if [ "$candidate" = "$prev" ]; then
      count=$((count + 1))
    else
      break
    fi
  done

  # Extract tool-like name from the status line (heuristic)
  local tool_name="status-line"
  case "$last_line" in
    *working:*)  tool_name="working-poll" ;;
    *signal:*)   tool_name="signal-event" ;;
    *check:*)    tool_name="check-poll" ;;
    *heartbeat:*) tool_name="heartbeat" ;;
    *stale:*)    tool_name="stale-wake" ;;
  esac

  echo "${count}|${tool_name}"
}

# Count consecutive error/failure lines.
derive_error_signals() {
  local status_file=$1
  if [ ! -f "$status_file" ]; then
    echo "0"
    return
  fi

  local count=0
  while IFS= read -r line; do
    case "$line" in
      *failed:*|*error:*|*blocked:*)
        count=$((count + 1))
        ;;
      *)
        count=0  # reset on non-error
        ;;
    esac
  done < <(tail -20 "$status_file" 2>/dev/null || true)

  echo "$count"
}

# Check if recent lines show progress (working/done vs stuck patterns).
derive_progress() {
  local status_file=$1
  if [ ! -f "$status_file" ]; then
    echo "1"
    return
  fi

  local last_line
  last_line=$(tail -1 "$status_file" 2>/dev/null || true)
  case "$last_line" in
    *done:*|*working:*|*signal:*check:*)
      echo "1"  # progress
      ;;
    *)
      echo "0"  # no clear progress
      ;;
  esac
}

# ── Commands ───────────────────────────────────────────────────────────────

cmd_evaluate() {
  local state_dir="${SQUAD_STATE_OVERRIDE:-state}"

  if [ "${1:-}" = "--signals" ]; then
    shift
    # Direct signal mode (for testing/manual use)
    local current_level="healthy" repeat_count=0 repeat_tool="unknown"
    local error_count=0 no_progress_beats=0 progressing=1

    while [ $# -gt 0 ]; do
      case "$1" in
        --current-level)   current_level="${2:?}"; shift 2 ;;
        --repeat-count)    repeat_count="${2:?}"; shift 2 ;;
        --repeat-tool)     repeat_tool="${2:?}"; shift 2 ;;
        --error-count)     error_count="${2:?}"; shift 2 ;;
        --no-progress-beats) no_progress_beats="${2:?}"; shift 2 ;;
        --progressing)     progressing="${2:?}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
      esac
    done

    local result
    result=$(sq_breaker_evaluate "$current_level" "$repeat_count" "$repeat_tool" \
                                  "$error_count" "$no_progress_beats" "$progressing")
    local verdict action reason
    verdict=$(echo "$result" | cut -d'|' -f1)
    action=$(echo "$result" | cut -d'|' -f2)
    reason=$(echo "$result" | cut -d'|' -f3-)
    echo "$verdict $action $reason"
    return
  fi

  # Task-based evaluation
  local task_id="${1:?task-id required}"
  local status_file="$state_dir/$task_id.status"

  # Read current breaker state
  local state_line
  state_line=$(sq_breaker_read_state "$task_id")
  local current_level repeat_count error_count no_progress_beats
  current_level=$(echo "$state_line" | cut -d'|' -f1)
  # repeat_key ($2) is read for completeness; fresh value written back below
  repeat_count=$(echo "$state_line" | cut -d'|' -f3)
  error_count=$(echo "$state_line" | cut -d'|' -f4)
  no_progress_beats=$(echo "$state_line" | cut -d'|' -f5)

  # Derive signals from status file
  local repeat_info new_repeat_count new_repeat_tool
  repeat_info=$(derive_repeat_signals "$status_file")
  new_repeat_count=$(echo "$repeat_info" | cut -d'|' -f1)
  new_repeat_tool=$(echo "$repeat_info" | cut -d'|' -f2)

  local new_error_count
  new_error_count=$(derive_error_signals "$status_file")

  local progressing
  progressing=$(derive_progress "$status_file")

  # Update no-progress beats counter
  if [ "$progressing" -eq 0 ]; then
    no_progress_beats=$((no_progress_beats + 1))
  else
    no_progress_beats=0
  fi

  # Evaluate policy
  local result
  result=$(sq_breaker_evaluate "$current_level" "$new_repeat_count" "$new_repeat_tool" \
                                "$new_error_count" "$no_progress_beats" "$progressing")
  local verdict action reason
  verdict=$(echo "$result" | cut -d'|' -f1)
  action=$(echo "$result" | cut -d'|' -f2)
  reason=$(echo "$result" | cut -d'|' -f3-)

  # Persist new state
  sq_breaker_write_state "$task_id" "$verdict" "$new_repeat_tool" \
                          "$new_repeat_count" "$new_error_count" "$no_progress_beats"

  echo "$verdict $action $reason"
}

cmd_status() {
  local task_id="${1:?task-id required}"
  local state_line
  state_line=$(sq_breaker_read_state "$task_id")
  local level
  level=$(echo "$state_line" | cut -d'|' -f1)
  echo "$level"
}

cmd_reset() {
  local task_id="${1:?task-id required}"
  sq_breaker_write_state "$task_id" "healthy" "" "0" "0" "0"
  echo "healthy"
}

# ── Main ───────────────────────────────────────────────────────────────────

case "${1:-}" in
  evaluate)  shift; cmd_evaluate "$@" ;;
  status)    shift; cmd_status "$@" ;;
  reset)     shift; cmd_reset "$@" ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
