#!/usr/bin/env bash
# Consolidate data/learnings.md: deduplicate, remove stale, trim long entries.
# Usage: sq-learnings-consolidate.sh [--apply] [--data-dir <dir>] [--backlog <file>]
# Dry-run by default. With --apply, writes changes after creating a backup.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-$SQUAD_ROOT}}
DATA_DIR=${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}
BACKLOG=""
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --data-dir)
      [ "$#" -ge 2 ] || { printf 'error: --data-dir requires a path\n' >&2; exit 1; }
      DATA_DIR=$2; shift 2 ;;
    --backlog)
      [ "$#" -ge 2 ] || { printf 'error: --backlog requires a path\n' >&2; exit 1; }
      BACKLOG=$2; shift 2 ;;
    -h|--help)
      printf 'Usage: %s [--apply] [--data-dir <dir>] [--backlog <file>]\n' "$(basename "$0")"
      exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

LEARNINGS="$DATA_DIR/learnings.md"

if [ ! -f "$LEARNINGS" ]; then
  printf 'error: learnings file not found: %s\n' "$LEARNINGS" >&2
  exit 1
fi

# --- helpers ----------------------------------------------------------------

normalize() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

date_diff_days() {
  local d1=$1 d2=$2
  local ts1 ts2
  ts1=$(date -d "$d1" +%s 2>/dev/null) || { printf '9999\n'; return; }
  ts2=$(date -d "$d2" +%s 2>/dev/null) || { printf '9999\n'; return; }
  printf '%s\n' $(( (ts1 - ts2) / 86400 ))
}

# Levenshtein-like similarity: return ratio 0.0-1.0 (simplified, good enough
# for short learnings lines).
string_similarity() {
  local a=$1 b=$2
  local len_a=${#a} len_b=${#b}
  if [ "$len_a" -eq 0 ] && [ "$len_b" -eq 0 ]; then
    printf '1.0'; return
  fi
  if [ "$len_a" -eq 0 ] || [ "$len_b" -eq 0 ]; then
    printf '0.0'; return
  fi
  # Quick char-overlap heuristic: count shared characters
  local total=$((len_a + len_b))
  local shared=0
  local i c
  local a_copy="$a"
  for (( i=0; i<len_b; i++ )); do
    c="${b:$i:1}"
    if [[ $a_copy == *"$c"* ]]; then
      shared=$((shared + 1))
      # Remove one occurrence from a_copy to avoid double-counting
      a_copy="${a_copy/}" # remove first occurrence via glob trick
      # Actually: use parameter expansion to remove first match
      case "$a_copy" in
        "$c"*) a_copy="${a_copy#"$c"}" ;;
        *"$c"*) local before="${a_copy%%"$c"*}"
                local after="${a_copy#*"$c"}"
                a_copy="${before}${after}" ;;
      esac
    fi
  done
  printf '%s.%s' $(( shared * 200 / total )) $(( (shared * 2000 / total) % 10 ))
}

# Extract date from a learnings line: - **Title (YYYY-MM-DD):**
extract_date() {
  local line=$1
  if [[ $line =~ \(([0-9]{4}-[0-9]{2}-[0-9]{2})\) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Extract task id from a learnings line: [task: <id>]
extract_task() {
  local line=$1
  if [[ $line =~ \[task:\ ([^]]+)\] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Check if a line contains CRITICAL or NEVER
is_important() {
  local line=$1
  [[ $line == *CRITICAL* ]] || [[ $line == *NEVER* ]]
}

# Build done-task set from backlog
DONE_TASKS_FILE=""
load_done_tasks() {
  local bl=$1 line
  if [ ! -f "$bl" ]; then
    printf 'warning: backlog not found: %s\n' "$bl" >&2
    return
  fi
  DONE_TASKS_FILE=$(mktemp)
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^-\ \[x\]\ ([[:alnum:]-]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" >> "$DONE_TASKS_FILE"
    fi
  done < "$bl"
}

is_done_task() {
  local task=$1
  [ -n "$DONE_TASKS_FILE" ] && [ -f "$DONE_TASKS_FILE" ] && grep -qxF "$task" "$DONE_TASKS_FILE"
}

# Extract lesson content from a learnings line, stripping title/date/metadata.
# Input:  - **Title (YYYY-MM-DD):** content [task: id] [source: evidence]
# Output: content only, normalized.
extract_content() {
  local line=$1
  local content
  if [[ $line =~ ^\-\ \*\*[^\)]*\)\:\*\*\ (.+) ]]; then
    content="${BASH_REMATCH[1]}"
  else
    content="$line"
  fi
  content="${content//\[task: */}"
  content="${content//\[source: */}"
  case "$content" in *\]*) content="${content%?}" ;; esac
  case "$content" in *\]*) content="${content%?}" ;; esac
  normalize "$content"
}

# --- main logic -------------------------------------------------------------

TODAY=$(date '+%Y-%m-%d')
# Read all lines (skip header)
declare -a LINES=()
while IFS= read -r line || [ -n "$line" ]; do
  LINES+=("$line")
done < "$LEARNINGS"

# Load backlog if available
[ -n "$BACKLOG" ] && load_done_tasks "$BACKLOG"
if [ -f "$DATA_DIR/backlog.md" ]; then
  load_done_tasks "$DATA_DIR/backlog.md"
fi
trap '[ -n "$DONE_TASKS_FILE" ] && rm -f "$DONE_TASKS_FILE"' EXIT

