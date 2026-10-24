#!/usr/bin/env bash
# sq-dispatch-tune.sh — Analyze operator performance and recommend dispatch profile adjustments.
#
# Reads completed-task evidence log-first. data/<id>/dispatch.jsonl, the private
# dispatch log written by sq-dispatch-log.sh, supplies the lane, the recommended
# and the dispatched profile, and the outcome. A task without a log falls back to
# state/<id>.meta for its profile and state/<id>.status for its outcome.
#
# Usage:
#   sq-dispatch-tune.sh                          # markdown output, last 30 days
#   sq-dispatch-tune.sh --json                   # machine-readable output
#   sq-dispatch-tune.sh --period 60              # analyze last 60 days
#   sq-dispatch-tune.sh --profile claude         # analyze a specific harness
#   sq-dispatch-tune.sh --profile claude/sonnet  # analyze a specific harness/model
#   sq-dispatch-tune.sh --verbose                # include per-task detail
#   sq-dispatch-tune.sh --by-lane                # group by decision lane
#   sq-dispatch-tune.sh --fallback-rate          # share of provider or quota failures
#
# Profile = harness + model + effort. The dispatched profile is the log's spawn
# row; a log without one uses state/<id>.meta, then the decision's recommended
# profile. A task without a log uses state/<id>.meta. With none of these, the
# profile is "(no-profile)".
# Lane = the decision profile name recorded at intake; "(no-profile)" when the
# decision recorded only a reason, or the task has no log.
# Outcome = done or landed (success) or failed, from the log's outcome rows,
# else the last done/failed line of state/<id>.status. A released outcome (teardown)
# counts toward its lane and profile dispatch totals, never as a success or failure;
# success rate is done over done plus failed, as in the lane table.
# Fallback = a log's failure_class of provider or quota, even on a released
# task (guard and other are misses). Without one, the last done, failed, blocked,
# or paused status line, classified as the writer does. Teardown removes the status
# file, so a torn-down task without a failure_class is "unknown".
# Duration = log span from first to last event, else file birth-to-modification
# time on state/<id>.status (approximate).
# Credential guard: a harness, model, effort, lane, or recommendation that looks
# like a credential or token prints as "redacted", never verbatim.
#
# Exit codes: 0 success, 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}"

# Credential or token shapes; matching values are never printed. Long token runs are checked by has_secret_run.
SECRET_SHAPE_RE='(^|[^A-Za-z0-9])(sk|pk|ghp|gho|ghs|ghu|ghr|xox[abprs]|glpat)[-_][A-Za-z0-9_-]{8,}|github_pat_[A-Za-z0-9_]{8,}|AKIA[0-9A-Z]{12,}|AIza[0-9A-Za-z_-]{20,}|eyJ[A-Za-z0-9_-]{8,}[.]|bearer[ ]|(token|secret|passwd|password|api[_-]?key|credential)[=:]'

# ── defaults ──────────────────────────────────────────────────────────────

OUTPUT_FORMAT="markdown"
PERIOD_DAYS=30
FILTER_PROFILE=""
VERBOSE=0
BY_LANE=0
FALLBACK_RATE=0

# ── usage ─────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: sq-dispatch-tune.sh [OPTIONS]

Analyze operator performance metrics and recommend dispatch profile adjustments.

Options:
  --json              Output in machine-readable JSON (default: markdown)
  --period <days>     Limit analysis window (default: 30)
  --profile <name>    Analyze a specific profile (harness, or harness/model)
  --by-lane           Group by decision lane: dispatches, chosen models, off-recommendation count
  --fallback-rate     Report the share of tasks whose status hit a provider or quota failure
  --verbose           Include per-task detail in output
  -h, --help          Show this help

Profiles are harness+model+effort, read from data/<id>/dispatch.jsonl (spawn row first,
then state/<id>.meta, then the decision's recommended profile) or, for tasks without
a log, from state/<id>.meta.
Outcomes come from the log's outcome rows or the state/<id>.status final line (done/failed).

Examples:
  sq-dispatch-tune.sh                            # all profiles, last 30 days
  sq-dispatch-tune.sh --json --period 7          # last 7 days, JSON
  sq-dispatch-tune.sh --profile claude/sonnet    # one model only
  sq-dispatch-tune.sh --by-lane --fallback-rate  # lanes with fallback rates
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
    --by-lane)
      BY_LANE=1
      shift
      ;;
    --fallback-rate)
      FALLBACK_RATE=1
      shift
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
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g" | tr '\n' ' '
}

