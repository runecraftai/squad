#!/usr/bin/env bash
# Detect and retry execution attempts that stopped making progress.
#
# Usage: sq-stall-detect.sh [check]
#
# A stall is an attempt that has exceeded SQUAD_STALL_TIMEOUT seconds without
# activity and has no positive evidence of a live tool call or active phase.
# Ambiguous endpoint evidence is surfaced for stuck-operator-recovery; it is
# never interrupted automatically. Workspaces and branches are not modified.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
STALL_TIMEOUT="${SQUAD_STALL_TIMEOUT:-300}"
case "$STALL_TIMEOUT" in ''|*[!0-9]*) STALL_TIMEOUT=300 ;; esac

# shellcheck source=bin/sq-classify-lib.sh
. "$SCRIPT_DIR/sq-classify-lib.sh"

field() { grep "^$1=" "$STATE/$2.exec" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
meta_field() { grep "^$1=" "$STATE/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

stall_status_is_nonworking() {  # <id>
  local last
  last=$(last_status_line "$STATE/$1.status")
  [ -n "$last" ] && { status_is_paused "$last" || status_is_terminal_verb "$last"; }
}

# Public for tests and for the execution-state owner.
stall_backoff_seconds() {
  local retry=${1:-0} base=${SQUAD_RETRY_BACKOFF_BASE:-10} cap=${SQUAD_RETRY_BACKOFF_MAX:-300} n
  case "$retry:$base:$cap" in *[!0-9:]*|*:*:0) return 2 ;; esac
  n=$base
  while [ "$retry" -gt 0 ] && [ "$n" -lt "$cap" ]; do
    n=$((n * 2)); retry=$((retry - 1))
  done
  [ "$n" -gt "$cap" ] && n=$cap
  printf '%s\n' "$n"
}

append_status() {
  local id=$1 note=$2
  [ -f "$STATE/$id.status" ] || : >"$STATE/$id.status"
  printf '%s: %s\n' "${3:-stalled}" "$note" >>"$STATE/$id.status"
}

positive_activity() {
  local id=$1 phase backend target state_out crew_state crew_bin
  phase=$(field exec_phase "$id"); [ -n "$phase" ] || phase=$(meta_field phase "$id")
  case "$phase" in running|active|in_progress|working|tool_call|busy) return 0 ;; esac
  crew_bin=${SQUAD_STALL_CREW_STATE_BIN:-$SCRIPT_DIR/sq-crew-state.sh}
  if [ -x "$crew_bin" ] && [ -f "$STATE/$id.meta" ] && [ -d "$(meta_field worktree "$id")" ]; then
    crew_state=$(timeout "${SQUAD_STALL_CREW_STATE_TIMEOUT:-5}" "$crew_bin" "$id" 2>/dev/null || true)
    case "$crew_state" in
      'state: working'* ) return 0 ;;
      'state: unknown'* ) return 2 ;;
    esac
  fi

  backend=$(field exec_backend "$id"); [ -n "$backend" ] || backend=$(meta_field backend "$id"); [ -n "$backend" ] || backend=tmux
  target=$(meta_field window "$id"); [ -n "$target" ] || target=$(meta_field target "$id"); [ -n "$target" ] || target="$id"
  # The busy classifier is the strongest positive signal available to the
  # sentry. Keep it optional so the detector remains usable in small fixtures.
  if [ -n "${SQUAD_STALL_AGENT_STATE:-}" ]; then
    state_out=$SQUAD_STALL_AGENT_STATE
  elif [ -f "$SCRIPT_DIR/sq-backend.sh" ]; then
    # shellcheck source=bin/sq-backend.sh disable=SC1091
    . "$SCRIPT_DIR/sq-backend.sh"
    state_out=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  else
    state_out=unreadable
  fi
  case "$state_out" in alive) ;; dead|missing) return 1 ;; ambiguous|unreadable|unverified) return 2 ;; esac
  return 1
}

interrupt_worker() {
  local id=$1
  # sq-send owns the backend-specific interrupt key and endpoint resolution.
  if [ -n "${SQUAD_STALL_INTERRUPT_CMD:-}" ]; then
    "$SQUAD_STALL_INTERRUPT_CMD" "$id"
  else
    "$SCRIPT_DIR/sq-send.sh" "$id" --key C-c >/dev/null 2>&1
  fi
}

handle_task() {
  local id=$1 now last age evidence retries max next reason
  now=$(date +%s)
  last=$(field exec_last_activity "$id"); [ -n "$last" ] || last=0
  age=$((now - last))
  [ "$age" -ge "$STALL_TIMEOUT" ] || return 0
  # A running sidecar can outlive the event that intentionally parked or
  # finished its worker. Never append a synthetic `working:` event after a
  # paused or terminal status - doing so resurrects a non-working task and
  # feeds the stale-pane detector a false wedge signal.
  stall_status_is_nonworking "$id" && return 0
  retries=$(field exec_retry_count "$id"); [ -n "$retries" ] || retries=0
  max=$(field exec_max_retries "$id"); [ -n "$max" ] || max=3

  if positive_activity "$id"; then
    "$SCRIPT_DIR/sq-exec-state.sh" heartbeat "$id" >/dev/null 2>&1 || true
    return 0
  else
    evidence=$?
  fi
  if [ "$evidence" -eq 2 ]; then
    append_status "$id" "ambiguous stall evidence; route to stuck-operator-recovery" ambiguous
    return 0
  fi

  reason=stall_timeout
  if ! interrupt_worker "$id"; then
    append_status "$id" "stall detected but worker interruption was not confirmed" blocked
    return 0
  fi
  if [ "$retries" -ge "$max" ]; then
    SQUAD_EXEC_ERROR=$reason "$SCRIPT_DIR/sq-exec-state.sh" release "$id" >/dev/null
    append_status "$id" "retry exhausted after stall" failed
  else
    SQUAD_EXEC_ERROR=$reason "$SCRIPT_DIR/sq-exec-state.sh" retry "$id" >/dev/null
    next=$(field exec_next_retry_at "$id")
    append_status "$id" "stall interrupted; retry scheduled for $next" working
  fi
}

stall_run_check() {
  local file id state
  mkdir -p "$STATE"
  for file in "$STATE"/*.exec; do
    [ -f "$file" ] || continue
    id=${file##*/}; id=${id%.exec}
    state=$(field exec_state "$id")
    [ "$state" = running ] || continue
    handle_task "$id"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-check}" = check ]; then
    stall_run_check
  else
    printf '%s\n' 'usage: sq-stall-detect.sh [check]' >&2
    exit 2
  fi
fi
