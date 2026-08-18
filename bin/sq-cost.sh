#!/usr/bin/env bash
# sq-cost.sh — Transcript-derived cost estimation for Squad tasks.
#
# Reads real operator transcripts and prices them per model to get
# per-operation cost. Degrades gracefully when no transcript exists.
#
# Ported from munder-difflin's src/main/transcript.ts + src/main/pricing.ts
# (MIT, Chaitanya Giri). Adapted for Squad.
#
# Usage:
#   bin/sq-cost.sh task <task-id>              # cost for a task's endpoint
#   bin/sq-cost.sh transcript <path.jsonl>     # cost for one transcript
#   bin/sq-cost.sh dir <path>                  # cost for all transcripts in dir
#   bin/sq-cost.sh cwd <working-dir>           # cost for a cwd's Claude transcripts
#   bin/sq-cost.sh estimate <model> <in> <out> [<cache_read>] [<cache_write>]
#                                              # quick cost estimate
#   bin/sq-cost.sh price <model>               # show pricing for a model
#
# Output format (task/transcript/dir/cwd):
#   input_tokens|output_tokens|cache_read|cache_write|model|cost_usd
#
# When no transcript is found, prints an estimate line with [estimate] label.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # sourced at runtime
. "$SCRIPT_DIR/sq-cost-lib.sh"

usage() {
  cat <<'EOF'
Usage: sq-cost.sh <command> [args...]

Commands:
  task <task-id>                                  Cost from task's recorded endpoint
  transcript <path.jsonl>                         Cost for one JSONL transcript
  dir <path>                                      Cost for all transcripts in directory
  cwd <working-dir>                               Cost for Claude transcripts by cwd
  estimate <model> <in> <out> [<cache_read>] [<cache_write>]
                                                  Quick cost estimate
  price <model>                                   Show pricing table for a model
  pricing-table                                   Dump the full pricing table
EOF
}

# ── Resolve transcript location for a task ─────────────────────────────────

# Given a task id, find where its transcripts live by reading its meta file.
resolve_task_transcripts() {
  local task_id="${1:?task-id required}"
  local state_dir="${SQUAD_STATE_OVERRIDE:-state}"
  local meta_file="$state_dir/$task_id.meta"

  if [ ! -f "$meta_file" ]; then
    echo ""
    return 1
  fi

  local harness model worktree
  harness=$(grep '^harness=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2 || true)
  worktree=$(grep '^worktree=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2 || true)
  model=$(grep '^model=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2 || true)

  case "${harness:-}" in
    claude)
      # Claude stores transcripts at ~/.claude/projects/<project-key>/
      if [ -n "$worktree" ]; then
        sq_cost_resolve_dir "$worktree"
      fi
      ;;
    pi|pi-signed)
      # Pi uses Claude's backend; transcripts may be in Claude's dir
      if [ -n "$worktree" ]; then
        sq_cost_resolve_dir "$worktree"
      fi
      ;;
    *)
      # Other harnesses: no local transcript format yet
      echo ""
      ;;
  esac
}

# ── Commands ───────────────────────────────────────────────────────────────

cmd_task() {
  local task_id="${1:?task-id required}"
  local dir
  dir=$(resolve_task_transcripts "$task_id")

  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    # No transcript found — report as estimate from meta
    local state_dir="${SQUAD_STATE_OVERRIDE:-state}"
    local meta_file="$state_dir/$task_id.meta"
    local model=""

    if [ -f "$meta_file" ]; then
      model=$(grep '^model=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2 || true)
    fi

    local cost
    cost=$(sq_cost_estimate "${model:-}" 0 0 0 0)
    echo "0|0|0|0|${model:-unknown}|${cost} [estimate]"
    return 0
  fi

  local result
  result=$(sq_cost_scan_dir "$dir")
  echo "$result"
}

cmd_transcript() {
  local file="${1:?transcript path required}"
  sq_cost_from_transcript "$file"
}

cmd_dir() {
  local dir="${1:?directory path required}"
  sq_cost_scan_dir "$dir"
}

cmd_cwd() {
  local cwd="${1:?cwd required}"
  local dir
  dir=$(sq_cost_resolve_dir "$cwd")

  if [ ! -d "$dir" ]; then
    echo "0|0|0|0||0.000000"
    return 0
  fi

  sq_cost_scan_dir "$dir"
}

cmd_estimate() {
  local model="${1:?model required}"
  local in="${2:-0}"
  local out="${3:-0}"
  local cr="${4:-0}"
  local cw="${5:-0}"

  local cost
  cost=$(sq_cost_estimate "$model" "$in" "$out" "$cr" "$cw")
  echo "${in}|${out}|${cr}|${cw}|${model}|${cost}"
}

cmd_price() {
  local model="${1:?model required}"
  local prices
  prices=$(sq_cost_price_for "$model")
  local p_in p_out p_cr p_cw
  p_in=$(echo "$prices" | cut -d'|' -f1)
  p_out=$(echo "$prices" | cut -d'|' -f2)
  p_cr=$(echo "$prices" | cut -d'|' -f3)
  p_cw=$(echo "$prices" | cut -d'|' -f4)

  echo "Model: $model"
  echo "  Input:       \$$p_in/M tokens"
  echo "  Output:      \$$p_out/M tokens"
  echo "  Cache read:  \$$p_cr/M tokens"
  echo "  Cache write: \$$p_cw/M tokens"
}

cmd_pricing_table() {
  echo "Squad Cost Pricing Table (USD per million tokens)"
  echo "================================================="
  echo ""
  printf "%-20s %10s %10s %12s %12s\n" "Model" "Input" "Output" "Cache Read" "Cache Write"
  printf "%-20s %10s %10s %12s %12s\n" "-----" "-----" "------" "----------" "-----------"

  for model in "claude-opus-4" "claude-sonnet-4" "claude-haiku-4" \
               "gpt-4o" "gpt-4.1" "o3" "o4-mini" \
               "gemini-2.5-pro" "gemini-2.5-flash" \
               "grok-3" "kimi-k2" "codex-mini"; do
    local prices
    prices=$(sq_cost_price_for "$model")
    local p_in p_out p_cr p_cw
    p_in=$(echo "$prices" | cut -d'|' -f1)
    p_out=$(echo "$prices" | cut -d'|' -f2)
    p_cr=$(echo "$prices" | cut -d'|' -f3)
    p_cw=$(echo "$prices" | cut -d'|' -f4)
    printf "%-20s %10s %10s %12s %12s\n" "$model" "\$$p_in" "\$$p_out" "\$$p_cr" "\$$p_cw"
  done
}

# ── Main ───────────────────────────────────────────────────────────────────

case "${1:-}" in
  task)           shift; cmd_task "$@" ;;
  transcript)     shift; cmd_transcript "$@" ;;
  dir)            shift; cmd_dir "$@" ;;
  cwd)            shift; cmd_cwd "$@" ;;
  estimate)       shift; cmd_estimate "$@" ;;
  price)          shift; cmd_price "$@" ;;
  pricing-table)  cmd_pricing_table ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
