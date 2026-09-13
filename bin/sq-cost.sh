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
# Output format (transcript/dir/cwd):
#   input_tokens|output_tokens|cache_read|cache_write|model|cost_usd
#
# `task <task-id>` preserves that legacy line unless `--json` is supplied.
# `report <task-id>` (or `task <task-id> --json`) emits the complete privacy-safe
# report and never includes prompt or response content. Pi sessions are counted
# only when their session header cwd exactly matches the recorded task worktree,
# the task has a recorded window, and its recorded harness is pi or pi-signed.
# This excludes primary sessions and sessions from another base; missing matches
# are reported explicitly. The PR hook is `publish <task-id> <pr-url>`, normally
# called by sq-pr-check after a PR becomes ready, because it survives generated
# PR bodies and can update one marked comment idempotently.
#
# When no transcript is found, the legacy command prints an estimate line.
# The humanized-count and agent-label patterns are based on LangWatch
# (https://github.com/langwatch/langwatch), Apache-2.0 License.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # sourced at runtime
. "$SCRIPT_DIR/sq-cost-lib.sh"
# shellcheck disable=SC1091 # sourced at runtime
. "$SCRIPT_DIR/sq-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage: sq-cost.sh <command> [args...]

Commands:
  task <task-id> [--json]                         Legacy line or complete task report
  report <task-id>                                Complete task report (Markdown)
  publish <task-id> <pr-url>                      Idempotently publish report comment
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

