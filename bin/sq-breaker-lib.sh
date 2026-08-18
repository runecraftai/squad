#!/usr/bin/env bash
# sq-breaker-lib.sh — Circuit-breaker ladder policy library.
#
# Ported from munder-difflin's src/main/breaker.ts (MIT, Chaitanya Giri).
# This is the POLICY ONLY — it reads signals and returns a verdict. The caller
# performs enforcement (steer, constrain, kill) and persists breaker state.
#
# The escalation ladder: healthy → steering → constrained → stopped.
# Trip conditions: repeated tool calls, error storms, no-progress streaks.
# De-escalation: one level per healthy evaluation (recovery).
# hardStop controls whether the ladder can reach 'stopped' or caps at 'constrained'.
#
# Usage:
#   . bin/sq-breaker-lib.sh
#   verdict=$(sq_breaker_evaluate ...)
#
# MIT License — Copyright (c) 2026 Chaitanya Giri, munder-difflin project.
# Adapted for Squad. See https://github.com/chaitanyagiri/munder-difflin

# ── Constants ───────────────────────────────────────────────────────────────

# Ordered levels; rank is index.
SQ_BREAKER_LEVELS="healthy steering constrained stopped"

# Default policy parameters. Callers may override via environment.
SQ_BREAKER_REPEATED_TOOL_LIMIT="${SQ_BREAKER_REPEATED_TOOL_LIMIT:-8}"
SQ_BREAKER_ERROR_STORM_LIMIT="${SQ_BREAKER_ERROR_STORM_LIMIT:-5}"
SQ_BREAKER_NO_PROGRESS_BEATS="${SQ_BREAKER_NO_PROGRESS_BEATS:-3}"
SQ_BREAKER_HARD_STOP="${SQ_BREAKER_HARD_STOP:-0}"  # 0 = cap at constrained, 1 = allow stopped
export SQ_BREAKER_HARD_STOP

# ── Helpers ─────────────────────────────────────────────────────────────────

# Rank a level (0=healthy, 3=stopped). Unknown → 0.
sq_breaker_rank() {
  local level=$1 i=0
  for l in $SQ_BREAKER_LEVELS; do
    [ "$l" = "$level" ] && { echo "$i"; return; }
    i=$((i + 1))
  done
  echo 0
}

# Action for a level: steer/constrain/stop/none.
sq_breaker_action_for() {
  case "$1" in
    steering)    echo "steer" ;;
    constrained) echo "constrain" ;;
    stopped)     echo "stop" ;;
    *)           echo "none" ;;
  esac
}

# ── Policy evaluation ──────────────────────────────────────────────────────

