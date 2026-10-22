#!/usr/bin/env bash
# Manage the per-attempt execution state sidecar at state/<id>.exec.
#
# Usage: sq-exec-state.sh get|get-recorded|claim|running|retry|release|after_run|heartbeat|recover <id>
# get projects a current attributed Drill run over the dispatch record;
# get-recorded reads only that record. A released id remains undispatchable.
# claim exits 3 when an active run already owns the id, so a supervisor can
# skip that attempt without recording a failure. A gate-parked run keeps the id
# while its recorded owner endpoint is alive; once that endpoint is
# authoritatively gone the attempt is resumable so a relaunch is not blocked. An
# ended run never blocks a claim or retires a record on its own: a retry_queued
# record exists precisely because the previous attempt's run already ended.
#        sq-exec-state.sh transition <id> <state>
#        sq-exec-state.sh recover-all
#
# The sidecar is deliberately separate from state/<id>.meta.  Missing sidecars
# are the backwards-compatible unclaimed state.  Claim and writes are guarded
# by a task-local mkdir lock and published with rename, so a competing
# dispatcher cannot observe a partial record.
#
# State machine: unclaimed -> claimed -> running -> retry_queued -> released.
# 'released' is terminal for this id - there is no released -> unclaimed or
# released -> claimed transition. recover repairs only claimed, running, and
# retry_queued records through the existing transitions, and never resurrects
# a released id.
# Once released, sq-spawn refuses relaunch of the same id. To redespatch
# the same work, create a new task id.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
# shellcheck source=bin/sq-drill-run-lib.sh
. "$SCRIPT_DIR/sq-drill-run-lib.sh"
STALE_AFTER="${SQUAD_EXEC_STALE_AFTER:-300}"
case "$STALE_AFTER" in ''|*[!0-9]*) STALE_AFTER=300 ;; esac

usage() {
  printf '%s\n' "usage: sq-exec-state.sh {get|get-recorded|claim|running|retry|release|after_run|heartbeat|recover|transition|recover-all} <id> [state]"
}
valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
valid_state() { case "$1" in unclaimed|claimed|running|retry_queued|released) return 0 ;; *) return 1 ;; esac; }
path_for() { printf '%s/%s.exec' "$STATE" "$1"; }
lock_for() { printf '%s/.exec-%s.lock' "$STATE" "$1"; }

get_field() { grep "^$1=" "$(path_for "$2")" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
meta_field() { grep "^$1=" "$STATE/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
get_state() { local value; value=$(get_field exec_state "$1"); printf '%s\n' "${value:-unclaimed}"; }

# Active run evidence is independent of endpoint liveness and stale events.
# Active evidence gates dispatch, while terminal evidence only drives the get
# projection: retiring a dispatch record stays tied to terminal .status
# evidence or an explicit release. Unknown/unattributed queries leave the
# existing dispatch semantics unchanged.
task_run_state() {  # <id> -> active|parked|terminal|unknown
  local wt kind timeout_secs limit state
  wt=$(meta_field worktree "$1")
  kind=$(meta_field kind "$1")
  case "$kind" in ''|strike) ;; *) printf 'unknown'; return ;; esac
  [ -n "$wt" ] && [ -d "$wt" ] || { printf 'unknown'; return; }
  timeout_secs=${SQUAD_CREW_STATE_DRILL_TIMEOUT:-10}
  limit=${SQUAD_CREW_STATE_RUNS_LIMIT:-200}
  case "$timeout_secs" in ''|*[!0-9]*) timeout_secs=10 ;; esac
  case "$limit" in ''|*[!0-9]*) limit=200 ;; esac
  fm_drill_current_run "$wt" "$timeout_secs" "$limit"
  state=$(fm_drill_current_run_state)
  if [ "$state" = active ] && fm_drill_current_run_parked; then
    printf 'parked'
    return
  fi
  printf '%s' "$state"
}

reported_state() {
  fm_drill_reported_exec_state "$(task_run_state "$1")" "$(get_state "$1")"
}

