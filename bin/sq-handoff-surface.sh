#!/usr/bin/env bash
# Surface pending new-session handoff requests exactly once per milestone.
#
# A primary-base hook surface - the Pi turn-end extension and the session-start
# digest - calls this whenever the agent settles or a session opens. Under the
# handoff-queue lock it atomically marks every pending record surfaced and
# prints the handoff card for the records it just surfaced. A second call
# finds nothing pending and prints nothing, which is what makes the card
# appear exactly once per milestone no matter how many surfaces race.
#
# The surfacer scopes to a real primary checkout (main base or a marked XO
# base), so an operator or recon worktree that happens to run the same tracked
# file stays silent. An XO base owns its own state/ and therefore its own
# handoff queue; the main base never surfaces for it.
#
# Output is the card only - no diagnostics - so a caller can distinguish
# "surfaced something" (non-empty stdout) from "nothing pending" (silent).
# See docs/handoff-request.md for the mechanism.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"

# shellcheck source=bin/sq-primary-scope-lib.sh
. "$SCRIPT_DIR/sq-primary-scope-lib.sh"
fm_primary_scope_matches "$SQUAD_ROOT" "$STATE" || exit 0

# shellcheck source=bin/sq-handoff-request.sh
. "$SCRIPT_DIR/sq-handoff-request.sh"

fm_handoff_kind_label() {  # <kind> <result-var>
  local kind=$1 result_var=$2 value
  case "$kind" in
    pr-merged) value='milestone PR merged' ;;
    queue-drained) value='flight queue drained' ;;
    *) value=$kind ;;
  esac
  printf -v "$result_var" '%s' "$value"
}

# fm_handoff_surface_mark <result-var> - atomically move every pending record
# to surfaced under the queue lock and emit each newly surfaced record as
# key<TAB>kind<TAB>payload lines into the result variable. Nothing is emitted
# when no record was pending, so a concurrent surfaver cannot double-print.
fm_handoff_surface_mark() {
  local result_var=$1 collected='' ts seq kind key state payload tmp changed=0
  [ -f "$SQUAD_HANDOFF_QUEUE" ] || {
    printf -v "$result_var" '%s' ''
    return 0
  }
  fm_lock_try_acquire "$SQUAD_HANDOFF_LOCK" || return 1
  tmp=$(mktemp "$STATE/.handoff-queue.XXXXXX") || {
    fm_lock_release "$SQUAD_HANDOFF_LOCK"
    return 1
  }
  while IFS=$'\t' read -r ts seq kind key state payload || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    if [ "$state" = pending ]; then
      state=surfaced
      changed=1
      collected="${collected}${key}"$'\t'"${kind}"$'\t'"${payload}"$'\n'
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$seq" "$kind" "$key" "$state" "$payload" >> "$tmp"
  done < "$SQUAD_HANDOFF_QUEUE"
  if [ "$changed" -eq 1 ]; then
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$SQUAD_HANDOFF_QUEUE"; then
      rm -f "$tmp" 2>/dev/null || true
      fm_lock_release "$SQUAD_HANDOFF_LOCK"
      return 1
    fi
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  fm_lock_release "$SQUAD_HANDOFF_LOCK"
  printf -v "$result_var" '%s' "$collected"
}

# The handoff card. It names what closed, reminds Squad of the commander-owned
# /new decision, and carries the exact resolve command so the record can be
# closed durably when the commander answers.
print_handoff_card() {  # <key> <kind> <payload>
  local key=$1 kind=$2 payload=$3 label
  fm_handoff_kind_label "$kind" label
  printf 'HANDOFF - MILESTONE CLOSE (new-session handoff request, surfaced once)\n'
  printf '  key:     %s\n' "$key"
  printf '  reason:  %s\n' "$label"
  printf '  context: %s\n' "$payload"
  printf '  At this milestone close, run the debrief sweep, present this card to the\n'
  printf '  commander, and ask whether to start a new session now. The commander owns\n'
  printf '  the /new decision and it must never auto-start. When the commander answers,\n'
  printf '  close the record with: sq-handoff-request.sh resolve %s\n' "$key"
}

fm_handoff_surface_main() {
  local surfaced key kind payload
  fm_handoff_surface_mark surfaced || exit 1
  [ -n "$surfaced" ] || exit 0
  while IFS=$'\t' read -r key kind payload || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    print_handoff_card "$key" "$kind" "$payload"
    printf '\n'
  done <<EOF
$surfaced
EOF
}

fm_handoff_surface_main "$@"
