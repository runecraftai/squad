#!/usr/bin/env bash
# sq-dispatch-tune.sh — Analyze operator performance and recommend dispatch profile adjustments.
#
# Reads operator completion data from state/*.status logs and state/*.meta files
# to compute per-profile (harness+model+effort) metrics and output actionable
# recommendations in markdown or JSON format.
#
# Usage:
#   sq-dispatch-tune.sh                       # markdown output, last 30 days
#   sq-dispatch-tune.sh --json                # machine-readable output
#   sq-dispatch-tune.sh --period 60           # analyze last 60 days
#   sq-dispatch-tune.sh --profile claude      # analyze a specific harness
#   sq-dispatch-tune.sh --profile claude/sonnet  # analyze a specific harness/model
#   sq-dispatch-tune.sh --verbose             # include per-task detail
#
# Profile = harness + model + effort (from state/<id>.meta).
# Outcome = done (success) or failed (failure) from state/<id>.status.
# Duration = file birth-to-modification time on state/<id>.status (approximate).
#
# Exit codes: 0 success, 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"

# ── defaults ──────────────────────────────────────────────────────────────

OUTPUT_FORMAT="markdown"
PERIOD_DAYS=30
FILTER_PROFILE=""
VERBOSE=0

# ── usage ─────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: sq-dispatch-tune.sh [OPTIONS]

Analyze operator performance metrics and recommend dispatch profile adjustments.

Options:
  --json              Output in machine-readable JSON (default: markdown)
  --period <days>     Limit analysis window (default: 30)
  --profile <name>    Analyze a specific profile (harness, or harness/model)
  --verbose           Include per-task detail in output
  -h, --help          Show this help

Profiles are harness+model+effort combinations from state/<id>.meta files.
Outcomes are determined from state/<id>.status log final lines (done/failed).

Examples:
  sq-dispatch-tune.sh                          # all profiles, last 30 days
  sq-dispatch-tune.sh --json --period 7        # last 7 days, JSON
  sq-dispatch-tune.sh --profile claude/sonnet  # one model only
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    --period)
      [ $# -ge 2 ] || { echo "error: --period requires a number" >&2; exit 2; }
      PERIOD_DAYS="$2"
      case "$PERIOD_DAYS" in ''|*[!0-9]*)
        echo "error: --period must be a positive integer" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --profile)
      [ $# -ge 2 ] || { echo "error: --profile requires a name" >&2; exit 2; }
      FILTER_PROFILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────

# Extract a key=value from a meta file. Returns empty string if absent.
meta_value() { # <meta_file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Get file birth time (seconds since epoch). Returns 0 if unavailable.
file_birth() { # <path>
  local ts
  ts=$(stat -c %W "$1" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) ts=$(stat -f %SB "$1" 2>/dev/null) ;; esac
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ "$ts" = "0" ] && ts=$(stat -c %Y "$1" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) ts=$(stat -f %m "$1" 2>/dev/null) ;; esac
  echo "${ts:-0}"
}

# Get file mtime (seconds since epoch).
file_mtime() { # <path>
  local ts
  ts=$(stat -c %Y "$1" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) ts=$(stat -f %m "$1" 2>/dev/null) ;; esac
  echo "${ts:-0}"
}

# Format seconds as human-readable duration.
fmt_duration() { # <seconds>
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    echo "${secs}s"
  elif [ "$secs" -lt 3600 ]; then
    printf '%dm%ds' $((secs / 60)) $((secs % 60))
  else
    printf '%dh%dm' $((secs / 3600)) $(((secs % 3600) / 60))
  fi
}

# Escape a string for safe embedding in JSON double-quoted values.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\t/g" | tr '\n' ' '
}

# Epoch seconds for N days ago.
days_ago() { # <days>
  local now
  now=$(date +%s)
  echo $(( now - $1 * 86400 ))
}

# ── data collection ───────────────────────────────────────────────────────

CUTOFF=$(days_ago "$PERIOD_DAYS")

# Collect task records: id harness model effort outcome duration profile
# Stored as tab-separated lines in a temp file.
TASKS_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-tune.XXXXXX")
METRICS_FILE=""
trap 'rm -f "$TASKS_FILE" "$METRICS_FILE"' EXIT
TASKS_COUNT=0

