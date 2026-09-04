#!/usr/bin/env bash
# Capture a learning and append it to data/learnings.md with metadata.
#
# Usage:
#   sq-learn.sh <lesson-text> [--task <id>] [--source <evidence>]
#
# Appends a dated learning entry to $SQUAD_BASE/data/learnings.md.
# The title is derived from the first ~40 chars of the lesson text.
# Lesson text is capped at 500 characters; longer text is truncated.
# A basic dedup check skips entries whose first 80 chars already exist.
#
# Exit codes: 0=appended, 1=skipped-duplicate, 2=error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
LEARNINGS_FILE="$SQUAD_BASE/data/learnings.md"

MAX_CHARS=500
DEDUP_PREFIX_LEN=80

usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | grep -v '^set ' | sed 's/^# \?//'
  exit 2
}

# --- parse args ---
TASK=""
SOURCE=""
TEXT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --task)
      [ $# -ge 2 ] || { echo "error: --task requires a value" >&2; exit 2; }
      TASK="$2"; shift 2 ;;
    --source)
      [ $# -ge 2 ] || { echo "error: --source requires a value" >&2; exit 2; }
      SOURCE="$2"; shift 2 ;;
    --help|-h) usage ;;
    -*)
      echo "error: unknown option: $1" >&2; exit 2 ;;
    *)
      if [ -z "$TEXT" ]; then
        TEXT="$1"
      else
        echo "error: unexpected argument: $1" >&2; exit 2
      fi
      shift ;;
  esac
done

if [ -z "$TEXT" ]; then
  echo "error: lesson text is required" >&2
  usage
fi

# --- truncate to max chars ---
if [ "${#TEXT}" -gt "$MAX_CHARS" ]; then
  TEXT="${TEXT:0:$MAX_CHARS}…"
fi

# --- build title from first words of text ---
# Use first ~40 chars, trimmed to word boundary
TITLE_LEN=40
TITLE="${TEXT:0:$TITLE_LEN}"
# Trim to last space to avoid mid-word cut
if [ "${#TEXT}" -gt "$TITLE_LEN" ]; then
  LAST_SPACE="${TITLE% *}"
  if [ -n "$LAST_SPACE" ]; then
    TITLE="$LAST_SPACE"
  fi
fi
# Capitalize first letter
TITLE="$(echo "${TITLE:0:1}" | tr '[:lower:]' '[:upper:]')${TITLE:1}"

# --- today's date ---
DATE="$(date +%Y-%m-%d)"

# --- assemble entry ---
ENTRY="- **${TITLE} (${DATE}):** ${TEXT}"
if [ -n "$TASK" ]; then
  ENTRY="${ENTRY} [task: ${TASK}]"
fi
if [ -n "$SOURCE" ]; then
  ENTRY="${ENTRY} [source: ${SOURCE}]"
fi

# --- ensure learnings file exists with header ---
if [ ! -f "$LEARNINGS_FILE" ]; then
  mkdir -p "$(dirname "$LEARNINGS_FILE")"
  printf '# Learnings (home-local)\n\n' > "$LEARNINGS_FILE"
fi

# --- dedup check ---
# Compare first DEDUP_PREFIX_LEN chars of the lesson text against existing entries
CHECK_TEXT="${TEXT:0:$DEDUP_PREFIX_LEN}"
if grep -qF "$CHECK_TEXT" "$LEARNINGS_FILE" 2>/dev/null; then
  echo "skipped: similar entry already exists" >&2
  exit 1
fi

# --- append ---
printf '%s\n\n' "$ENTRY" >> "$LEARNINGS_FILE"
echo "appended: ${TITLE}"
