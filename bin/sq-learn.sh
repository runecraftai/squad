#!/usr/bin/env bash
# Capture a durable operational lesson in data/learnings.md.
# Usage: sq-learn.sh <lesson-text> [--task <id>] [--source <evidence>]
# Lessons are capped at 500 characters and near-duplicate entries are skipped.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-$SQUAD_ROOT}}
DATA=${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}
LEARNINGS=$DATA/learnings.md

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

if [ -n "$TASK" ] && [[ ! $TASK =~ ^[[:alnum:]-]+$ ]]; then
  printf 'warning: task id does not contain only alphanumeric characters and hyphens: %s\n' "$TASK" >&2
fi

# Keep one lesson on one Markdown line.
LESSON=${LESSON//$'\r'/ }
LESSON=${LESSON//$'\n'/ }
while [[ $LESSON == *"  "* ]]; do
  LESSON=${LESSON//  / }
done

if [ "${#LESSON}" -gt 500 ]; then
  LESSON=${LESSON:0:497}...
fi

normalize() {
  local value=$1
  value=${value,,}
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
if [ ! -e "$LEARNINGS" ]; then
  printf '# Learnings (home-local)\n\n' > "$LEARNINGS"
fi

NORMALIZED_LESSON=$(normalize "$LESSON")
if is_duplicate "$NORMALIZED_LESSON"; then
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
printf '%s\n' "$ENTRY" >> "$LEARNINGS"
printf 'lesson captured\n'