# Pass 1: identify removals (age + done tasks)
declare -A REMOVE=()
for (( i=0; i<${#LINES[@]}; i++ )); do
  line="${LINES[$i]}"
  [[ $line == -* ]] || continue  # only process list entries

  # Skip important entries
  if is_important "$line"; then
    continue
  fi

  # Check age-based removal: entry date > 90 days AND references a done task
  entry_date=$(extract_date "$line")
  entry_task=$(extract_task "$line")
  if [ -n "$entry_date" ] && [ -n "$entry_task" ]; then
    if is_done_task "$entry_task"; then
      age=$(date_diff_days "$TODAY" "$entry_date")
      if [ "$age" -ge 90 ]; then
        REMOVE[$i]="stale: task=$entry_task age=${age}d"
        continue
      fi
    fi
  fi
done

# Pass 2: duplicate detection (fuzzy)
for (( i=0; i<${#LINES[@]}; i++ )); do
  [[ ${REMOVE[$i]:-} ]] && continue
  line="${LINES[$i]}"
  [[ $line == -* ]] || continue

  norm_i=$(extract_content "$line")
  for (( j=$((i+1)); j<${#LINES[@]}; j++ )); do
    [[ ${REMOVE[$j]:-} ]] && continue
    other="${LINES[$j]}"
    [[ $other == -* ]] || continue

    norm_j=$(extract_content "$other")

    # Exact duplicate
    if [ "$norm_i" = "$norm_j" ]; then
      REMOVE[$j]="duplicate of entry $((i+1))"
      continue
    fi

    # Fuzzy: check if one contains 80% of the other as contiguous substring
    shorter=$norm_i
    longer=$norm_j
    if [ "${#norm_i}" -gt "${#norm_j}" ]; then
      shorter=$norm_j
      longer=$norm_i
    fi
    required=$(( (${#shorter} * 80 + 99) / 100 ))
    if [ "$required" -gt 0 ] && [ "$required" -le "${#shorter}" ]; then
      candidate="${shorter:0:$required}"
      if [[ $longer == *"$candidate"* ]]; then
        REMOVE[$j]="near-duplicate of entry $((i+1))"
      fi
    fi
  done
done

# Pass 3: trim overly long entries
declare -A TRIM=()
for (( i=0; i<${#LINES[@]}; i++ )); do
  [[ ${REMOVE[$i]:-} ]] && continue
  line="${LINES[$i]}"
  [[ $line == -* ]] || continue
  is_important "$line" && continue

  if [ "${#line}" -gt 500 ]; then
    TRIM[$i]="trimmed from ${#line} to 500 chars"
  fi
done

# --- output report ----------------------------------------------------------

printf '# Learnings Consolidation Report\n\n'
printf 'Date: %s\n' "$TODAY"
printf 'File: %s\n\n' "$LEARNINGS"

total_changes=$(( ${#REMOVE[@]} + ${#TRIM[@]} ))
if [ "$total_changes" -eq 0 ]; then
  printf 'No changes needed. Learnings file is clean.\n'
  exit 0
fi

printf '## Removals (%d)\n\n' "${#REMOVE[@]}"
shown=""
for (( i=0; i<${#LINES[@]}; i++ )); do
  reason="${REMOVE[$i]:-}"
  [ -z "$reason" ] && continue
  shown="${LINES[$i]:0:80}"
  printf -- '- [%d] %s -> %s\n' "$((i+1))" "$shown" "$reason"
done

printf '\n## Trims (%d)\n\n' "${#TRIM[@]}"
for (( i=0; i<${#LINES[@]}; i++ )); do
  reason="${TRIM[$i]:-}"
  [ -z "$reason" ] && continue
  shown="${LINES[$i]:0:80}"
  printf -- '- [%d] %s -> %s\n' "$((i+1))" "$shown" "$reason"
done

printf '\n## Summary\n\n'
printf -- '- Total entries: %d\n' "${#LINES[@]}"
printf -- '- Entries to remove: %d\n' "${#REMOVE[@]}"
printf -- '- Entries to trim: %d\n' "${#TRIM[@]}"
printf -- '- Preserved (important/untouched): %d\n' "$(( ${#LINES[@]} - ${#REMOVE[@]} - ${#TRIM[@]} ))"

if [ "$APPLY" -eq 0 ]; then
  printf '\nDry run. Use --apply to make changes.\n'
  exit 0
fi

# --- apply changes ----------------------------------------------------------

# Backup
BACKUP="$LEARNINGS.bak"
cp "$LEARNINGS" "$BACKUP"
printf '\nBackup created: %s\n' "$BACKUP"

# Build new file
{
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
  done < "$LEARNINGS"
} > "$LEARNINGS.tmp"

# Rewrite in place: skip removed lines, trim long ones
: > "$LEARNINGS"
while IFS= read -r line || [ -n "$line" ]; do
  # Find this line's index
  found_idx=-1
  for (( i=0; i<${#LINES[@]}; i++ )); do
    if [ "${LINES[$i]}" = "$line" ]; then
      found_idx=$i
      break
    fi
  done

  if [ "$found_idx" -ge 0 ] && [ -n "${REMOVE[$found_idx]:-}" ]; then
    # Skip removed line
    continue
  fi

  if [ "$found_idx" -ge 0 ] && [ -n "${TRIM[$found_idx]:-}" ]; then
    # Trim to 500 chars: keep prefix up to the 500th char, add ellipsis
    trimmed="${line:0:497}..."
    printf '%s\n' "$trimmed"
  else
    printf '%s\n' "$line"
  fi
done < "$LEARNINGS.tmp"
rm -f "$LEARNINGS.tmp"

printf 'Changes applied.\n'