cmd_report() {
  local task_id="${1:?task-id required}" state_dir="${SQUAD_STATE_OVERRIDE:-${SQUAD_BASE:-${SQUAD_HOME:-.}}/state}"
  local session_root="${SQUAD_PI_SESSION_DIR:-$HOME/.pi/agent/sessions}" raw
  raw=$(sq_cost_pi_task_json "$task_id" "$state_dir" "$session_root")
  if [ "${2:-}" = "--json" ]; then
    printf '%s\n' "$raw"
    return 0
  fi
  if ! jq -e '.found == true' >/dev/null 2>&1 <<<"$raw"; then
    local reason
    reason=$(jq -r '.reason // empty' <<<"$raw")
    printf '## Coding agent usage on this pull request\n\nUsage unavailable: %s.\n' "${reason:-no attributable sessions}"
    return 0
  fi
  local enriched model cost mode provider in_tokens out_tokens cache_read cache_write
  enriched=$(mktemp "${TMPDIR:-/tmp}/sq-cost-report.XXXXXX")
  trap 'rm -f "$enriched"' RETURN
  while IFS=$'\t' read -r model provider reported; do
    if [ "$provider" = "opencode-go" ] || [[ "$model" == *opencode-go* ]]; then
      cost="null"; mode="flat-rate subscription"
    elif [ "$reported" != "null" ]; then
      cost="$reported"; mode="provider-recorded"
    else
      in_tokens=$(jq -r --arg m "$model" '.models[]|select(.model==$m)|.input' <<<"$raw")
      out_tokens=$(jq -r --arg m "$model" '.models[]|select(.model==$m)|.output' <<<"$raw")
      cache_read=$(jq -r --arg m "$model" '.models[]|select(.model==$m)|.cache_read' <<<"$raw")
      cache_write=$(jq -r --arg m "$model" '.models[]|select(.model==$m)|.cache_write' <<<"$raw")
      cost=$(sq_cost_estimate "$model" "$in_tokens" "$out_tokens" "$cache_read" "$cache_write")
      mode="estimate"
    fi
    jq --arg m "$model" --arg mode "$mode" --argjson cost "$cost" '.models |= map(if .model == $m then . + {cost:$cost,cost_basis:$mode} else . end)' <<<"$raw" > "$enriched"
    raw=$(cat "$enriched")
  done < <(jq -r '.models[] | [.model,.provider,(.reported_cost|tojson)] | @tsv' <<<"$raw")
  local jq_program
  jq_program=$(cat <<'JQ'
    def humanize:
      if . < 1000 then tostring
      elif . < 1000000 then (((. / 1000 * 10) | round) / 10 | tostring) + " thousand"
      elif . < 1000000000 then (((. / 1000000 * 10) | round) / 10 | tostring) + " million"
      elif . < 1000000000000 then (((. / 1000000000 * 10) | round) / 10 | tostring) + " billion"
      else (((. / 1000000000000 * 10) | round) / 10 | tostring) + " trillion" end;
    def agent_label:
      {pi:"Pi", "pi-signed":"Pi", claude:"Claude Code", codex:"Codex", opencode:"OpenCode", grok:"Grok", kimi:"Kimi", muse:"Muse"} as $labels |
      if $labels[.] then $labels[.]
      else (split("[-_]") | map((.[0:1] | ascii_upcase) + .[1:]) | join(" ")) end;
    def money: if . == null then "not applicable" else ("$" + (.|tostring)) end;
    (.models | map(.total) | add // 0) as $total |
    "## Coding agent usage on this pull request\n\n" +
    "| Contributor | Agent | Sessions | Total tokens | Estimated cost |\n|---|---|---:|---:|---:|\n" +
    ("| Squad task \(.task) | \(.agent | agent_label) | \(.sessions) | \($total | humanize) | " + (([.models[].cost] | map(select(. != null)) | add) | money) + " |\n\n") +
    "### Token and model breakdown\n\n| Model | Input | Output | Cache read | Cache write | Total tokens | Estimated cost |\n|---|---:|---:|---:|---:|---:|---:|\n" +
    ([.models[] | "| \(.model) | \(.input | humanize) | \(.output | humanize) | \(.cache_read | humanize) | \(.cache_write | humanize) | \(.total | humanize) | \(.cost_basis): \(.cost // $na) |\n"] | join("")) +
    "\n_Source: Pi session JSONL usage records, covering the task lifetime from \(.started) through report generation. Costs are provider-recorded where available, otherwise list-price estimates; subscription usage is not represented as spend._"
JQ
  )
  jq -r --arg na "not applicable" "$jq_program" <<<"$raw"
}

cmd_publish() {
  local task_id="${1:?task-id required}" url="${2:?pr-url required}" state_dir="${SQUAD_STATE_OVERRIDE:-${SQUAD_BASE:-${SQUAD_HOME:-.}}/state}"
  local project meta project_registry body number repo
  meta="$state_dir/$task_id.meta"
  project=$(grep '^project=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
  project_registry="${SQUAD_DATA_OVERRIDE:-${SQUAD_BASE:-${SQUAD_HOME:-.}}/data}/projects.md"
  if [ -n "$project" ] && [ -f "$project_registry" ] && grep -F "$project" "$project_registry" | grep -qi 'visiveis ao cliente\|client-visible'; then
    if ! grep -F "$project" "$project_registry" | grep -q '+cost-report'; then
      echo "not published: client-visible project policy" >&2
      return 0
    fi
  fi
  fm_pr_url_parse "$url" || { echo "error: invalid PR URL: repository and number cannot be resolved" >&2; return 1; }
  number="$SQUAD_PR_NUMBER"
  repo="$SQUAD_PR_PATH"
  [ -n "$repo" ] || { echo "error: invalid PR URL: repository cannot be resolved" >&2; return 1; }
  body=$(cmd_report "$task_id")
  body=$(printf '<!-- squad-cost-report -->\n%s' "$body")
  local comments comment_id
  comments=$(sq-gh api "/repos/$repo/issues/$number/comments" --paginate --jq '.[] | select(.body | contains("<!-- squad-cost-report -->")) | [.id,.body] | @tsv' 2>/dev/null || true)
  comment_id=$(printf '%s\n' "$comments" | head -1 | cut -f1)
  if [ -n "$comment_id" ]; then
    sq-gh api PATCH "/repos/$repo/issues/comments/$comment_id" --field "body=$body" >/dev/null
  else
    sq-gh pr comment "$number" --body "$body" >/dev/null
  fi
  echo "published: $url"
}

cmd_task() {
  local task_id="${1:?task-id required}"
  if [ "${2:-}" = "--json" ]; then cmd_report "$task_id" --json; return; fi
  local dir
  dir=$(resolve_task_transcripts "$task_id" || true)

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
  sq_cost_from_transcript "$file" || true
}

cmd_dir() {
  local dir="${1:?directory path required}"
  sq_cost_scan_dir "$dir" || true
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
  report)         shift; cmd_report "$@" ;;
  publish)        shift; cmd_publish "$@" ;;
  transcript)     shift; cmd_transcript "$@" ;;
  dir)            shift; cmd_dir "$@" ;;
  cwd)            shift; cmd_cwd "$@" ;;
  estimate)       shift; cmd_estimate "$@" ;;
  price)          shift; cmd_price "$@" ;;
  pricing-table)  cmd_pricing_table ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
