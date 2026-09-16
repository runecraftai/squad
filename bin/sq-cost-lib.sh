#!/usr/bin/env bash
# sq-cost-lib.sh — Transcript-derived cost estimation library.
#
# Ported from munder-difflin's src/main/transcript.ts + src/main/pricing.ts
# (MIT, Chaitanya Giri). Reads real operator transcripts (JSONL) and prices
# them per model to get per-operation cost.
#
# Supports Claude Code JSONL transcripts and Pi session JSONL files. Other harnesses
# (opencode, codex, grok, kimi) are estimated from token counts when available.
# Pi attribution is exact: a session is eligible when its session header cwd
# equals the task execution workspace and its record carries the task identity.
# The recorded execution-attempt window remains the fallback for legacy sessions
# without that identity, and the recorded harness must be pi or pi-signed.
# The session directory is scoped by SQUAD_PI_SESSION_DIR (or ~/.pi/agent/sessions),
# so another base and the primary session cannot be counted accidentally. No
# prompt or response content is read.
#
# Usage:
#   . bin/sq-cost-lib.sh
#   cost=$(sq_cost_from_transcript /path/to/session.jsonl)
#
# MIT License — Copyright (c) 2026 Chaitanya Giri, munder-difflin project.
# Adapted for Squad. See https://github.com/chaitanyagiri/munder-difflin

# ── Pricing table ──────────────────────────────────────────────────────────
#
# USD per million tokens. Fallback-only — the live path would use provider-
# reported costs when available. Prices are approximate list prices, used
# when transcript-based estimation is the only option.
#
# Sources: Anthropic published pricing (2025-2026), OpenAI published pricing,
# Google published pricing. Update these when provider prices change.



# Per-family pricing: input|output|cache_read|cache_write per million tokens.
# Cache prices default to 10% of input when not specified by the provider.
sq_cost_price_for() {
  local model="${1:-}"
  local lower
  lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')

  # Strip variant suffixes like [1m], -20250514, etc.
  lower=$(echo "$lower" | sed 's/\[.*\]//;s/-[0-9]\{8\}$//')

  case "$lower" in
    *opus*)
      # Anthropic Claude Opus: $15/$75/$1.5/$18.75
      echo "15|75|1.5|18.75"
      ;;
    *sonnet*)
      # Anthropic Claude Sonnet: $3/$15/$0.3/$3.75
      echo "3|15|0.3|3.75"
      ;;
    *haiku*)
      # Anthropic Claude Haiku: $0.80/$4/$0.08/$1.00
      echo "0.80|4|0.08|1.00"
      ;;
    *gpt-4o*)
      # OpenAI GPT-4o: $2.50/$10/$1.25/$2.50
      echo "2.50|10|1.25|2.50"
      ;;
    *gpt-4.1*|*gpt-4-1*)
      # OpenAI GPT-4.1: $2/$8/$0.50/$2
      echo "2|8|0.50|2"
      ;;
    *o3-mini*|*o3mini*)
      # OpenAI o3-mini: $1.10/$4.40/$0.55/$1.10
      echo "1.10|4.40|0.55|1.10"
      ;;
    *o3*)
      # OpenAI o3: $10/$40/$2.50/$10
      echo "10|40|2.50|10"
      ;;
    *o4-mini*|*o4mini*)
      # OpenAI o4-mini: $1.10/$4.40/$0.275/$1.10
      echo "1.10|4.40|0.275|1.10"
      ;;
    *gemini-2.5-pro*|*gemini-2-5-pro*)
      # Google Gemini 2.5 Pro: $1.25/$10/$0.3125/$1.25
      echo "1.25|10|0.3125|1.25"
      ;;
    *gemini-2.5-flash*|*gemini-2-5-flash*)
      # Google Gemini 2.5 Flash: $0.15/$0.60/$0.0375/$0.15
      echo "0.15|0.60|0.0375|0.15"
      ;;
    *grok-3*|*grok3*)
      # xAI Grok-3: $3/$15 (estimated, no cache pricing published)
      echo "3|15|0|0"
      ;;
    *kimi*)
      # Moonshot Kimi: $2/$8 (estimated from kimi-k2 pricing)
      echo "2|8|0|0"
      ;;
    *codex*)
      # OpenAI codex-mini: $1.50/$6/$0.375/$1.50
      echo "1.50|6|0.375|1.50"
      ;;
    *)
      # Default: assume Sonnet-class pricing (the common case for Squad operators)
      echo "3|15|0.3|3.75"
      ;;
  esac
}