# Escape pipes so a value cannot break a markdown table row.
md_cell() {
  printf '%s' "$1" | sed 's/|/\\|/g'
}

# Percentage with one decimal and a sign, or "n/a" when the denominator is zero.
pct_text() { # <numerator> <denominator>
  awk -v n="$1" -v d="$2" 'BEGIN { if (d > 0) printf "%.1f%%", n * 100 / d; else printf "n/a" }'
}

# Percentage as a JSON number, or null when the denominator is zero.
pct_json() { # <numerator> <denominator>
  awk -v n="$1" -v d="$2" 'BEGIN { if (d > 0) printf "%.1f", n * 100 / d; else printf "null" }'
}

# Epoch seconds for N days ago.
days_ago() { # <days>
  local now
  now=$(date +%s)
  echo $(( now - $1 * 86400 ))
}

# Last terminal verb (done or failed) of a status file, if any.
status_outcome() { # <status_file>
  grep -E '^(done|failed):' "$1" 2>/dev/null | tail -1 | cut -d: -f1 || true
}

# True when a run of 32 or more token characters is not exactly a commit SHA (40 or 64 hex).
has_secret_run() { # <value>
  local run
  while IFS= read -r run; do
    [[ $run =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] || return 0
  done < <(printf '%s' "$1" | grep -E -o -- '[A-Za-z0-9_+/]{32,}' || true)
  return 1
}

# Print a value, or "redacted" when it looks like a credential or token.
redact_shape() { # <value>
  if printf '%s' "$1" | grep -E -i -q -- "$SECRET_SHAPE_RE" || has_secret_run "$1"; then
    echo redacted
  else
    printf '%s' "$1"
  fi
}

# ── data collection ───────────────────────────────────────────────────────

CUTOFF=$(days_ago "$PERIOD_DAYS")

# Collect task records: id harness model effort outcome duration profile lane fallback recommended
# Stored as tab-separated lines in a temp file.
TASKS_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-tune.XXXXXX")
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-logs.XXXXXX")
METRICS_FILE=""
LANES_FILE=""
STATUS_BUCKETS_FILE=""
RESOLVED_FILE=""
LANE_ROWS=()
trap 'rm -f "$TASKS_FILE" "$LOG_FILE" "$METRICS_FILE" "$LANES_FILE" "$STATUS_BUCKETS_FILE" "$RESOLVED_FILE"' EXIT
TASKS_COUNT=0
LOG_READER=0
if command -v python3 >/dev/null 2>&1; then
  LOG_READER=1
fi

# Append one task record after the --profile filter.
record_task() { # <id> <harness> <model> <effort> <outcome> <duration> <lane> <fallback> <recommended> [profile]
  local harness model effort lane recommended profile
  harness=$(redact_shape "$2"); model=$(redact_shape "$3"); effort=$(redact_shape "$4")
  lane=$(redact_shape "$7"); recommended=$(redact_shape "$9")
  profile="${10:-$harness/$model/$effort}"
  if [ -n "$FILTER_PROFILE" ]; then
    case "$profile" in
      *"$FILTER_PROFILE"*) ;; # match
      *) return 0 ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$harness" "$model" "$effort" "$5" "$6" "$profile" "$lane" "$8" "$recommended" >> "$TASKS_FILE"
  TASKS_COUNT=$((TASKS_COUNT + 1))
}

