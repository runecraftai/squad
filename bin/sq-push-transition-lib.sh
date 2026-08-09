#!/usr/bin/env bash
# Shared owner of the sentry's native push-transition escalation.
#
# The sentry and event-wait smoke tests source this library instead of loading
# the whole sentry to obtain handle_push_transition. Its source list is limited
# to the four production boundaries the transition handler actually calls.

SQUAD_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/sq-stand-to-lib.sh
. "$SQUAD_PUSH_TRANSITION_LIB_DIR/sq-stand-to-lib.sh"
# shellcheck source=bin/sq-classify-lib.sh
. "$SQUAD_PUSH_TRANSITION_LIB_DIR/sq-classify-lib.sh"
# shellcheck source=bin/sq-backend.sh
. "$SQUAD_PUSH_TRANSITION_LIB_DIR/sq-backend.sh"
# shellcheck source=bin/sq-transition-lib.sh
. "$SQUAD_PUSH_TRANSITION_LIB_DIR/sq-transition-lib.sh"

TRIAGE_LOG="$STATE/.sentry-triage.log"
TRIAGE_LOG_MAX_BYTES=${SQUAD_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
SQUAD_WAKE_POST_OUTPUT_ACTION=
SQUAD_WATCH_DELIVERY_PID=
SQUAD_WATCH_DELIVERY_IDENTITY=
WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_MAX_BYTES=${SQUAD_WATCH_DELIVERY_MAX_BYTES:-65536}
WATCH_DELIVERY_KEEP_LINES=${SQUAD_WATCH_DELIVERY_KEEP_LINES:-64}
case "$WATCH_DELIVERY_MAX_BYTES" in ''|*[!0-9]*|0) WATCH_DELIVERY_MAX_BYTES=65536 ;; esac
case "$WATCH_DELIVERY_KEEP_LINES" in ''|*[!0-9]*|0) WATCH_DELIVERY_KEEP_LINES=64 ;; esac

watch_delivery_clean_identity() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_clean_reason() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-4096
}

watch_delivery_publish() {
  local reason=$1 i size tmp raw
  [ -n "$SQUAD_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$SQUAD_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf '%s\t%s\t%s\n' \
    "$SQUAD_WATCH_DELIVERY_PID" \
    "$(watch_delivery_clean_identity "$SQUAD_WATCH_DELIVERY_IDENTITY")" \
    "$(watch_delivery_clean_reason "$reason")" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  size=$(wc -c < "$WATCH_DELIVERY_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$WATCH_DELIVERY_MAX_BYTES" ]; then
        tmp="$WATCH_DELIVERY_LOG.tmp.$SQUAD_WATCH_DELIVERY_PID"
        raw="$tmp.raw"
        tail -n "$WATCH_DELIVERY_KEEP_LINES" "$WATCH_DELIVERY_LOG" 2>/dev/null \
          | tail -c "$WATCH_DELIVERY_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^[0-9]+\t/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$WATCH_DELIVERY_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$WATCH_DELIVERY_LOCK"
}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  local output_status=0
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  trap '' HUP INT TERM
  [ -z "$SQUAD_WAKE_POST_OUTPUT_ACTION" ] || trap '' PIPE
  if echo "$1"; then
    output_status=0
    watch_delivery_publish "$1" || true
  else
    output_status=1
  fi
  if [ -n "$SQUAD_WAKE_POST_OUTPUT_ACTION" ]; then
    "$SQUAD_WAKE_POST_OUTPUT_ACTION" "$output_status" || true
  fi
  [ "$output_status" -eq 0 ] || exit "$output_status"
  exit 0
}

_hb_surfaced_path() {
  printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"
}

# Record a commander-relevant status after its durable wake has been enqueued.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_commander_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}