collect_tasks() {
  local meta_file status_file
  local task_id harness model effort outcome duration birth mtime profile

  for status_file in "$STATE"/*.status; do
    [ -f "$status_file" ] || continue

    task_id=$(basename "$status_file" .status)

    # Skip tasks outside the analysis window (use status file mtime as proxy).
    mtime=$(file_mtime "$status_file")
    [ "$mtime" -ge "$CUTOFF" ] 2>/dev/null || continue

    # Determine outcome from the last meaningful status line.
    outcome=$(grep -E '^(done|failed):' "$status_file" 2>/dev/null | tail -1 | cut -d: -f1 || true)
    [ -z "$outcome" ] && continue  # skip tasks with no terminal state

    # Read metadata.
    meta_file="$STATE/$task_id.meta"
    if [ -f "$meta_file" ]; then
      harness=$(meta_value "$meta_file" harness)
      model=$(meta_value "$meta_file" model)
      effort=$(meta_value "$meta_file" effort)
    else
      harness="unknown"
      model="unknown"
      effort="unknown"
    fi

    [ -z "$harness" ] && harness="unknown"
    [ -z "$model" ] && model="unknown"
    [ -z "$effort" ] && effort="unknown"

    # Compute duration from file birth to last modification.
    birth=$(file_birth "$status_file")
    duration=0
    if [ "$birth" -gt 0 ] 2>/dev/null && [ "$mtime" -gt "$birth" ] 2>/dev/null; then
      duration=$(( mtime - birth ))
    fi

    # Build profile key.
    profile="${harness}/${model}/${effort}"

    # Apply profile filter.
    if [ -n "$FILTER_PROFILE" ]; then
      case "$profile" in
        *"$FILTER_PROFILE"*) ;; # match
        *) continue ;;
      esac
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$task_id" "$harness" "$model" "$effort" "$outcome" "$duration" "$profile" \
      >> "$TASKS_FILE"
    TASKS_COUNT=$((TASKS_COUNT + 1))
  done
}

collect_tasks

if [ "$TASKS_COUNT" -eq 0 ]; then
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    echo '{"period_days":'"$PERIOD_DAYS"',"profiles":[],"recommendations":[],"tasks":0}'
  else
    echo "# Dispatch Profile Analysis"
    echo ""
    echo "No completed tasks found in the last ${PERIOD_DAYS} days."
    echo "Try --period with a larger value, or check that state/ contains task data."
  fi
  rm -f "$TASKS_FILE"
  exit 0
fi

# ── metric computation ────────────────────────────────────────────────────

# Aggregate per-profile metrics using awk.
compute_metrics() {
  # Input: tab-separated task records (id, harness, model, effort, outcome, duration, profile)
  # Output: profile|total|success|failure|success_rate|avg_duration
  awk -F'\t' '
  {
    profile = $7
    outcome = $5
    duration = $6 + 0

    total[profile]++
    if (outcome == "done") success[profile]++
    else if (outcome == "failed") failure[profile]++

    sum_duration[profile] += duration
  }
  END {
    for (p in total) {
      s = p in success ? success[p] : 0
      f = p in failure ? failure[p] : 0
      t = total[p]
      rate = (t > 0) ? (s / t) * 100 : 0
      avg = (t > 0) ? sum_duration[p] / t : 0
      printf "%s\t%d\t%d\t%d\t%.1f\t%.0f\n", p, t, s, f, rate, avg
    }
  }' "$TASKS_FILE"
}

# Generate markdown output.
emit_markdown() {
  local metrics_file="$1"
  local profile total success failure rate avg_dur
  local best_rate=0 best_profile="" worst_rate=100 worst_profile=""
  local fastest_dur=999999 fastest_profile="" fastest_rate=0

  echo "# Dispatch Profile Analysis"
  echo ""
  echo "**Period:** last ${PERIOD_DAYS} days"
  echo "**Tasks analyzed:** ${TASKS_COUNT}"
  echo ""

  # Summary table.
  echo "## Per-Profile Metrics"
  echo ""
  echo "| Profile | Tasks | Success Rate | Avg Duration |"
  echo "|---------|------:|-------------:|-------------:|"

  while IFS=$'\t' read -r profile total success failure rate avg_dur; do
    printf '| %s | %s | %.1f%% | %s |' \
      "$profile" "$total" "$rate" "$(fmt_duration "${avg_dur%.*}")"
    echo ""

    # Track best/worst for recommendations.
    if [ "$total" -ge 1 ]; then
      rate_int="${rate%.*}"
      if [ "$rate_int" -gt "${best_rate%.*}" ] 2>/dev/null || [ "$best_rate" = "0" ]; then
        best_rate="$rate"
        best_profile="$profile"
      fi
      if [ "$rate_int" -lt "${worst_rate%.*}" ] 2>/dev/null || [ "$worst_rate" = "100" ]; then
        worst_rate="$rate"
        worst_profile="$profile"
      fi
      avg_int="${avg_dur%.*}"
      if [ "$avg_int" -lt "$fastest_dur" ] 2>/dev/null; then
        fastest_dur="$avg_int"
        fastest_profile="$profile"
        fastest_rate="$rate"
      fi
    fi
  done < "$metrics_file"

  echo ""

  # Recommendations.
  echo "## Recommendations"
  echo ""

  local has_recommendations=0

  # Overperforming profiles: high success rate, fast completion.
  if [ -n "$best_profile" ] && [ "${best_rate%.*}" -ge 80 ] 2>/dev/null; then
    echo "- **Increase usage of ${best_profile}:** ${best_rate}% success rate"
    has_recommendations=1
  fi

  if [ -n "$fastest_profile" ] && [ "$fastest_dur" -lt 999999 ] 2>/dev/null; then
    # Only recommend if not already the best by success rate and has acceptable success rate.
    if [ "$fastest_profile" != "$best_profile" ] && [ "${fastest_rate%.*}" -ge 50 ] 2>/dev/null; then
      echo "- **Increase usage of ${fastest_profile}:** fastest avg completion ($(fmt_duration "$fastest_dur"))"
      has_recommendations=1
    fi
  fi

  # Underperforming profiles: low success rate.
  if [ -n "$worst_profile" ] && [ "${worst_rate%.*}" -lt 50 ] 2>/dev/null; then
    echo "- **Reduce usage of ${worst_profile}:** ${worst_rate}% success rate"
    has_recommendations=1
  fi

  # Consistently failing model/harness combos.
  while IFS=$'\t' read -r profile total success failure rate avg_dur; do
    if [ "$failure" -ge 3 ] 2>/dev/null && [ "$total" -ge 3 ] 2>/dev/null; then
      local fail_pct
      fail_pct=$(awk "BEGIN { printf \"%.0f\", ($failure / $total) * 100 }")
      echo "- **Avoid ${profile}:** ${fail_pct}% failure rate (${failure}/${total} tasks failed)"
      has_recommendations=1
    fi
  done < "$metrics_file"

  if [ "$has_recommendations" -eq 0 ]; then
    echo "- No strong recommendations. All profiles performing within normal range."
  fi

  echo ""

  # Verbose: per-task detail.
  if [ "$VERBOSE" -eq 1 ]; then
    echo "## Task Detail"
    echo ""
    echo "| Task ID | Profile | Outcome | Duration |"
    echo "|---------|---------|---------|----------|"
    sort -t$'\t' -k7,7 -k5,5 "$TASKS_FILE" | while IFS=$'\t' read -r tid _h _m _e outcome dur _p; do
      printf '| %s | %s | %s | %s |\n' "$tid" "$_h/$_m/$_e" "$outcome" "$(fmt_duration "$dur")"
    done
    echo ""
  fi
}

# Generate JSON output.
emit_json() {
  local metrics_file="$1"

  # Build profile JSON array.
  local profiles_json="["
  local first=1
  while IFS=$'\t' read -r profile total success failure rate avg_dur; do
    [ "$first" -eq 0 ] && profiles_json+=","
    first=0
    local escaped
    escaped=$(json_escape "$profile")
    profiles_json+=$(printf '{"profile":"%s","tasks":%s,"success":%s,"failure":%s,"success_rate":%s,"avg_duration_sec":%.0f}' \
      "$escaped" "$total" "$success" "$failure" "$rate" "$avg_dur")
  done < "$metrics_file"
  profiles_json+="]"

  # Build recommendations array.
  local recs_json="["
  local first_rec=1
  local best_rate=0 best_profile="" worst_rate=100 worst_profile=""
  local fastest_dur=999999 fastest_profile="" fastest_rate=0

  while IFS=$'\t' read -r profile total success failure rate avg_dur; do
    rate_int="${rate%.*}"
    avg_int="${avg_dur%.*}"
    if [ "$total" -ge 1 ]; then
      if [ "$rate_int" -gt "${best_rate%.*}" ] 2>/dev/null || [ "$best_rate" = "0" ]; then
        best_rate="$rate"; best_profile="$profile"
      fi
      if [ "$rate_int" -lt "${worst_rate%.*}" ] 2>/dev/null || [ "$worst_rate" = "100" ]; then
        worst_rate="$rate"; worst_profile="$profile"
      fi
      if [ "$avg_int" -lt "$fastest_dur" ] 2>/dev/null; then
        fastest_dur="$avg_int"; fastest_profile="$profile"; fastest_rate="$rate"
      fi
    fi
  done < "$metrics_file"

  local bp ep wp
  bp=$(json_escape "$best_profile")
  ep=$(json_escape "$fastest_profile")
  wp=$(json_escape "$worst_profile")

  if [ -n "$best_profile" ] && [ "${best_rate%.*}" -ge 80 ] 2>/dev/null; then
    [ "$first_rec" -eq 0 ] && recs_json+="," 
    first_rec=0
    recs_json+=$(printf '{"action":"increase","profile":"%s","reason":"%.1f%% success rate"}' \
      "$bp" "$best_rate")
  fi

  if [ -n "$fastest_profile" ] && [ "$fastest_dur" -lt 999999 ] 2>/dev/null && \
     [ "$fastest_profile" != "$best_profile" ] && [ "${fastest_rate%.*}" -ge 50 ] 2>/dev/null; then
    [ "$first_rec" -eq 0 ] && recs_json+="," 
    first_rec=0
    recs_json+=$(printf '{"action":"increase","profile":"%s","reason":"fastest avg completion (%.0fs)"}' \
      "$ep" "$fastest_dur")
  fi

  if [ -n "$worst_profile" ] && [ "${worst_rate%.*}" -lt 50 ] 2>/dev/null; then
    [ "$first_rec" -eq 0 ] && recs_json+="," 
    first_rec=0
    recs_json+=$(printf '{"action":"reduce","profile":"%s","reason":"%.1f%% success rate"}' \
      "$wp" "$worst_rate")
  fi

  while IFS=$'\t' read -r profile total success failure rate avg_dur; do
    if [ "$failure" -ge 3 ] 2>/dev/null && [ "$total" -ge 3 ] 2>/dev/null; then
      local fail_pct ep2
      fail_pct=$(awk "BEGIN { printf \"%.0f\", ($failure / $total) * 100 }")
      ep2=$(json_escape "$profile")
      [ "$first_rec" -eq 0 ] && recs_json+="," 
      first_rec=0
      recs_json+=$(printf '{"action":"avoid","profile":"%s","reason":"%d%% failure rate (%d/%d tasks)"}' \
        "$ep2" "$fail_pct" "$failure" "$total")
    fi
  done < "$metrics_file"

  recs_json+="]"

  # Emit complete JSON.
  printf '{"period_days":%d,"tasks":%d,"profiles":%s,"recommendations":%s}\n' \
    "$PERIOD_DAYS" "$TASKS_COUNT" "$profiles_json" "$recs_json"
}

# ── main ──────────────────────────────────────────────────────────────────

METRICS_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-metrics.XXXXXX")
compute_metrics > "$METRICS_FILE"

if [ "$OUTPUT_FORMAT" = "json" ]; then
  emit_json "$METRICS_FILE"
else
  emit_markdown "$METRICS_FILE"
fi