# Read every data/<id>/dispatch.jsonl once through python3. Only the fields this
# report uses leave the reader: never brief text, reasons, or quota payloads.
# Rows are unit-separator delimited so empty fields survive `read`.
collect_log_rows() {
  [ "$LOG_READER" -eq 1 ] || return 0
  if ! python3 - "$DATA" "$CUTOFF" > "$LOG_FILE" 2>/dev/null <<'PY'
import datetime
import json
import os
import re
import sys

data_dir, cutoff = sys.argv[1], int(sys.argv[2])
id_pattern = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


def text(value):
    if not isinstance(value, str):
        return ""
    return "".join(ch if ord(ch) >= 32 else " " for ch in value)


def moment(value):
    try:
        return datetime.datetime.fromisoformat(value).timestamp()
    except (TypeError, ValueError):
        return None


FAILURE_CLASSES = ("provider", "quota", "guard", "other")


def triple(row):
    if not isinstance(row, dict):
        return ["", "", ""]
    return [text(row.get(key)) for key in ("harness", "model", "effort")]


try:
    names = sorted(os.listdir(data_dir))
except OSError:
    names = []

for name in names:
    folder = os.path.join(data_dir, name)
    path = os.path.join(folder, "dispatch.jsonl")
    if not id_pattern.fullmatch(name) or os.path.islink(folder):
        continue
    if os.path.islink(path) or not os.path.isfile(path):
        continue
    try:
        in_window = int(os.stat(path).st_mtime) >= cutoff
        decision = None
        spawn = None
        results = set()
        failure = ""
        stamps = []
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                when = moment(row.get("timestamp"))
                if when is not None:
                    stamps.append(when)
                event = row.get("event")
                if event == "decision":
                    decision = row
                elif event == "spawn":
                    spawn = row
                elif event == "outcome" and isinstance(row.get("result"), str):
                    results.add(row["result"])
                    failure = row["failure_class"] if row.get("failure_class") in FAILURE_CLASSES else ""
    except OSError:
        continue
    profile = decision.get("profile") if isinstance(decision, dict) else None
    lane = text(profile) if isinstance(profile, str) and profile else "(no-profile)"
    if results & {"done", "landed"}:
        outcome = "done"
    elif "failed" in results:
        outcome = "failed"
    elif "released" in results:
        outcome = "released"
    else:
        outcome = "none"
    span = int(max(stamps) - min(stamps)) if len(stamps) > 1 else 0
    columns = [name, lane, *triple(decision), *triple(spawn), outcome, failure, str(span), "1" if in_window else "0"]
    sys.stdout.write("\x1f".join(columns) + "\n")
PY
  then
    LOG_READER=0
    : > "$LOG_FILE"
  fi
}

# Tasks with a dispatch log: the log decides lane, profile, and recommendation.
collect_logged_tasks() {
  local task_id lane rec_h rec_m rec_e spawn_h spawn_m spawn_e log_outcome log_class duration in_window
  local outcome harness model effort recommended meta_file fallback profile

  while IFS=$'\x1f' read -r task_id lane rec_h rec_m rec_e spawn_h spawn_m spawn_e log_outcome log_class duration in_window; do
    [ "$in_window" = "1" ] || continue

    outcome="$log_outcome"
    case "$outcome" in
      done|failed|released) ;;
      *) continue ;; # no terminal state in the log
    esac

    case "$outcome:$log_class" in
      *:provider|*:quota) fallback="hit" ;;
      *:guard|*:other|done:) fallback="miss" ;;
      *) fallback="unknown" ;;
    esac

    harness=""; model=""; effort=""
    if [ -n "$spawn_h" ]; then
      harness="$spawn_h"; model="$spawn_m"; effort="$spawn_e"
    else
      meta_file="$STATE/$task_id.meta"
      if [ -f "$meta_file" ]; then
        harness=$(meta_value "$meta_file" harness)
        model=$(meta_value "$meta_file" model)
        effort=$(meta_value "$meta_file" effort)
      fi
      if [ -z "$harness$model$effort" ]; then
        harness="$rec_h"; model="$rec_m"; effort="$rec_e"
      fi
    fi
    profile=""
    if [ -z "$harness$model$effort" ]; then
      profile="(no-profile)"
    fi
    harness=${harness:-unknown}; model=${model:-unknown}; effort=${effort:-unknown}

    recommended="-"
    if [ -n "$rec_h" ]; then
      recommended="$rec_h/$rec_m/$rec_e"
    fi
    record_task "$task_id" "$harness" "$model" "$effort" "$outcome" "${duration:-0}" \
      "$lane" "$fallback" "$recommended" "$profile"
  done < "$LOG_FILE"
}

