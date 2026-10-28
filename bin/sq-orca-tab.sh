#!/usr/bin/env bash
# Close a recorded Orca mission tab when its mission ends.
# Usage: sq-orca-tab.sh <task-id> done|failed|sync [--force]
# sync reconciles on a status/turn-end event and closes only after a finished turn
# or run declared done or failed; teardown passes done.
# The tab title is Orca's own, so nothing here renames it, and a live, waiting, or
# blocked mission keeps its tab open with no Orca call at all.
# Other backends and legacy records without orca_host_workspace_id are inert.
# The per-terminal receipt serializes closes with teardown; only a confirmed
# close is recorded. Runtime errors preserve the record for retry, except under
# an explicit --force teardown, which lets an unobservable runtime through without
# ever claiming a close that was not confirmed.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}}
STATE=${SQUAD_STATE_OVERRIDE:-$BASE/state}
ID=${1:-} STATE_NAME=${2:-} FORCE=${3:-}
case "$ID" in ''|*[!a-zA-Z0-9_-]*) echo 'error: invalid Orca task id' >&2; exit 2 ;; esac
case "$STATE_NAME" in done|failed|sync) ;; *) echo 'error: invalid Orca tab state' >&2; exit 2 ;; esac
case "$FORCE" in ''|--force) ;; *) echo 'error: invalid Orca tab option' >&2; exit 2 ;; esac
# shellcheck source=bin/sq-backend.sh
. "$SCRIPT_DIR/sq-backend.sh"
META="$STATE/$ID.meta"
[ "$(fm_backend_of_meta "$META")" = orca ] || exit 0
# The hosting workspace owns the tab; the mission worktree owns the execution.
# Keeping them as separate exact identities is what stops a close or send from
# reaching a terminal in the wrong place.
HOST=$(fm_backend_meta_exact_value "$META" orca_host_workspace_id) || exit 0
MISSION=$(fm_backend_meta_exact_value "$META" orca_worktree_id) || { echo 'error: Orca tab has no exact mission worktree identity' >&2; exit 1; }
[ "$HOST" != "$MISSION" ] || { echo "error: Orca hosting workspace and mission worktree are one identity for sq-$ID; preserving tab" >&2; exit 1; }
TERMINAL_COUNT=$(grep -c '^terminal=' "$META" 2>/dev/null || true)
[ "$TERMINAL_COUNT" -ne 0 ] || exit 0
TERMINAL=$(fm_backend_meta_exact_value "$META" terminal) || { echo 'error: Orca tab has no exact terminal identity' >&2; exit 1; }
[ "$(fm_backend_meta_exact_value "$META" window)" = "sq-$ID" ] || exit 1
fm_backend_source orca
# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"
LOCK="$STATE/.orca-tab-$ID.lock"
fm_lock_acquire_wait "$LOCK"
trap 'fm_lock_release "$LOCK"' EXIT
# Re-read under the lock so a concurrent relaunch cannot redirect an old event.
[ "$(fm_backend_meta_exact_value "$META" terminal)" = "$TERMINAL" ] || exit 1
RECEIPT="$STATE/.orca-tab-$ID"
PREVIOUS=$(cat "$RECEIPT" 2>/dev/null || true)
[ "$PREVIOUS" != "$TERMINAL closed" ] || exit 0

record_closed_receipt() {
  local tmp
  tmp=$(umask 077; mktemp "$RECEIPT.XXXXXX")
  printf '%s closed\n' "$TERMINAL" > "$tmp"
  mv -f -- "$tmp" "$RECEIPT"
}

preserve_tab() {  # <reason>
  if [ "$FORCE" = --force ]; then
    echo "warning: $1; continuing because teardown was forced" >&2
    exit 0
  fi
  echo "error: $1; preserving tab" >&2
  exit 1
}

if [ "$STATE_NAME" = sync ]; then
  # Cheap decision first: only a finished turn/run can close a tab, so a live,
  # waiting, or blocked mission never pays for the crew-state probe.
  # shellcheck source=bin/sq-classify-lib.sh
  . "$SCRIPT_DIR/sq-classify-lib.sh"
  case "$(status_line_verb "$(last_status_state_line "$STATE/$ID.status")")" in
    done|failed) ;;
    *) exit 0 ;;
  esac
  # Never let a finished status line supersede a live validation run or busy turn.
  CURRENT=$("$SCRIPT_DIR/sq-crew-state.sh" "$ID" 2>/dev/null) || true
  VERDICT=${CURRENT#state: }; VERDICT=${VERDICT%% ·*}
  case "$VERDICT" in
    working|parked|blocked|paused) exit 0 ;;
  esac
fi
# Handles are runtime-scoped: a tab the commander already closed, or a handle left
# by a previous Orca runtime, must never block the worktree release. Absence from a
# complete hosting-workspace inventory only means the tab is not in that workspace,
# so one exact observation must also show the terminal gone before a close is
# recorded; only an unobservable runtime refuses an ordinary close.
TAB_PRESENCE=$(fm_backend_orca_terminal_presence "$HOST" "$TERMINAL")
case "$TAB_PRESENCE" in
  present) ;;
  mismatch)
    preserve_tab "Orca terminal $TERMINAL is not a tab in hosting workspace $HOST for sq-$ID" ;;
  *)
    LIVE_HOST=$(fm_backend_orca_terminal_observe "$TERMINAL") || LIVE_HOST=
    if [ -n "$LIVE_HOST" ]; then
      [ "$LIVE_HOST" = "$HOST" ] || preserve_tab "Orca terminal $TERMINAL is a tab in hosting workspace $LIVE_HOST, not $HOST, for sq-$ID"
    else
      [ "$TAB_PRESENCE" = absent ] || preserve_tab "Orca cannot observe the tab for sq-$ID"
      record_closed_receipt
      exit 0
    fi ;;
esac
fm_backend_orca_close "$TERMINAL" || preserve_tab "Orca did not confirm close of sq-$ID"
record_closed_receipt