# sq_breaker_evaluate — evaluate breaker signals and return a verdict.
#
# Arguments (positional):
#   $1  current_level     — current breaker level (healthy/steering/constrained/stopped)
#   $2  repeat_count      — consecutive identical tool calls
#   $3  repeat_tool       — name of the repeating tool (for reason text)
#   $4  error_count       — consecutive errors/retries
#   $5  no_progress_beats — consecutive beats with no forward progress
#   $6  progressing       — "1" if agent made progress recently, "0" otherwise
#
# Environment overrides:
#   SQ_BREAKER_REPEATED_TOOL_LIMIT  (default 8)
#   SQ_BREAKER_ERROR_STORM_LIMIT    (default 5)
#   SQ_BREAKER_NO_PROGRESS_BEATS    (default 3)
#   SQ_BREAKER_HARD_STOP            (default 0)
#
# Output: prints "verdict|action|reason" where:
#   verdict = new level (healthy/steering/constrained/stopped)
#   action  = what to do (none/steer/constrain/stop)
#   reason  = human-readable explanation
# Returns 0 always.
sq_breaker_evaluate() {
  local current_level="${1:-healthy}"
  local repeat_count="${2:-0}"
  local repeat_tool="${3:-unknown}"
  local error_count="${4:-0}"
  local no_progress_beats="${5:-0}"
  local progressing="${6:-1}"

  local tripping=0 reason=""

  # ── Trip evaluation ──

  # Repeated identical tool calls (looping)
  if [ "$repeat_count" -ge "$SQ_BREAKER_REPEATED_TOOL_LIMIT" ]; then
    tripping=1
    reason="looping: ${repeat_count}x identical tool call (${repeat_tool})"
  fi

  # Error storm
  if [ "$tripping" -eq 0 ] && [ "$error_count" -ge "$SQ_BREAKER_ERROR_STORM_LIMIT" ]; then
    tripping=1
    reason="error storm: ${error_count} consecutive errors/retries"
  fi

  # No-progress streak (generating output without forward progress)
  if [ "$tripping" -eq 0 ] && [ "$progressing" -eq 0 ] && \
     [ "$no_progress_beats" -ge "$SQ_BREAKER_NO_PROGRESS_BEATS" ]; then
    tripping=1
    reason="no-progress: ${no_progress_beats} consecutive beats without forward progress"
  fi

  # ── Level transition ──
  local current_rank ceiling_rank target_rank
  current_rank=$(sq_breaker_rank "$current_level")

  if [ "$SQ_BREAKER_HARD_STOP" -eq 1 ]; then
    ceiling_rank=3  # stopped
  else
    ceiling_rank=2  # constrained
  fi

  local target_level action changed="false"
  if [ "$tripping" -eq 1 ]; then
    # Escalate one level (up to ceiling)
    target_rank=$((current_rank + 1))
    if [ "$target_rank" -gt "$ceiling_rank" ]; then
      target_rank=$ceiling_rank
    fi
  else
    # Recover one level (down to healthy)
    target_rank=$((current_rank - 1))
    if [ "$target_rank" -lt 0 ]; then
      target_rank=0
    fi
  fi

  # Map rank back to level
  local i=0
  for l in $SQ_BREAKER_LEVELS; do
    if [ "$i" -eq "$target_rank" ]; then
      target_level=$l
      break
    fi
    i=$((i + 1))
  done
  target_level="${target_level:-healthy}"

  # Action fires only on escalation
  action="none"
  if [ "$target_rank" -gt "$current_rank" ]; then
    action=$(sq_breaker_action_for "$target_level")
  fi

  [ "$target_level" != "$current_level" ] && changed="true"

  if [ "$tripping" -eq 0 ] && [ "$changed" = "true" ]; then
    reason="recovering — signals cleared"
  fi
  if [ "$tripping" -eq 0 ] && [ "$changed" = "false" ]; then
    reason=""
  fi

  echo "${target_level}|${action}|${reason}"
}

# ── State file helpers ─────────────────────────────────────────────────────

# sq_breaker_read_state — read persisted breaker state for a task.
# Prints "level|repeat_key|repeat_count|error_count|no_progress_beats".
# Defaults to healthy state when no file exists.
sq_breaker_read_state() {
  local state_dir="${SQUAD_STATE_OVERRIDE:-state}"
  local state_file="$state_dir/$1.breaker"
  if [ -f "$state_file" ]; then
    cat "$state_file"
  else
    echo "healthy||0|0|0"
  fi
}

# sq_breaker_write_state — persist breaker state for a task.
# Args: $1=task_id $2=level $3=repeat_key $4=repeat_count $5=error_count $6=no_progress_beats
sq_breaker_write_state() {
  local state_dir="${SQUAD_STATE_OVERRIDE:-state}"
  local state_file="$state_dir/$1.breaker"
  printf '%s|%s|%s|%s|%s\n' "${2:-healthy}" "${3:-}" "${4:-0}" "${5:-0}" "${6:-0}" > "$state_file"
}

# sq_breaker_forget — remove breaker state for a task (teardown).
sq_breaker_forget() {
  local state_dir="${SQUAD_STATE_OVERRIDE:-state}"
  rm -f "${state_dir}/${1:?}.breaker"
}
