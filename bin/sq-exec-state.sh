#!/usr/bin/env bash
# Manage the per-attempt execution state sidecar at state/<id>.exec.
#
# Usage: sq-exec-state.sh get|claim|running|retry|release|after_run|heartbeat|recover <id>
#        sq-exec-state.sh transition <id> <state>
#        sq-exec-state.sh recover-all
#
# The sidecar is deliberately separate from state/<id>.meta.  Missing sidecars
# are the backwards-compatible unclaimed state.  Claim and writes are guarded
# by a task-local mkdir lock and published with rename, so a competing
# dispatcher cannot observe a partial record.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
STALE_AFTER="${SQUAD_EXEC_STALE_AFTER:-300}"
case "$STALE_AFTER" in ''|*[!0-9]*) STALE_AFTER=300 ;; esac

usage() {
  printf '%s\n' "usage: sq-exec-state.sh {get|claim|running|retry|release|after_run|heartbeat|recover|transition|recover-all} <id> [state]"
}
valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
valid_state() { case "$1" in unclaimed|claimed|running|retry_queued|released) return 0 ;; *) return 1 ;; esac; }
path_for() { printf '%s/%s.exec' "$STATE" "$1"; }
lock_for() { printf '%s/.exec-%s.lock' "$STATE" "$1"; }

get_field() { grep "^$1=" "$(path_for "$2")" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
meta_field() { grep "^$1=" "$STATE/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
get_state() { local value; value=$(get_field exec_state "$1"); printf '%s\n' "${value:-unclaimed}"; }

with_lock() {
  local id=$1; shift
  local lock tmp
  lock=$(lock_for "$id")
  if ! mkdir "$lock" 2>/dev/null; then
    printf 'error: execution state is locked for %s\n' "$id" >&2
    return 1
  fi
  trap 'rmdir "$lock" 2>/dev/null || true' RETURN
  "$@"
  trap - RETURN
  rmdir "$lock" 2>/dev/null || true
}

write_record() {
  local id=$1 state=$2 old=$3 now tmp attempt retry started workspace backend harness workflow max_retries error next_retry
  now=$(date +%s)
  attempt=$(get_field exec_attempt "$id"); [ -n "$attempt" ] || attempt=0
  retry=$(get_field exec_retry_count "$id"); [ -n "$retry" ] || retry=0
  started=$(get_field exec_started_at "$id")
  workspace=$(get_field exec_workspace "$id"); [ -n "$workspace" ] || workspace=$(meta_field worktree "$id")
  backend=$(get_field exec_backend "$id"); [ -n "$backend" ] || backend=$(meta_field backend "$id"); [ -n "$backend" ] || backend=tmux
  harness=$(get_field exec_harness "$id"); [ -n "$harness" ] || harness=$(meta_field harness "$id")
  workflow=$(get_field exec_workflow_version "$id"); [ -n "$workflow" ] || workflow=$(meta_field workflow "$id")
  max_retries=$(get_field exec_max_retries "$id"); [ -n "$max_retries" ] || max_retries=3
  error=${SQUAD_EXEC_ERROR:-$(get_field exec_error "$id")}
  next_retry=$(get_field exec_next_retry_at "$id")
  [ "$state" = claimed ] && attempt=$((attempt + 1))
  if [ "$state" = retry_queued ]; then
    local backoff=${SQUAD_RETRY_BACKOFF_BASE:-10} cap=${SQUAD_RETRY_BACKOFF_MAX:-300} n
    case "$backoff:$cap" in *[!0-9:]*|*:0) backoff=10; cap=300 ;; esac
    n=$backoff
    local remaining=$retry
    while [ "$remaining" -gt 0 ] && [ "$n" -lt "$cap" ]; do
      n=$((n * 2)); remaining=$((remaining - 1))
    done
    [ "$n" -gt "$cap" ] && n=$cap
    next_retry=$((now + n))
  fi
  [ "$state" = claimed ] && [ "$old" = retry_queued ] && retry=$((retry + 1))
  [ "$state" = running ] && [ -n "$started" ] || started=$now
  tmp=$(mktemp "$STATE/.exec.$id.XXXXXX")
  umask 077
  {
    printf 'exec_state=%s\n' "$state"
    printf 'exec_attempt=%s\n' "$attempt"
    printf 'exec_retry_count=%s\n' "$retry"
    printf 'exec_started_at=%s\n' "$started"
    printf 'exec_last_activity=%s\n' "$now"
    printf 'exec_previous_state=%s\n' "$old"
    printf 'exec_error=%s\n' "$error"
    printf 'exec_next_retry_at=%s\n' "$next_retry"
    printf 'exec_max_retries=%s\n' "$max_retries"
    printf 'exec_workflow_version=%s\n' "$workflow"
    printf 'exec_workspace=%s\n' "$workspace"
    printf 'exec_backend=%s\n' "$backend"
    printf 'exec_harness=%s\n' "$harness"
  } >"$tmp"
  mv -f -- "$tmp" "$(path_for "$id")"
}

claim_locked() {
  local id=$1 state
  state=$(get_state "$id")
  case "$state" in
    unclaimed|retry_queued)
      write_record "$id" claimed "$state"
      ;;
    claimed|running) printf 'error: task %s is already %s\n' "$id" "$state" >&2; return 1 ;;
    released) printf 'error: task %s is released\n' "$id" >&2; return 1 ;;
    *) printf 'error: invalid execution state for %s\n' "$id" >&2; return 1 ;;
  esac
  printf '%s\n' claimed
}

