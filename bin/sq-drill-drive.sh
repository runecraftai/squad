#!/usr/bin/env bash
# Drive one AXI run/respond call, recovering terminal failed runs without a steer.
# Usage: sq-drill-drive.sh <task-id> run --intent '<accepted task intent>'
#        sq-drill-drive.sh <task-id> respond --intent '<same intent>' <respond flags>
# Run from the task's feature branch. The original call and at most two consecutive
# automatic reruns are allowed per invocation; a gate or successful outcome returns
# immediately and ends that consecutive-failure sequence. No gate is answered here.
# Every retry uses the original intent and the clean head returned by Drill's own
# guarded custody recovery. Cancellation, errors, dirty trees and unreturned custody
# stop with the exact AXI evidence and one blocked event in this base's task status.
# Never retry this helper after it reports blocked without resolving the cause.
# Resume is limited to Drill's unpublished custody recovery (custody_returned,
# user_owned). A terminal run that stopped after the pipeline pushed
# (behind/synchronized) or that still holds pipeline custody reports blocked
# instead of running an automatic `axi sync`. The reported state is the value
# exposed by `axi status` when available; synchronized post-push state may be
# omitted there. Published-branch sync and divergence are a separate risk class
# requiring separate authorization.
# --specialized-review is accepted on the run form; --yes and --skip are forbidden;
# no gate, fix-round limit or approval is bypassed.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-drill-run-lib.sh
. "$SCRIPT_DIR/sq-drill-run-lib.sh"
# shellcheck source=bin/sq-classify-lib.sh
. "$SCRIPT_DIR/sq-classify-lib.sh"
# shellcheck source=bin/sq-durable-custody.sh
. "$SCRIPT_DIR/sq-durable-custody.sh"

usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
ID=${1:-}; ACTION=${2:-}
case "$ID" in ''|*[!a-zA-Z0-9_-]*) usage >&2; exit 2 ;; esac
durable_custody_check "$ID" status || exit 3
case "$ACTION" in run|respond) ;; *) usage >&2; exit 2 ;; esac
shift 2
INTENT=
RUN_ARGS=()
RESPOND_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;; esac
  case "$1" in
    --intent)
      [ "$#" -ge 2 ] && [ -z "$INTENT" ] || { usage >&2; exit 2; }
      INTENT=$2; shift 2 ;;
    --action|--findings|--instructions|--step|--add-finding)
      [ "$ACTION" = respond ] && [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      RESPOND_ARGS+=("$1" "$2"); shift 2 ;;
    --specialized-review)
      [ "$ACTION" = run ] || { usage >&2; exit 2; }
      shift
      case "${1:-}" in
        true)  RUN_ARGS+=("--specialized-review"); shift ;;
        false) shift ;;
        *)     RUN_ARGS+=("--specialized-review") ;;
      esac ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -n "${INTENT//[[:space:]]/}" ] || { usage >&2; exit 2; }
BASE=${SQUAD_BASE:-${SQUAD_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATUS=${SQUAD_STATE_OVERRIDE:-$BASE/state}/$ID.status
[ -d "$(dirname "$STATUS")" ] || { echo 'error: task state directory is missing' >&2; exit 1; }
ATTEMPTS=
EVIDENCE=
SYNC_STATE=unknown

# These scalars are identifiers/enums, not free text or commands to evaluate.
scalar() { fm_drill_strip_quotes "$(fm_drill_field "$1" "$2")"; }
sync_object() { printf '%s\n' "$1" | awk '/^branch_sync:/ {inside=1; next} inside && /^[^ ]/ {exit} inside {print}'; }
block() {
  printf '%s\n' "$EVIDENCE"
  local latest state note
  latest=$(sync_object "$EVIDENCE")
  state=$(scalar "$latest" state)
  [ -z "$state" ] || SYNC_STATE=$state
  note="blocked: $1; drill_state=$SYNC_STATE; runs=${ATTEMPTS:-none}"
  printf '%s\n' "$note"
  status_line_append "$STATUS" "$note" || printf 'error: could not append the blocked event to %s\n' "$STATUS" >&2
  exit 1
}
BRANCH=$(git symbolic-ref --quiet --short HEAD) || block 'not on a feature branch'
DRILL_BIN=$(fm_drill_bin) || block 'drill CLI is not installed'
RERUNS=0
while :; do
  RC=0
  if [ "$ACTION" = run ]; then
    OUTPUT=$("$DRILL_BIN" axi run --intent "$INTENT" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} 2>&1) || RC=$?
  else
    OUTPUT=$("$DRILL_BIN" axi respond ${RESPOND_ARGS[@]+"${RESPOND_ARGS[@]}"} 2>&1) || RC=$?
  fi
  printf '%s\n' "$OUTPUT"
  EVIDENCE=$OUTPUT
  # A normal gate/CI-ready return belongs to the worker, never to this loop.
  [ "$RC" -ne 0 ] || exit 0
  RUN=$(scalar "$OUTPUT" id)
  case "$RUN" in ''|*[!a-zA-Z0-9_-]*) block 'AXI call failed without a run identity' ;; esac
  ATTEMPTS="${ATTEMPTS:+$ATTEMPTS,}$RUN"
  [ "$(scalar "$OUTPUT" outcome)" = failed ] || block 'AXI call did not return a terminal failed outcome'

  EVIDENCE=$("$DRILL_BIN" axi status --run "$RUN" 2>&1) || block 'cannot inspect the failed run'
  SYNC=$(sync_object "$EVIDENCE")
  SYNC_STATE=$(scalar "$SYNC" state)
  [ "$(scalar "$EVIDENCE" status)" = failed ] || block 'run is no longer failed'
  [ "$(scalar "$EVIDENCE" branch)" = "$BRANCH" ] || block 'run branch does not match this task'
  [ "$RERUNS" -lt 2 ] || block 'automatic rerun budget exhausted (2)'
  if [ "$(scalar "$SYNC" code)" = recover_custody ]; then
    EVIDENCE=$("$DRILL_BIN" axi sync --recover 2>&1) || block 'guarded custody recovery refused'
    SYNC=$(sync_object "$EVIDENCE")
    SYNC_STATE=$(scalar "$SYNC" state)
  fi
  # Accepted scope limit, not a missing recovery step: only unpublished custody
  # is resumed. Post-push terminal failures (behind/synchronized) and held
  # pipeline custody block here because syncing or re-running an already
  # published branch is a separate risk class requiring separate authorization.
  # The state exposed by `axi status` may be absent for synchronized branches.
  case "$SYNC_STATE" in
    custody_returned|user_owned) ;;
    *) block 'automatic resume covers unpublished custody recovery only; post-push sync, divergence and held custody stay manual' ;;
  esac
  CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD) || block 'branch detached during recovery'
  [ "$CURRENT_BRANCH" = "$BRANCH" ] || block 'branch changed during recovery'
  HEAD=$(git rev-parse HEAD) || block 'cannot inspect the recovered head'
  [ "$(scalar "$SYNC" head)" = "$HEAD" ] || block 'recovery does not match the local head'
  DIRTY=$(git status --porcelain) || block 'cannot inspect branch cleanliness'
  [ -z "$DIRTY" ] || block 'recovered branch is dirty'
  RERUNS=$((RERUNS + 1))
  printf 'recovery: starting automatic rerun %s/2 on %s after %s\n' "$RERUNS" "$HEAD" "$RUN"
  ACTION=run
done
