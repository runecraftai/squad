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
# --yes and --skip are forbidden; no gate, fix-round limit or approval is bypassed.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-drill-run-lib.sh
. "$SCRIPT_DIR/sq-drill-run-lib.sh"
# shellcheck source=bin/sq-classify-lib.sh
. "$SCRIPT_DIR/sq-classify-lib.sh"

usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
ID=${1:-}; ACTION=${2:-}
case "$ID" in ''|*[!a-zA-Z0-9_-]*) usage >&2; exit 2 ;; esac
case "$ACTION" in run|respond) ;; *) usage >&2; exit 2 ;; esac
shift 2
INTENT=
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;; esac
  case "$1" in
    --intent)
      [ "$#" -ge 2 ] && [ -z "$INTENT" ] || { usage >&2; exit 2; }
      INTENT=$2; shift 2 ;;
    --action|--findings|--instructions|--step|--add-finding)
      [ "$ACTION" = respond ] && [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ARGS+=("$1" "$2"); shift 2 ;;
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
    OUTPUT=$("$DRILL_BIN" axi run --intent "$INTENT" 2>&1) || RC=$?
  else
    OUTPUT=$("$DRILL_BIN" axi respond "${ARGS[@]}" 2>&1) || RC=$?
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
  case "$SYNC_STATE" in
    custody_returned|user_owned) ;;
    *) block 'custody was not returned' ;;
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