# Liveness of the endpoint recorded for this task. Only an authoritatively
# gone endpoint (dead|missing) licenses resumption; every ambiguous, unreadable,
# or unverified read keeps the recorded owner authoritative.
task_owner_endpoint_state() {  # <id> -> alive|dead|unknown
  local meta
  if [ -n "${SQUAD_EXEC_OWNER_STATE:-}" ]; then
    case "$SQUAD_EXEC_OWNER_STATE" in
      alive) printf 'alive' ;;
      dead|missing) printf 'dead' ;;
      *) printf 'unknown' ;;
    esac
    return
  fi
  meta="$STATE/$1.meta"
  [ -f "$meta" ] || { printf 'unknown'; return; }
  if [ -z "${_SQUAD_EXEC_BACKEND_SOURCED:-}" ]; then
    [ -f "$SCRIPT_DIR/sq-backend.sh" ] || { printf 'unknown'; return; }
    # shellcheck source=bin/sq-backend.sh disable=SC1091
    . "$SCRIPT_DIR/sq-backend.sh"
    _SQUAD_EXEC_BACKEND_SOURCED=1
  fi
  { fm_backend_agent_alive "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")" 2>/dev/null; } || printf 'unknown'
}

# An executing run always blocks a second attempt. A gate-parked run blocks
# only while its recorded owner endpoint is still alive, so a dead owner cannot
# leave the task parked behind a run nobody can answer.
task_run_blocks_dispatch() {  # <id> <run_state>
  case "$2" in
    active) return 0 ;;
    parked) [ "$(task_owner_endpoint_state "$1")" != dead ] ;;
    *) return 1 ;;
  esac
}

# Last nonblank .status event verb, the completion signal claim and recover read.
last_status_verb() {  # <id>
  local line verb
  line=$(grep -v '^[[:space:]]*$' "$STATE/$1.status" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 1
  verb=${line%%:*}
  verb=${verb%%[key=*}
  verb=${verb#"${verb%%[![:space:]]*}"}
  printf '%s' "$verb"
}

terminal_status() {  # <id> <run_state>: last terminal event, unless a bound run resumed
  local verb run_state=${2-}
  verb=$(last_status_verb "$1") || return 1
  # PR metadata is corroborating only; local and recon deliveries need none.
  case "$verb" in
    done|failed) ;;
    *) return 1 ;;
  esac
  # Every caller resolves run evidence before taking the lock; a missing
  # argument is a call-site bug, never a reason to query drill under the lock.
  case "$run_state" in
    active|parked) return 1 ;;
    '') printf 'error: terminal status checked without run evidence\n' >&2; return 2 ;;
  esac
  return 0
}

with_lock() {
  local id=$1; shift
  local lock tmp rc=0
  lock=$(lock_for "$id")
  if ! mkdir "$lock" 2>/dev/null; then
    printf 'error: execution state is locked for %s\n' "$id" >&2
    return 1
  fi
  trap 'rmdir "$lock" 2>/dev/null || true' RETURN
  "$@" || rc=$?
  trap - RETURN
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

write_record() {
  local id=$1 state=$2 old=$3 now tmp attempt retry started workspace workspace_history backend harness workflow max_retries error next_retry
  now=$(date +%s)
  attempt=$(get_field exec_attempt "$id"); [ -n "$attempt" ] || attempt=0
  retry=$(get_field exec_retry_count "$id"); [ -n "$retry" ] || retry=0
  started=$(get_field exec_started_at "$id")
  workspace=$(meta_field worktree "$id"); [ -n "$workspace" ] || workspace=$(get_field exec_workspace "$id")
  workspace_history=$(grep '^exec_workspace=' "$(path_for "$id")" 2>/dev/null || true)
  if [ -n "$workspace" ] && ! printf '%s\n' "$workspace_history" | grep -qxF -- "exec_workspace=$workspace"; then
    workspace_history="${workspace_history}${workspace_history:+
}exec_workspace=$workspace"
  fi
  backend=$(get_field exec_backend "$id"); [ -n "$backend" ] || backend=$(meta_field backend "$id"); [ -n "$backend" ] || backend=tmux
  harness=$(get_field exec_harness "$id"); [ -n "$harness" ] || harness=$(meta_field harness "$id")
  workflow=$(get_field exec_workflow_version "$id"); [ -n "$workflow" ] || workflow=$(meta_field workflow_version "$id")
  # A fresh claim is a new execution version. Running attempts retain the
  # value already written to the sidecar, while retries pick up changed bytes.
  if [ "$state" = claimed ] && [ "$old" = retry_queued ]; then
    workflow_path=$(meta_field workflow "$id")
    if [ -n "$workflow_path" ] && [ -f "$workflow_path" ]; then
      workflow=$("$SQUAD_ROOT/bin/sq-workflow-reload.sh" check "$workflow_path" "$STATE" | sed 's/.*version=//')
    fi
  fi
  max_retries=$(get_field exec_max_retries "$id"); [ -n "$max_retries" ] || max_retries=3
  error=${SQUAD_EXEC_ERROR:-$(get_field exec_error "$id")}
  # A retry deadline only describes a queued attempt, never one that started.
  next_retry=
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
    [ -z "$workspace_history" ] || printf '%s\n' "$workspace_history"
    printf 'exec_backend=%s\n' "$backend"
    printf 'exec_harness=%s\n' "$harness"
  } >"$tmp"
  mv -f -- "$tmp" "$(path_for "$id")"
}