transition_locked() {
  local id=$1 next=$2 current
  current=$(get_state "$id")
  valid_state "$next" || { printf 'error: invalid execution state %s\n' "$next" >&2; return 2; }
  case "$current:$next" in
    unclaimed:claimed|unclaimed:released|claimed:running|claimed:retry_queued|claimed:released|running:retry_queued|running:released|retry_queued:claimed|retry_queued:released|released:released) : ;;
    "$next:$next") printf '%s\n' "$current"; return 0 ;;
    *) printf 'error: invalid transition %s -> %s\n' "$current" "$next" >&2; return 1 ;;
  esac
  write_record "$id" "$next" "$current"
  printf '%s\n' "$next"
}

_heartbeat() {
  local id=$1 now tmp
  now=$(date +%s)
  tmp=$(mktemp "$STATE/.exec.$id.XXXXXX")
  umask 077
  sed "s/^exec_last_activity=.*/exec_last_activity=$now/" "$(path_for "$id")" >"$tmp"
  mv -f -- "$tmp" "$(path_for "$id")"
}

recover_locked() {
  local id=$1 current age now last
  current=$(get_state "$id")
  case "$current" in
    running|claimed)
      now=$(date +%s); last=$(get_field exec_last_activity "$id"); [ -n "$last" ] || last=0
      age=$((now - last))
      if [ "$age" -ge "$STALE_AFTER" ]; then
        transition_locked "$id" retry_queued
      else
        printf '%s\n' "$current"
      fi ;;
    *) printf '%s\n' "$current" ;;
  esac
}

run_after_run_hook() {
  local id=$1 workflow workspace attempt state
  workflow=$(meta_field workflow "$id")
  [ -n "$workflow" ] || return 0
  workspace=$(get_field exec_workspace "$id"); [ -n "$workspace" ] || workspace=$(meta_field worktree "$id")
  attempt=$(get_field exec_attempt "$id"); [ -n "$attempt" ] || attempt=0
  state=$(get_state "$id")
  WORKFLOW_PATH="$workflow" SQUAD_BASE="$SQUAD_BASE" \
    "$SCRIPT_DIR/sq-hooks.sh" after_run "$workspace" "$id" "$attempt" "$state" "$(get_field exec_workflow_version "$id")" "$(basename "$(meta_field project "$id")")"
}

mkdir -p "$STATE"
cmd=${1:-}; id=${2:-}
case "$cmd" in
  recover-all)
    for file in "$STATE"/*.exec; do
      [ -f "$file" ] || continue
      id=${file##*/}; id=${id%.exec}
      valid_id "$id" || continue
      with_lock "$id" recover_locked "$id" >/dev/null || true
    done
    ;;
  get) valid_id "$id" || { usage >&2; exit 2; }; get_state "$id" ;;
  claim) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" claim_locked "$id" ;;
  running) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" transition_locked "$id" running ;;
  retry|retry_queued) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" transition_locked "$id" retry_queued ;;
  release|released) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" transition_locked "$id" released ;;
  after_run)
    valid_id "$id" || { usage >&2; exit 2; }
    if run_after_run_hook "$id"; then
      exit 0
    else
      hook_rc=$?
      current=$(get_state "$id")
      if [ "$current" = running ] || [ "$current" = claimed ]; then
        with_lock "$id" transition_locked "$id" retry_queued >/dev/null 2>&1 || true
      fi
      exit "$hook_rc"
    fi
    ;;
  heartbeat) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" _heartbeat "$id" ;;
  recover) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" recover_locked "$id" ;;
  transition) valid_id "$id" && [ -n "${3:-}" ] || { usage >&2; exit 2; }; with_lock "$id" transition_locked "$id" "$3" ;;
  *) usage >&2; exit 2 ;;
esac
