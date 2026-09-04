#!/usr/bin/env bash
# Capture a durable operational lesson in data/learnings.md.
# Usage: sq-learn.sh <lesson-text> [--task <id>] [--source <evidence>]
# Lessons are capped at 500 characters and near-duplicate entries are skipped.
# Captures are refused when the startup-memory budget would be exceeded.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-$SQUAD_ROOT}}
DATA=${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}
CONFIG=${SQUAD_CONFIG_OVERRIDE:-$SQUAD_BASE/config}
LEARNINGS=$DATA/learnings.md

# shellcheck source=bin/sq-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/sq-startup-memory-budget-lib.sh"

usage() {
  printf 'Usage: %s <lesson-text> [--task <id>] [--source <evidence>]\n' "$(basename "$0")" >&2
}

if [ "${1:-}" = '--help' ] || [ "${1:-}" = '-h' ]; then
  usage
  exit 0
fi
if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

LESSON=$1
shift
TASK=
SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      TASK=$2
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      SOURCE=$2
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

one_line() {
  local value=$1
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  while [[ $value == *"  "* ]]; do
    value=${value//  / }
  done
  printf '%s' "$value"
}

# Keep one lesson on one Markdown line.
LESSON=$(one_line "$LESSON")
TASK=$(one_line "$TASK")
SOURCE=$(one_line "$SOURCE")

if [ -n "$TASK" ] && [[ ! $TASK =~ ^[[:alnum:]-]+$ ]]; then
  printf 'warning: task id does not contain only alphanumeric characters and hyphens: %s\n' "$TASK" >&2
fi

if [ "${#LESSON}" -gt 500 ]; then
  LESSON=${LESSON:0:497}...
fi

normalize() {
  local value=$1
  value=$(printf '%s' "$value" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  while [[ $value == *"  "* ]]; do
    value=${value//  / }
  done
  while [[ $value == ' '* ]]; do value=${value# }; done
  while [[ $value == *' ' ]]; do value=${value% }; done
  printf '%s' "$value"
}

# A candidate is a contiguous substring covering at least 80% of the lesson.
is_duplicate() {
  local lesson_normalized=$1 existing line candidate required start
  required=$(((${#lesson_normalized} * 80 + 99) / 100))
  [ "$required" -gt 0 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    existing=$(normalize "$line")
    start=0
    while [ $((start + required)) -le "${#lesson_normalized}" ]; do
      candidate=${lesson_normalized:start:required}
      if [[ $existing == *"$candidate"* ]]; then
        return 0
      fi
      start=$((start + 1))
    done
  done < "$LEARNINGS"
  return 1
}

mkdir -p "$DATA"
export SQUAD_STATE_OVERRIDE=$DATA
# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"
LEARNINGS_LOCK="$DATA/.learnings.lock"
fm_lock_acquire_wait "$LEARNINGS_LOCK"
trap 'fm_lock_release "$LEARNINGS_LOCK" || true' EXIT
trap 'exit 1' HUP INT TERM

if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
  if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
    printf 'error: invalid startup-memory budget - %s\n' "$SQUAD_STARTUP_MEMORY_BUDGET_ERROR" >&2
    exit 1
  fi
  BUDGET=$SQUAD_STARTUP_MEMORY_BUDGET_VALUE
else
  BUDGET=$SQUAD_STARTUP_MEMORY_BUDGET_DEFAULT
fi

measure_memory_file() {
  local path=$1
  if ! fm_startup_memory_measure_file "$path" >/dev/null; then
    printf 'error: cannot inspect startup-memory file - %s\n' "$SQUAD_STARTUP_MEMORY_BUDGET_ERROR" >&2
    return 1
  fi
}

measure_memory_file "$DATA/commander.md"
COMMANDER_TOKENS=$SQUAD_STARTUP_MEMORY_MEASURE_TOKENS
measure_memory_file "$DATA/commander-shared.md"
SHARED_TOKENS=$SQUAD_STARTUP_MEMORY_MEASURE_TOKENS
measure_memory_file "$LEARNINGS"
LEARNINGS_BYTES=$SQUAD_STARTUP_MEMORY_MEASURE_BYTES

NORMALIZED_LESSON=$(normalize "$LESSON")
if [ -f "$LEARNINGS" ] && is_duplicate "$NORMALIZED_LESSON"; then
  printf 'duplicate skipped\n'
  exit 0
fi

TITLE=${LESSON:0:50}
TITLE=${TITLE//$'\r'/ }
TITLE=${TITLE//$'\n'/ }
while [[ $TITLE == *"  "* ]]; do TITLE=${TITLE//  / }; done
while [[ $TITLE == ' '* ]]; do TITLE=${TITLE# }; done
while [[ $TITLE == *' ' ]]; do TITLE=${TITLE% }; done
DATE=$(date '+%Y-%m-%d')
ENTRY="- **$TITLE ($DATE):** $LESSON"
[ -n "$TASK" ] && ENTRY="$ENTRY [task: $TASK]"
[ -n "$SOURCE" ] && ENTRY="$ENTRY [source: $SOURCE]"

ENTRY_BYTES=$(printf '%s\n' "$ENTRY" | LC_ALL=C wc -c | tr -d '[:space:]')
HEADER_BYTES=0
if [ ! -e "$LEARNINGS" ]; then
  HEADER_BYTES=$(printf '# Learnings (home-local)\n\n' | LC_ALL=C wc -c | tr -d '[:space:]')
fi
PROJECTED_LEARNINGS_BYTES=$((LEARNINGS_BYTES + HEADER_BYTES + ENTRY_BYTES))
PROJECTED_LEARNINGS_TOKENS=$(fm_startup_memory_estimated_tokens_for_bytes "$PROJECTED_LEARNINGS_BYTES")
PROJECTED_TOTAL=$((COMMANDER_TOKENS + SHARED_TOKENS + PROJECTED_LEARNINGS_TOKENS))
if ! fm_startup_memory_decimal_le "$PROJECTED_TOTAL" "$BUDGET"; then
  printf 'error: startup-memory budget would be exceeded; lesson not captured\n' >&2
  exit 1
fi

if [ ! -e "$LEARNINGS" ]; then
  printf '# Learnings (home-local)\n\n' > "$LEARNINGS"
fi
printf '%s\n' "$ENTRY" >> "$LEARNINGS"
printf 'lesson captured\n'