# ── Model normalization ───────────────────────────────────────────────────

# Normalize a model id: strip variant suffixes, trim whitespace.
sq_cost_normalize_model() {
  local model="${1:-}"
  # Strip [bracketed] suffixes and trailing date stamps
  echo "$model" | sed 's/\[[^\]]*\]//;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ── Cost calculation ──────────────────────────────────────────────────────

# sq_cost_estimate — estimate USD cost for a token split.
# Args: $1=model $2=input_tokens $3=output_tokens $4=cache_read $5=cache_write
# Prints cost in USD (decimal).
sq_cost_estimate() {
  local model="${1:-}"
  local input="${2:-0}"
  local output="${3:-0}"
  local cache_read="${4:-0}"
  local cache_write="${5:-0}"

  local prices
  prices=$(sq_cost_price_for "$model")
  local p_input p_output p_cache_read p_cache_write
  p_input=$(echo "$prices" | cut -d'|' -f1)
  p_output=$(echo "$prices" | cut -d'|' -f2)
  p_cache_read=$(echo "$prices" | cut -d'|' -f3)
  p_cache_write=$(echo "$prices" | cut -d'|' -f4)

  # Use awk for floating point: cost = (tokens / 1_000_000) * price_per_million
  awk -v i="$input" -v o="$output" -v cr="$cache_read" -v cw="$cache_write" \
      -v pi="$p_input" -v po="$p_output" -v pcr="$p_cache_read" -v pcw="$p_cache_write" \
      'BEGIN { printf "%.6f", (i/1000000)*pi + (o/1000000)*po + (cr/1000000)*pcr + (cw/1000000)*pcw }'
}

# ── Transcript parsing ────────────────────────────────────────────────────

# sq_cost_parse_transcript — parse a Claude Code JSONL transcript.
# Args: $1=path to .jsonl file
# Prints: input_tokens|output_tokens|cache_read|cache_write|model|cost_usd
# Returns 0 on success, 1 on error.
sq_cost_parse_transcript() {
  local file="${1:?transcript path required}"
  if [ ! -f "$file" ]; then
    echo "0|0|0|0||0.000000"
    return 1
  fi

  # Use awk for efficient single-pass JSONL parsing.
  # We look for type=assistant records with message.usage fields.
  # IMPORTANT: longer patterns must match first (cache_*_input_tokens before input_tokens)
  # to avoid partial matches.
  awk '
  BEGIN {
    total_in = 0; total_out = 0; total_cr = 0; total_cw = 0
    model = ""
  }
  {
    line = $0
    if (line == "") next

    # Quick check: must be an assistant message with usage
    if (index(line, "\"type\":\"assistant\"") == 0) next
    if (index(line, "\"usage\"") == 0) next

    # Extract model
    if (match(line, /"model":"[^"]*"/)) {
      m = substr(line, RSTART, RLENGTH)
      split(m, mp, ":")
      gsub(/"/, "", mp[2])
      if (mp[2] != "") model = mp[2]
    }

    # Extract token counts using split on colon (robust against offset errors)
    # ORDER MATTERS: longer patterns first to avoid partial matches.
    # cache_creation_input_tokens (longest)
    if (match(line, /"cache_creation_input_tokens":[0-9]+/)) {
      split(substr(line, RSTART, RLENGTH), p, ":")
      total_cw += p[2] + 0
    }
    # cache_read_input_tokens
    if (match(line, /"cache_read_input_tokens":[0-9]+/)) {
      split(substr(line, RSTART, RLENGTH), p, ":")
      total_cr += p[2] + 0
    }
    # output_tokens
    if (match(line, /"output_tokens":[0-9]+/)) {
      split(substr(line, RSTART, RLENGTH), p, ":")
      total_out += p[2] + 0
    }
    # input_tokens (shortest - must come last)
    if (match(line, /"input_tokens":[0-9]+/)) {
      split(substr(line, RSTART, RLENGTH), p, ":")
      total_in += p[2] + 0
    }
  }
  END {
    printf "%d|%d|%d|%d|%s|0.000000\n", total_in, total_out, total_cr, total_cw, model
  }' "$file" 2>/dev/null || echo "0|0|0|0||0.000000"
}

# sq_cost_from_transcript — parse and price a transcript in one call.
# Args: $1=path to .jsonl file
# Prints: input_tokens|output_tokens|cache_read|cache_write|model|cost_usd
sq_cost_from_transcript() {
  local file="${1:?transcript path required}"
  local parsed model cost
  parsed=$(sq_cost_parse_transcript "$file")

  local in out cr cw
  in=$(echo "$parsed" | cut -d'|' -f1)
  out=$(echo "$parsed" | cut -d'|' -f2)
  cr=$(echo "$parsed" | cut -d'|' -f3)
  cw=$(echo "$parsed" | cut -d'|' -f4)
  model=$(echo "$parsed" | cut -d'|' -f5)

  cost=$(sq_cost_estimate "$model" "$in" "$out" "$cr" "$cw")
  echo "${in}|${out}|${cr}|${cw}|${model}|${cost}"
}

# ── Pi task reporting ─────────────────────────────────────────────────────

# sq_cost_pi_task_json — return privacy-safe aggregated usage for a Pi task.
# Args: $1=task id, $2=state directory, $3=session root.
# The JSON is intentionally an interface for sq-cost.sh and its tests.
sq_cost_pi_task_json() {
  local task_id="${1:?task-id required}" state_dir="${2:?state dir required}" session_root="${3:?session root required}"
  local meta="$state_dir/$task_id.meta" exec_file worktree window harness model start end
  [ -f "$meta" ] || { printf '{"found":false,"reason":"task metadata is unavailable"}\n'; return 0; }
  exec_file="$state_dir/$task_id.exec"
  worktree=$(grep '^worktree=' "$meta" | head -1 | cut -d= -f2- || true)
  window=$(grep '^window=' "$meta" | head -1 | cut -d= -f2- || true)
  harness=$(grep '^harness=' "$meta" | head -1 | cut -d= -f2- || true)
  model=$(grep '^model=' "$meta" | head -1 | cut -d= -f2- || true)
  start=$(grep '^exec_started_at=' "$exec_file" 2>/dev/null | head -1 | cut -d= -f2- || true)
  end=$(grep '^exec_last_activity=' "$exec_file" 2>/dev/null | head -1 | cut -d= -f2- || true)
  local exec_workspace
  exec_workspace=$(grep '^exec_workspace=' "$exec_file" 2>/dev/null | head -1 | cut -d= -f2- || true)
  [ -n "$exec_workspace" ] && worktree="$exec_workspace"
  if [ -z "$worktree" ] || [ -z "$window" ] || [[ "$harness" != pi && "$harness" != pi-signed ]]; then
    jq -cn --arg reason "task metadata lacks an attributable Pi worktree, window, or harness" \
      '{found:false,reason:$reason}'
    return 0
  fi
  if [[ ! "$start" =~ ^[0-9]+$ ]] || [[ ! "$end" =~ ^[0-9]+$ ]] || [ "$end" -lt "$start" ]; then
    jq -cn --arg reason "task execution window is unavailable or invalid" \
      '{found:false,reason:$reason}'
    return 0
  fi

  local -a files=() file
  while IFS= read -r -d '' file; do files+=("$file"); done < <(
    find "$session_root" -type f -name '*.jsonl' -print0 2>/dev/null
  )
  if [ "${#files[@]}" -eq 0 ]; then
    jq -cn --arg reason "no Pi sessions were found under the configured session directory" \
      '{found:false,reason:$reason}'
    return 0
  fi

  local packed
  packed=$(mktemp "${TMPDIR:-/tmp}/sq-cost.XXXXXX")
  trap 'rm -f "$packed"' RETURN
  for file in "${files[@]}"; do
    jq -s -c . "$file" >> "$packed" 2>/dev/null || true
  done
  jq -s -n --arg cwd "$worktree" --arg task "$task_id" --arg agent "$harness" \
    --arg configured_model "$model" --arg start "$start" --arg end "$end" \
    --slurpfile sessions "$packed" '
    ($sessions | map(select(.[0].type == "session" and .[0].cwd == $cwd))) as $workspace_sessions |
    ($workspace_sessions | map(select(any(.[]; .type == "message" and .message.role == "user" and
      ((.message.content // "") | tostring | contains($task)))))) as $identity_matched |
    (if ($identity_matched | length) > 0 then $identity_matched else
      ($workspace_sessions | map(select(((try (.[0].timestamp | fromdateiso8601) catch null) as $ts |
       $ts != null and $ts >= ($start | tonumber) and $ts <= ($end | tonumber))))) end) as $matched |
    [ $matched[] as $s | $s[] | select(.type == "message" and .message.role == "assistant" and .message.usage != null) |
      {model:(.message.model // (($s | map(select(.type == "model_change") | .modelId) | last) // $configured_model)),
       provider:(($s | map(select(.type == "model_change") | .provider) | last) // ""), session:($s[0].id // "unknown"),
       started:($s[0].timestamp // ""), input:(.message.usage.input // 0), output:(.message.usage.output // 0),
       cache_read:(.message.usage.cacheRead // 0), cache_write:(.message.usage.cacheWrite // 0),
       total:(.message.usage.totalTokens // ((.message.usage.input // 0)+(.message.usage.output // 0)+(.message.usage.cacheRead // 0)+(.message.usage.cacheWrite // 0))),
       reported_cost:(.message.usage.cost.total // null)} ] as $rows |
    {found:($matched|length > 0), task:$task, agent:$agent, worktree:$cwd, sessions:($matched|length),
     started:($matched|map(.[0].timestamp // "")|min // ""),
     models:([ $rows[].model ] | unique | map(. as $m | {model:$m,
       sessions:([$rows[] | select(.model == $m) | .session] | unique | length),
       input:([$rows[] | select(.model == $m) | .input] | add // 0), output:([$rows[] | select(.model == $m) | .output] | add // 0),
       cache_read:([$rows[] | select(.model == $m) | .cache_read] | add // 0), cache_write:([$rows[] | select(.model == $m) | .cache_write] | add // 0),
       total:([$rows[] | select(.model == $m) | .total] | add // 0),
       reported_cost:([$rows[] | select(.model == $m) | .reported_cost] | map(select(. != null)) | add // null),
       provider:([$rows[] | select(.model == $m) | .provider] | map(select(. != "")) | first // "")}))}
  ' 2>/dev/null || printf '{"found":false,"reason":"Pi session data could not be read"}\n'
}

# ── Directory scanning ────────────────────────────────────────────────────

# sq_cost_scan_dir — scan all JSONL transcripts in a Claude projects dir.
# Args: $1=project_dir path
# Prints: total_input|total_output|total_cache_read|total_cache_write|last_model|total_cost
sq_cost_scan_dir() {
  local dir="${1:?directory path required}"
  if [ ! -d "$dir" ]; then
    echo "0|0|0|0||0.000000"
    return 1
  fi

  local total_in=0 total_out=0 total_cr=0 total_cw=0 total_cost=0 last_model=""

  for jsonl in "$dir"/*.jsonl; do
    [ -f "$jsonl" ] || continue
    local parsed
    parsed=$(sq_cost_from_transcript "$jsonl")
    local in out cr cw model cost
    in=$(echo "$parsed" | cut -d'|' -f1)
    out=$(echo "$parsed" | cut -d'|' -f2)
    cr=$(echo "$parsed" | cut -d'|' -f3)
    cw=$(echo "$parsed" | cut -d'|' -f4)
    model=$(echo "$parsed" | cut -d'|' -f5)
    cost=$(echo "$parsed" | cut -d'|' -f6)

    total_in=$((total_in + in))
    total_out=$((total_out + out))
    total_cr=$((total_cr + cr))
    total_cw=$((total_cw + cw))
    total_cost=$(awk -v a="$total_cost" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')
    [ -n "$model" ] && last_model="$model"
  done

  echo "${total_in}|${total_out}|${total_cr}|${total_cw}|${last_model}|${total_cost}"
}

# sq_cost_resolve_dir — resolve the Claude transcript directory for a cwd.
# Mirrors the logic from munder-difflin's transcript.ts projectDir().
# Args: $1=cwd (working directory)
# Prints: path to the transcript directory (may not exist)
sq_cost_resolve_dir() {
  local cwd="${1:?cwd required}"
  local root="$HOME/.claude/projects"
  # Claude's project key: every non-alphanumeric → dash
  local key
  key="${cwd//[^a-zA-Z0-9]/-}"
  local current="$root/$key"

  if [ -d "$current" ]; then
    echo "$current"
    return
  fi

  # Legacy key: leading slash dropped, only slashes dashed
  local legacy_key="${cwd#/}"
  legacy_key="${legacy_key//\//-}"
  local legacy="$root/$legacy_key"
  if [ -d "$legacy" ]; then
    echo "$legacy"
    return
  fi

  # Neither exists: return current (caller creates if needed)
  echo "$current"
}