# Tasks without a dispatch log: state/<id>.meta supplies the profile.
collect_status_tasks() {
  local status_file task_id mtime outcome meta_file harness model effort birth duration fallback

  for status_file in "$STATE"/*.status; do
    [ -f "$status_file" ] || continue

    task_id=$(basename "$status_file" .status)

    # A task whose log was read was already collected from that log.
    case $'\n'"$LOGGED_IDS"$'\n' in
      *$'\n'"$task_id"$'\n'*) continue ;;
    esac

    # Skip tasks outside the analysis window (use status file mtime as proxy).
    mtime=$(file_mtime "$status_file")
    [ "$mtime" -ge "$CUTOFF" ] 2>/dev/null || continue

    # Determine outcome from the last meaningful status line.
    outcome=$(status_outcome "$status_file")
    [ -z "$outcome" ] && continue  # skip tasks with no terminal state

    # Read metadata.
    harness=""; model=""; effort=""
    meta_file="$STATE/$task_id.meta"
    if [ -f "$meta_file" ]; then
      harness=$(meta_value "$meta_file" harness)
      model=$(meta_value "$meta_file" model)
      effort=$(meta_value "$meta_file" effort)
    fi
    harness=${harness:-unknown}; model=${model:-unknown}; effort=${effort:-unknown}

    # Compute duration from file birth to last modification.
    birth=$(file_birth "$status_file")
    duration=0
    if [ "$birth" -gt 0 ] 2>/dev/null && [ "$mtime" -gt "$birth" ] 2>/dev/null; then
      duration=$(( mtime - birth ))
    fi

    fallback=unknown
    if [ ! -L "$status_file" ]; then
      fallback="pending"
    fi
    record_task "$task_id" "$harness" "$model" "$effort" "$outcome" "$duration" \
      "(no-profile)" "$fallback" "-"
  done
}

collect_tasks() {
  collect_log_rows
  LOGGED_IDS=$(cut -d $'\x1f' -f1 "$LOG_FILE")
  collect_logged_tasks
  collect_status_tasks
}

# Classify each status file with the writer's last-terminal-line rule in one python3
# pass, then join the buckets onto the rows marked pending. Rows print hit, miss, or
# unknown only, never the status text; unknown when python3 is missing.
resolve_status_fallbacks() {
  [ "$TASKS_COUNT" -gt 0 ] || return 0
  STATUS_BUCKETS_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-status.XXXXXX")
  RESOLVED_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-resolved.XXXXXX")
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SCRIPT_DIR" "$STATE" "$CUTOFF" > "$STATUS_BUCKETS_FILE" 2>/dev/null <<'PY' || true
import os
import sys
sys.path.insert(0, sys.argv[1])
from sq_dispatch_failure import status_failure_class

state, cutoff = sys.argv[2], int(sys.argv[3])
try:
    names = sorted(os.listdir(state))
except OSError:
    names = []
for name in names:
    if not name.endswith(".status"):
        continue
    task_id = name[: -len(".status")]
    path = os.path.join(state, name)
    if "\t" in task_id or "\n" in task_id or os.path.islink(path) or not os.path.isfile(path):
        continue
    if int(os.stat(path).st_mtime) < cutoff:
        continue
    print(f"{task_id}\t{status_failure_class(path) or 'none'}")
PY
  fi
  if awk -F'\t' -v OFS='\t' -v buckets="$STATUS_BUCKETS_FILE" '
    FILENAME == buckets { bucket[$1] = $2; next }
    $9 == "pending" {
      b = ($1 in bucket) ? bucket[$1] : ""
      $9 = (b == "provider" || b == "quota") ? "hit" : (b == "none" || b == "guard" || b == "other") ? "miss" : "unknown"
    }
    { print }' "$STATUS_BUCKETS_FILE" "$TASKS_FILE" > "$RESOLVED_FILE"; then
    mv "$RESOLVED_FILE" "$TASKS_FILE"
  else
    rm -f "$RESOLVED_FILE"
  fi
}

collect_tasks
resolve_status_fallbacks

if [ "$TASKS_COUNT" -eq 0 ]; then
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    extras=""
    if [ "$BY_LANE" -eq 1 ]; then
      extras+=',"lanes":[]'
    fi
    if [ "$FALLBACK_RATE" -eq 1 ]; then
      extras+=',"fallback":{"hits":0,"observed":0,"unknown":0,"rate":null}'
    fi
    echo '{"period_days":'"$PERIOD_DAYS"',"profiles":[],"recommendations":[],"tasks":0'"$extras"'}'
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
  # Input: tab-separated task records (id, harness, model, effort, outcome, duration, profile, lane, fallback, recommended)
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
      rate = (s + f > 0) ? sprintf("%.1f", (s / (s + f)) * 100) : "-"
      avg = (t > 0) ? sum_duration[p] / t : 0
      printf "%s\t%d\t%d\t%d\t%s\t%.0f\n", p, t, s, f, rate, avg
    }
  }' "$TASKS_FILE"
}

# Per-lane rows: L lane dispatches successes failures off-recommendation fallback-hits observed;
# C lane chosen-profile dispatches. Sorted so each lane's L row precedes its C rows.
compute_lanes() {
  awk -F'\t' '
  {
    lane = $8
    total[lane]++
    if ($5 == "done") success[lane]++
    else if ($5 == "failed") failure[lane]++
    if ($10 != "-" && $10 != $7) off[lane]++
    if ($9 == "hit") hit[lane]++
    if ($9 == "hit" || $9 == "miss") observed[lane]++
    chosen[lane SUBSEP $7]++
  }
  END {
    for (l in total)
      printf "L\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", l, total[l], success[l] + 0, failure[l] + 0, off[l] + 0, hit[l] + 0, observed[l] + 0
    for (k in chosen) {
      split(k, parts, SUBSEP)
      printf "C\t%s\t%s\t%d\n", parts[1], parts[2], chosen[k]
    }
  }' "$TASKS_FILE" | sort -t$'\t' -k2,2 -k1,1r -k3,3
}

# Fallback counts as "hits observed unknown", optionally for one lane.
fallback_totals() { # [lane]
  LANE_FILTER="${1:-}" awk -F'\t' '
    BEGIN { lane = ENVIRON["LANE_FILTER"] }
    lane != "" && $8 != lane { next }
    $9 == "hit" { hits++ }
    $9 == "hit" || $9 == "miss" { observed++ }
    $9 == "unknown" { unknown++ }
    END { printf "%d %d %d\n", hits + 0, observed + 0, unknown + 0 }' "$TASKS_FILE"
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
    printf '| %s | %s | %s | %s |' \
      "$profile" "$total" "$(pct_text "$success" $((success + failure)))" "$(fmt_duration "${avg_dur%.*}")"
    echo ""

    # Track best/worst for recommendations; released-only profiles have no rate.
    if [ $((success + failure)) -ge 1 ]; then
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

  if [ "$BY_LANE" -eq 1 ]; then
    emit_lanes_markdown
  fi

  if [ "$FALLBACK_RATE" -eq 1 ]; then
    emit_fallback_markdown
  fi

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
    local decided=$((success + failure))
    if [ "$failure" -ge 3 ] 2>/dev/null && [ "$decided" -ge 3 ] 2>/dev/null; then
      local fail_pct
      fail_pct=$(awk "BEGIN { printf \"%.0f\", ($failure / $decided) * 100 }")
      echo "- **Avoid ${profile}:** ${fail_pct}% failure rate (${failure}/${decided} tasks failed)"
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
    sort -t$'\t' -k7,7 -k5,5 "$TASKS_FILE" | while IFS=$'\t' read -r tid _h _m _e outcome dur _p _rest; do
      printf '| %s | %s | %s | %s |\n' "$(redact_shape "$tid")" "$_h/$_m/$_e" "$outcome" "$(fmt_duration "$dur")"
    done
    echo ""
  fi
}

# Per-lane table: what each decision lane recommended, what was dispatched, and how it fared.
emit_lanes_markdown() {
  local row crow kind lane total success failure off hits observed chosen
  local ckind clane cprofile ccount
  echo "## Lanes"
  echo ""
  echo "A lane is the decision profile recorded at intake; (no-profile) covers decisions that recorded only a reason and tasks without a log."
  echo ""
  if [ "$FALLBACK_RATE" -eq 1 ]; then
    echo "| Lane | Dispatches | Chosen Models | Off Recommendation | Success Rate | Fallback Rate |"
    echo "|------|-----------:|---------------|-------------------:|-------------:|--------------:|"
  else
    echo "| Lane | Dispatches | Chosen Models | Off Recommendation | Success Rate |"
    echo "|------|-----------:|---------------|-------------------:|-------------:|"
  fi

  for row in "${LANE_ROWS[@]}"; do
    IFS=$'\t' read -r kind lane total success failure off hits observed <<< "$row"
    [ "$kind" = "L" ] || continue
    chosen=""
    for crow in "${LANE_ROWS[@]}"; do
      IFS=$'\t' read -r ckind clane cprofile ccount <<< "$crow"
      if [ "$ckind" = "C" ] && [ "$clane" = "$lane" ]; then
        chosen+="${chosen:+, }${cprofile} x${ccount}"
      fi
    done
    printf '| %s | %s | %s | %s | %s |' \
      "$(md_cell "$lane")" "$total" "$(md_cell "$chosen")" "$off" "$(pct_text "$success" $((success + failure)))"
    if [ "$FALLBACK_RATE" -eq 1 ]; then
      printf ' %s |' "$(pct_text "$hits" "$observed")"
    fi
    echo ""
  done
  echo ""
}

# Fallback summary: how often a run hit a provider or quota failure while its status file was still present.
emit_fallback_markdown() {
  local hits observed unknown
  read -r hits observed unknown < <(fallback_totals)
  echo "## Fallback Rate"
  echo ""
  echo "A fallback is a provider or quota failure, from the log's failure_class or else a blocked, paused, or failed status line."
  echo "A logged done task without a failure_class is clean; a released or failed one without a failure_class is unknown."
  echo ""
  echo "- **Observed:** ${observed} of $((observed + unknown)) tasks (failure class or status file present)"
  echo "- **Provider or quota fallbacks:** ${hits}"
  echo "- **Fallback rate:** $(pct_text "$hits" "$observed") of observed tasks"
  echo ""
}

# Fallback object for JSON, optionally for one lane.
fallback_json() { # [lane]
  local hits observed unknown
  read -r hits observed unknown < <(fallback_totals "${1:-}")
  printf '{"hits":%s,"observed":%s,"unknown":%s,"rate":%s}' \
    "$hits" "$observed" "$unknown" "$(pct_json "$hits" "$observed")"
}

# Lane array for JSON: one object per decision lane with its chosen profiles.
lanes_json() {
  local row crow kind lane total success failure off hits observed chosen out="[" first=1
  local ckind clane cprofile ccount cfirst lane_json
  for row in "${LANE_ROWS[@]}"; do
    IFS=$'\t' read -r kind lane total success failure off hits observed <<< "$row"
    [ "$kind" = "L" ] || continue
    chosen="["
    cfirst=1
    for crow in "${LANE_ROWS[@]}"; do
      IFS=$'\t' read -r ckind clane cprofile ccount <<< "$crow"
      if [ "$ckind" = "C" ] && [ "$clane" = "$lane" ]; then
        [ "$cfirst" -eq 1 ] || chosen+=","
        cfirst=0
        chosen+=$(printf '{"profile":"%s","dispatches":%s}' "$(json_escape "$cprofile")" "$ccount")
      fi
    done
    chosen+="]"
    lane_json=$(printf '{"lane":"%s","dispatches":%s,"success_rate":%s,"off_recommendation":%s,"chosen":%s' \
      "$(json_escape "$lane")" "$total" "$(pct_json "$success" $((success + failure)))" "$off" "$chosen")
    if [ "$FALLBACK_RATE" -eq 1 ]; then
      lane_json+=$(printf ',"fallback":%s' "$(fallback_json "$lane")")
    fi
    lane_json+="}"
    [ "$first" -eq 1 ] || out+=","
    first=0
    out+="$lane_json"
  done
  out+="]"
  printf '%s' "$out"
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
      "$escaped" "$total" "$success" "$failure" "$(pct_json "$success" $((success + failure)))" "$avg_dur")
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
    if [ $((success + failure)) -ge 1 ]; then
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
    local decided=$((success + failure))
    if [ "$failure" -ge 3 ] 2>/dev/null && [ "$decided" -ge 3 ] 2>/dev/null; then
      local fail_pct ep2
      fail_pct=$(awk "BEGIN { printf \"%.0f\", ($failure / $decided) * 100 }")
      ep2=$(json_escape "$profile")
      [ "$first_rec" -eq 0 ] && recs_json+=","
      first_rec=0
      recs_json+=$(printf '{"action":"avoid","profile":"%s","reason":"%d%% failure rate (%d/%d tasks)"}' \
        "$ep2" "$fail_pct" "$failure" "$decided")
    fi
  done < "$metrics_file"

  recs_json+="]"

  # Optional sections, present only when their flag was given.
  local extras=""
  if [ "$BY_LANE" -eq 1 ]; then
    extras+=",\"lanes\":$(lanes_json)"
  fi
  if [ "$FALLBACK_RATE" -eq 1 ]; then
    extras+=",\"fallback\":$(fallback_json)"
  fi

  # Emit complete JSON.
  printf '{"period_days":%d,"tasks":%d,"profiles":%s,"recommendations":%s%s}\n' \
    "$PERIOD_DAYS" "$TASKS_COUNT" "$profiles_json" "$recs_json" "$extras"
}

# ── main ──────────────────────────────────────────────────────────────────

METRICS_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-metrics.XXXXXX")
compute_metrics > "$METRICS_FILE"

if [ "$BY_LANE" -eq 1 ]; then
  LANES_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-dispatch-lanes.XXXXXX")
  compute_lanes > "$LANES_FILE"
  while IFS= read -r lane_line; do
    LANE_ROWS+=("$lane_line")
  done < "$LANES_FILE"
fi

if [ "$OUTPUT_FORMAT" = "json" ]; then
  emit_json "$METRICS_FILE"
else
  emit_markdown "$METRICS_FILE"
fi
