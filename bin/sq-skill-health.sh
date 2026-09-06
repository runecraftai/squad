#!/usr/bin/env bash
# Generate a health report for all installed skills.
# Scans .agents/skills/ and skills/ directories for SKILL.md files and reports
# name, description, file size, last modified, test coverage, usage in the last
# 30 days, and trigger phrases.
#
# Usage:
#   sq-skill-health.sh              # full scan, markdown table
#   sq-skill-health.sh --json       # machine-readable JSON
#   sq-skill-health.sh --skill afk  # report on a single skill
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"

MODE="table"
FILTER_SKILL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      MODE="json"
      shift
      ;;
    --skill)
      [ $# -ge 2 ] || { echo "error: --skill requires a name" >&2; exit 2; }
      FILTER_SKILL="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: sq-skill-health.sh [--json] [--skill <name>]\n'
      exit 0
      ;;
    *)
      echo "error: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# Collect skill directories: both .agents/skills/ and skills/
declare -a SKILL_DIRS=()
[ -d "$SQUAD_BASE/.agents/skills" ] && SKILL_DIRS+=("$SQUAD_BASE/.agents/skills")
[ -d "$SQUAD_BASE/skills" ] && SKILL_DIRS+=("$SQUAD_BASE/skills")

if [ ${#SKILL_DIRS[@]} -eq 0 ]; then
  if [ "$MODE" = "json" ]; then
    printf '[]\n'
  else
    echo "No skill directories found."
  fi
  exit 0
fi

# Extract a field from YAML frontmatter between --- lines.
# Usage: extract_field <file> <field>
extract_field() {
  local file="$1" field="$2"
  awk -v field="$field" '
    /^---$/ { if (in_fm) exit; in_fm=1; next }
    in_fm && $0 ~ "^"field":" {
      sub("^[[:space:]]*"field":[[:space:]]*\"?", "", $0)
      gsub(/[[:space:]]*\"?[[:space:]]*$/, "", $0)
      print
      exit
    }
  ' "$file"
}

# Extract the description (may be multi-line with >- folding).
# Returns the first paragraph of the description value.
extract_description() {
  local file="$1"
  awk '
    /^---$/ { if (in_fm) exit; in_fm=1; next }
    in_fm && /^[[:space:]]*description:/ {
      line = $0
      sub(/^[[:space:]]*description:[[:space:]]*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      # strip surrounding quotes if present
      if (line ~ /^"/ && line ~ /"$/) {
        sub(/^"/, "", line)
        sub(/"$/, "", line)
      }
      if (line != "" && line !~ /^>/) {
        print line
        exit
      }
      # multi-line (> or >-)
      folding = 1
      next
    }
    folding && /^[[:space:]]+/ {
      gsub(/^[[:space:]]+/, "")
      print
      exit
    }
  ' "$file"
}

# Extract trigger lines from the frontmatter (lines matching "triggers:" or "- ")
# The trigger field may be a list or a paragraph.
extract_triggers() {
  local file="$1"
  awk '
    /^---$/ { if (in_fm) exit; in_fm=1; next }
    in_fm && /^[[:space:]]*triggers:/ || /^[[:space:]]*trigger:/ {
      folding = 1
      next
    }
    folding && /^[[:space:]]*-[[:space:]]*/ {
      gsub(/^[[:space:]]*-[[:space:]]*/, "")
      printf "%s\n", $0
    }
    folding && /^[[:space:]]*Do NOT use for:/ {
      folding = 0
    }
    folding && /^[[:space:]]*description:/ {
      folding = 0
    }
  ' "$file"
}

# Also extract triggers from the description block when they appear as
# "Triggers: ..." sentences.
extract_triggers_from_desc() {
  local file="$1"
  awk '
    /^---$/ { if (in_fm) { exit } else { in_fm=1; next } }
    in_fm && /^[[:space:]]*description:/ { desc_start=1 }
    desc_start && /Triggers:/ {
      sub(/.*Triggers:[[:space:]]*/, "")
      gsub(/"/, "", $0)
      print
      exit
    }
    desc_start && /^[[:space:]]+/ { next }
    desc_start && /^[[:space:]]*[^ ]/ && !/Triggers:/ { exit }
  ' "$file"
}

# Check if a skill has matching test files.
# Looks for tests/<skill-name>* or tests/*<skill-name>*.
has_tests() {
  local skill_name="$1"
  local tests_dir="$SQUAD_BASE/tests"
  [ -d "$tests_dir" ] || return 1
  # Check exact prefix match or substring match
  if find "$tests_dir" -maxdepth 1 -name "${skill_name}*" -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  if find "$tests_dir" -maxdepth 1 -name "*${skill_name}*" -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

# Check if a skill has been referenced in state/*.status from the last 30 days.
has_been_used() {
  local skill_name="$1"
  local status_dir="$STATE"
  [ -d "$status_dir" ] || return 1
  local cutoff
  cutoff=$(date -d "30 days ago" +%s 2>/dev/null) || return 1
  local found=0
  local f
  for f in "$status_dir"/*.status; do
    [ -f "$f" ] || continue
    # Skip files older than 30 days
    local mtime
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
    [ "$mtime" -ge "$cutoff" ] || continue
    if grep -qi "$skill_name" "$f" 2>/dev/null; then
      found=1
      break
    fi
  done
  return $(( ! found ))
}

# Process one skill directory, printing structured output.
process_skill() {
  local skill_dir="$1"
  local skill_md="$skill_dir/SKILL.md"
  [ -f "$skill_md" ] || return 0

  local name desc file_size last_mod triggers test_count used_str used_flag

  name=$(basename "$skill_dir")
  desc=$(extract_description "$skill_md")
  [ -z "$desc" ] && desc=$(extract_field "$skill_md" "description")

  # File size in bytes
  file_size=$(stat -c %s "$skill_md" 2>/dev/null || stat -f z "$skill_md" 2>/dev/null) || file_size="?"

  # Last modified
  last_mod=$(date -r "$skill_md" +%Y-%m-%d 2>/dev/null || stat -f "%Sm" -t "%Y-%m-%d" "$skill_md" 2>/dev/null) || last_mod="?"

  # Triggers
  triggers=$(extract_triggers "$skill_md")
  if [ -z "$triggers" ]; then
    triggers=$(extract_triggers_from_desc "$skill_md")
  fi

  # Tests
  if has_tests "$name"; then
    test_count="yes"
  else
    test_count="no"
  fi

  # Usage in last 30 days
  if has_been_used "$name"; then
    used_str="yes"
    used_flag=1
  else
    used_str="no"
    used_flag=0
  fi

  if [ "$MODE" = "json" ]; then
    # Escape JSON strings
    local jname jdesc jtriggers
    jname=$(printf '%s' "$name" | sed 's/"/\\"/g')
    jdesc=$(printf '%s' "$desc" | sed 's/"/\\"/g' | head -c 200)
    jtriggers=$(printf '%s' "$triggers" | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|$//')
    printf '{"name":"%s","description":"%s","size_bytes":%s,"last_modified":"%s","has_tests":%s,"used_last_30d":%s,"triggers":"%s"}\n' \
      "$jname" "$jdesc" "$file_size" "$last_mod" \
      "$([ "$test_count" = "yes" ] && echo true || echo false)" \
      "$([ "$used_flag" = 1 ] && echo true || echo false)" \
      "$jtriggers"
  else
    # Markdown table row
    # Truncate description for table display
    local short_desc
    short_desc=$(printf '%s' "$desc" | head -c 80)
    [ ${#desc} -gt 80 ] && short_desc="${short_desc}..."
    printf '| %s | %s | %s | %s | %s | %s |\n' \
      "$name" "$short_desc" "${file_size}B" "$last_mod" "$test_count" "$used_str"
  fi
}

# Main output
if [ "$MODE" = "json" ]; then
  echo "["
fi

HEADER_PRINTED=0
for dir in "${SKILL_DIRS[@]}"; do
  for skill_dir in "$dir"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    # Apply filter if specified
    if [ -n "$FILTER_SKILL" ] && [ "$skill_name" != "$FILTER_SKILL" ]; then
      continue
    fi
    if [ "$MODE" = "table" ] && [ "$HEADER_PRINTED" -eq 0 ]; then
      echo "| Skill | Description | Size | Modified | Tests | Used (30d) |"
      echo "|-------|-------------|------|----------|-------|------------|"
      HEADER_PRINTED=1
    fi
    process_skill "$skill_dir"
  done
done

if [ "$MODE" = "json" ]; then
  echo "]"
fi

if [ "$HEADER_PRINTED" -eq 0 ] && [ "$MODE" = "table" ]; then
  if [ -n "$FILTER_SKILL" ]; then
    echo "Skill not found: $FILTER_SKILL"
  else
    echo "No skills found."
  fi
fi
