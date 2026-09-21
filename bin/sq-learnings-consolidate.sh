#!/usr/bin/env bash
# Consolidate data/learnings.md: deduplicate, remove stale by age, trim long entries.
# Stale entries are archived to data/learnings.md.archive (never deleted).
# Undated entries are exempt from age-based retirement.
# Usage: sq-learnings-consolidate.sh [--apply] [--data-dir <dir>]
# Dry-run by default. With --apply, writes changes after creating a backup.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-$SQUAD_ROOT}}
DATA_DIR=${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --data-dir)
      [ "$#" -ge 2 ] || { printf 'error: --data-dir requires a path\n' >&2; exit 1; }
      DATA_DIR=$2; shift 2 ;;
    -h|--help)
      printf 'Usage: %s [--apply] [--data-dir <dir>]\n' "$(basename "$0")"
      exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

LEARNINGS="$DATA_DIR/learnings.md"
ARCHIVE="$DATA_DIR/learnings.md.archive"

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

# Extract date from a learnings line: - **Title (YYYY-MM-DD):**
extract_date() {
  local line=$1
  if [[ $line =~ \(([0-9]{4}-[0-9]{2}-[0-9]{2})\) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Check if a line contains CRITICAL or NEVER
is_important() {
  local line=$1
  [[ $line == *CRITICAL* ]] || [[ $line == *NEVER* ]]
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

# Retirement age threshold in days.
RETIREMENT_AGE=60

# --- main logic -------------------------------------------------------------

TODAY=$(date '+%Y-%m-%d')
# Read all lines (skip header)
declare -a LINES=()
while IFS= read -r line || [ -n "$line" ]; do
  LINES+=("$line")
done < "$LEARNINGS"

# Pass 1: identify removals by age (>=60 days, undated exempt)
declare -A REMOVE=()
for (( i=0; i<${#LINES[@]}; i++ )); do
  line="${LINES[$i]}"
  [[ $line == -* ]] || continue  # only process list entries

  # Skip important entries (CRITICAL / NEVER)
  if is_important "$line"; then
    continue
  fi

  # Extract the date; undated entries are exempt from age-based retirement
  entry_date=$(extract_date "$line")
  if [ -z "$entry_date" ]; then
    continue
  fi

  age=$(date_diff_days "$TODAY" "$entry_date")
  if [ "$age" -ge "$RETIREMENT_AGE" ]; then
    REMOVE[$i]="stale: age=${age}d (>= ${RETIREMENT_AGE}d)"
    continue
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

# Build the replacement from the indexed input array. Writing directly to a
# sibling temporary file avoids truncating the source before it has been read,
# and indexing preserves duplicate lines correctly.
OUTPUT="$LEARNINGS.tmp"
ARCHIVE_TMP="$LEARNINGS.archive.tmp"
trap 'rm -f -- "$OUTPUT" "$ARCHIVE_TMP"' EXIT
: > "$OUTPUT"
: > "$ARCHIVE_TMP"
for (( i=0; i<${#LINES[@]}; i++ )); do
  line="${LINES[$i]}"
  if [ -n "${REMOVE[$i]:-}" ]; then
    # Archive removed entries (skip header lines)
    [[ $line == -* ]] && printf '%s\n' "$line" >> "$ARCHIVE_TMP"
    continue
  fi

  if [ -n "${TRIM[$i]:-}" ]; then
    # Trim to 500 chars: keep prefix up to the 500th char, add ellipsis
    trimmed="${line:0:497}..."
    printf '%s\n' "$trimmed" >> "$OUTPUT"
  else
    printf '%s\n' "$line" >> "$OUTPUT"
  fi
done
mv -f -- "$OUTPUT" "$LEARNINGS"

# Append archived entries to the archive file (create if absent)
if [ -s "$ARCHIVE_TMP" ]; then
  if [ ! -f "$ARCHIVE" ]; then
    printf '# Learnings Archive\n\n' > "$ARCHIVE"
  fi
  cat "$ARCHIVE_TMP" >> "$ARCHIVE"
  printf 'Archived %d entry/entries to %s\n' "$(wc -l < "$ARCHIVE_TMP")" "$ARCHIVE"
fi
rm -f "$ARCHIVE_TMP"

printf 'Changes applied.\n'