claim_locked() {  # <id> [run_state]: run evidence is resolved before the lock
  local id=$1 run_state=${2-} state
  state=$(get_state "$id")
  [ -n "$run_state" ] || { printf 'error: claim requires run evidence for %s\n' "$id" >&2; return 2; }
  if task_run_blocks_dispatch "$id" "$run_state"; then
    printf 'error: task %s already has an active run\n' "$id" >&2
    return 3
  fi
  if terminal_status "$id" "$run_state"; then
    transition_locked "$id" released >/dev/null
    printf 'error: task %s has terminal status\n' "$id" >&2
    return 1
  fi
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

transition_locked() {  # <id> <next> [run_state]
  local id=$1 next=$2 run_state=${3-} current
  current=$(get_state "$id")
  valid_state "$next" || { printf 'error: invalid execution state %s\n' "$next" >&2; return 2; }
  if [ "$next" = running ] && terminal_status "$id" "$run_state"; then
    case "$current" in claimed|retry_queued) write_record "$id" released "$current" ;; esac
    printf '%s\n' released
    return 1
  fi
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

recover_locked() {  # <id> [run_state]: run evidence is resolved before the lock
  local id=$1 run_state=${2-} current age now last
  current=$(get_state "$id")
  [ -n "$run_state" ] || { printf 'error: recover requires run evidence for %s\n' "$id" >&2; return 2; }
  if task_run_blocks_dispatch "$id" "$run_state"; then
    # Repair only through existing transitions. Released is immutable for
    # dispatch, even though its live run still projects as running in get.
    case "$current" in
      retry_queued)
        transition_locked "$id" claimed "$run_state" >/dev/null
        transition_locked "$id" running "$run_state" >/dev/null ;;
      claimed) transition_locked "$id" running "$run_state" >/dev/null ;;
      running) write_record "$id" running "$current" ;;
    esac
    printf 'running\n'
    return
  fi
  case "$current" in
    running|claimed|retry_queued)
      if terminal_status "$id" "$run_state"; then
        transition_locked "$id" released
        return
      fi
      ;;
  esac
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
    recover_now=$(date +%s)
    for file in "$STATE"/*.exec; do
      [ -f "$file" ] || continue
      id=${file##*/}; id=${id%.exec}
      valid_id "$id" || continue
      [ -f "$STATE/$id.meta" ] || { rm -f "$file"; continue; }
      current=$(get_state "$id")
      # Only queued or live attempts are repairable, so released and fresh
      # records cost no run attribution on every heartbeat.
      case "$current" in running|claimed|retry_queued) ;; *) continue ;; esac
      # A running record that is neither stale nor carrying a terminal event
      # recovers to itself, so it skips the bounded drill probe too.
      if [ "$current" = running ]; then
        last=$(get_field exec_last_activity "$id"); [ -n "$last" ] || last=0
        if [ $((recover_now - last)) -lt "$STALE_AFTER" ]; then
          case "$(last_status_verb "$id" || true)" in done|failed) ;; *) continue ;; esac
        fi
      fi
      with_lock "$id" recover_locked "$id" "$(task_run_state "$id")" >/dev/null || true
    done
    ;;
  get) valid_id "$id" || { usage >&2; exit 2; }; reported_state "$id" ;;
  get-recorded) valid_id "$id" || { usage >&2; exit 2; }; get_state "$id" ;;
  claim) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" claim_locked "$id" "$(task_run_state "$id")" ;;
  running) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" transition_locked "$id" running "$(task_run_state "$id")" ;;
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
  recover) valid_id "$id" || { usage >&2; exit 2; }; with_lock "$id" recover_locked "$id" "$(task_run_state "$id")" ;;
  transition)
    valid_id "$id" && [ -n "${3:-}" ] || { usage >&2; exit 2; }
    run_state=
    case "${3:-}" in running) run_state=$(task_run_state "$id") ;; esac
    with_lock "$id" transition_locked "$id" "$3" "$run_state" ;;
  *) usage >&2; exit 2 ;;
esac
