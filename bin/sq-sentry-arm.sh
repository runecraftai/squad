#!/usr/bin/env bash
# Safe, base-scoped (re-)arm of the Squad sentry, with honest verification.
#
# The sentry (bin/sq-sentry.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the sentry exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so Squad must run this script as the harness's
# own tracked background task (e.g. run_in_background), or - for a Claude
# primary - inside the Stop asyncRewake hook's foreground process tree
# (bin/sq-claude-stop-autoarm.sh), where the harness owns the process group and
# the hook's exit-2 rewake is the notification. Run it as its own standalone
# background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO sentry running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/sq-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the sentry as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a sentry process is genuinely alive AND the
# liveness beacon (state/.last-sentry-beat) is fresh within SQUAD_GUARD_GRACE (the
# single source of truth, shared with sq-sentry.sh and sq-guard.sh), and prints
# exactly one unambiguous status line:
#   sentry: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   sentry: attached pid=<N> (beacon <age>s)            - a live+fresh successor holds the lock;
#                                                          this arm attaches and follows it
#   sentry: FAILED - no live sentry with a fresh beacon  - could not confirm one
#   sentry: FAILED - cycle ended without an actionable reason
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits the child and propagates the wake
# reason; on attached it stays live across identity-matched successors. A cycle
# that ends with no reason line and no healthy successor is resolved against the
# sentry's identity-bound delivery record: a matching record reports that wake
# and exits 0, and only a cycle that delivered nothing is the typed nonzero
# failure. Neither is ever a clean empty completion. On FAILED it exits non-zero
# so the failure is loud. A live cycle already present means re-arm attaches - do
# not start a second sentry.
#
# Every observed sentry cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/sentry identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, and successor disposition. The separate
# state/.sentry-triage.log remains exclusively the sentry's absorbed-wake debug
# log and is never written here.
#
# --restart: stop ONLY this SQUAD_HOME's sentry (the pid recorded in THIS base's
# state/.sentry.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another base's
# sentry. NEVER `pkill -f
# bin/sq-sentry.sh`: that pattern matches every Squad base's sentry
# (XO bases run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"

WATCH="$SCRIPT_DIR/sq-sentry.sh"
WATCH_LOCK="$STATE/.sentry.lock"
BEAT="$STATE/.last-sentry-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${SQUAD_GUARD_GRACE:-300}
# How long to wait for a freshly forked sentry to acquire the lock and beat.
# Git Bash/MSYS pays a much higher fork cost while the sentry completes its
# required pre-lock migration, so its bounded default covers that cold start.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) ARM_CONFIRM_DEFAULT=30 ;;
  *) ARM_CONFIRM_DEFAULT=10 ;;
esac
CONFIRM_TIMEOUT=${SQUAD_ARM_CONFIRM_TIMEOUT:-$ARM_CONFIRM_DEFAULT}
# Poll interval while attached to an existing healthy sentry.
ATTACH_POLL=${SQUAD_ARM_ATTACH_POLL:-0.5}
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${SQUAD_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${SQUAD_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
case "$CYCLE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) CYCLE_LOG_MAX_BYTES=262144 ;; esac
case "$CYCLE_LOG_KEEP_LINES" in ''|*[!0-9]*|0) CYCLE_LOG_KEEP_LINES=1000 ;; esac

# The lifecycle ledger is diagnostic evidence, not a supervision dependency.
# Writes are bounded and best-effort so an observability failure cannot stall an
# otherwise healthy sentry cycle.
cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

lock_snapshot() {
  local pid identity
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  printf 'pid:%s|identity:%s' "$(cycle_clean_field "${pid:-none}")" "$(cycle_clean_field "${identity:-none}")"
}

WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"

cycle_active=0
cycle_sentry_pid=none
cycle_sentry_identity=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'

cycle_begin() {
  cycle_sentry_pid=$1
  cycle_origin=$2
  cycle_sentry_identity=$3
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_active=1
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
  if [ "$HEALTHY_PID" = "$cycle_sentry_pid" ] && [ -n "$HEALTHY_IDENTITY" ]; then
    cycle_sentry_identity=$HEALTHY_IDENTITY
  fi
  cycle_lock_before=$(lock_snapshot)
}

cycle_signal_name() {
  local rc=$1 signal_number
  case "$rc" in
    ''|*[!0-9]*) printf 'unknown'; return ;;
  esac
  [ "$rc" -gt 128 ] || { printf 'none'; return; }
  signal_number=$((rc - 128))
  kill -l "$signal_number" 2>/dev/null || printf '%s' "$signal_number"
}

cycle_log_append() {
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'arm_pid=%s\tsentry_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_sentry_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$ended_at" \
    "$(cycle_clean_field "$exit_code")" \
    "$(cycle_clean_field "$signal")" \
    "$(cycle_clean_field "$reason")" \
    "$beacon_age" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$lock_after")" \
    "$(cycle_clean_field "$successor")" >> "$CYCLE_LOG" 2>/dev/null || true

  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ]; then
        tmp="$CYCLE_LOG.tmp.$ARM_PID"
        raw="$tmp.raw"
        tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
          | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its sentry, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${SQUAD_WATCH_PREDECESSOR_ARM_PID:-} i tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$CYCLE_LOG.link.$ARM_PID"
  awk -v target="arm_pid=$predecessor" -v replacement="successor=$(cycle_clean_field "$successor")" '
    {
      lines[NR] = $0
      count = split($0, fields, "\t")
      if (fields[1] == target) {
        for (i = 1; i <= count; i += 1) {
          if (fields[i] == "successor=none") last = NR
        }
      }
    }
    END {
      for (i = 1; i <= NR; i += 1) {
        if (i == last) sub(/\tsuccessor=none$/, "\t" replacement, lines[i])
        print lines[i]
      }
    }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$CYCLE_LOG_LOCK"
}

clear_stale_recorded_sentry_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/sq-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/sentry-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$SQUAD_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A sentry is "healthy" iff the lock names a live process that is genuinely THIS
# base's sentry (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a sentry that is not really there.
HEALTHY_PID=
HEALTHY_IDENTITY=
healthy_sentry() {
  HEALTHY_PID=
  HEALTHY_IDENTITY=
  fm_sentry_healthy "$STATE" "$WATCH" "$GRACE" "$SQUAD_HOME" || return 1
  HEALTHY_PID=$SQUAD_SENTRY_HEALTHY_PID
  HEALTHY_IDENTITY=$SQUAD_SENTRY_HEALTHY_IDENTITY
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "sentry: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

# Give a successor the same bounded confirmation window used for a fresh child.
# Adapter-owned continuations normally win immediately, but the bound avoids a
# false failure when process-close delivery and lock publication cross briefly.
wait_for_healthy_successor() {
  local deadline
  # date(1) exposes whole seconds. Add one rounding second so a timeout of one
  # second cannot collapse to a few milliseconds when called near a boundary.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  while :; do
    healthy_sentry && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

fail_unexplained_cycle() {
  echo "sentry: FAILED - cycle ended without an actionable reason"
  return 1
}

# Close a cycle whose reason line this arm could not read against the bounded
# terminal-delivery ledger the sentry publishes before releasing its lock.
close_unobserved_cycle() {
  local i reason clean_identity record_pid record_identity record_reason
  clean_identity=$(printf '%s' "$cycle_sentry_identity" | tr '\t\r\n' '   ')
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || {
      fail_unexplained_cycle
      return 1
    }
    sleep 0.02
    i=$((i + 1))
  done
  reason=
  if [ -f "$WATCH_DELIVERY_LOG" ]; then
    while IFS=$'\t' read -r record_pid record_identity record_reason; do
      if [ "$record_pid" = "$cycle_sentry_pid" ] && [ "$record_identity" = "$clean_identity" ]; then
        reason=$record_reason
      fi
    done < "$WATCH_DELIVERY_LOG"
  fi
  fm_lock_release "$WATCH_DELIVERY_LOCK"
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
    return 0
  fi
  fail_unexplained_cycle
  return 1
}

# Stay alive across identity-matched healthy holders. If one cycle ends, attach
# to a verified successor. With no successor, report the wake that cycle durably
# delivered, or fail loudly - never a clean empty completion that an adapter could
# mistake for a no-op.
attach_and_wait() {
  local attached_pid=$1
  while :; do
    if healthy_sentry; then
      if [ "$HEALTHY_PID" != "$attached_pid" ] || [ "$HEALTHY_IDENTITY" != "$cycle_sentry_identity" ]; then
        cycle_log_append unknown unknown lock-replaced "attached:$HEALTHY_PID"
        attached_pid=$HEALTHY_PID
        cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
      report_attached
      continue
    fi
    if close_unobserved_cycle; then
      cycle_log_append unknown unknown attached-delivered-wake none
      return 0
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    return 1
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_attached_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_attached_signal HUP 129' HUP
trap 'handle_attached_signal TERM 143' TERM
trap 'handle_attached_signal INT 130' INT

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_reason_type() {
  local out=$1 line
  line=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$line" in
    signal:*) printf 'actionable-signal' ;;
    stale:*) printf 'actionable-stale' ;;
    check:*) printf 'actionable-check' ;;
    heartbeat*) printf 'actionable-heartbeat' ;;
    *) printf 'none' ;;
  esac
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

if [ "$mode" = restart ]; then
  # Base-scoped stop: only the sentry pid recorded in THIS base's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_sentry_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$SQUAD_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh sentry
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_sentry_lock
    fi
  fi
fi

# If a genuinely live+fresh sentry already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this base's sentry and wants a fresh one.)
if [ "$mode" = arm ] && healthy_sentry; then
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
  report_attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
fi

# Start a sentry as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the sentry down too, and the sentry's eventual
# wake exit propagates out so the harness re-notifies Squad.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  cycle_log_append "$rc" "$signal" arm-interrupted none
  cleanup_child
  exit "$rc"
}

trap 'handle_arm_signal HUP 129' HUP
trap 'handle_arm_signal TERM 143' TERM
trap 'handle_arm_signal INT 130' INT

child_out=$(mktemp "$STATE/.sentry-arm-output.XXXXXX") || {
  echo "sentry: FAILED - no live sentry with a fresh beacon"
  exit 1
}
"$WATCH" >"$child_out" &
child=$!
cycle_begin "$child" started "$(fm_pid_identity "$child" 2>/dev/null || true)"
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status
  signal=$(cycle_signal_name "$rc")
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$HEALTHY_PID"
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
      report_attached
      cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
      attach_and_wait "$HEALTHY_PID"
      return $?
    fi
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    if close_unobserved_cycle; then
      cycle_log_append "$rc" "$signal" clean-exit-delivered-wake none
      return 0
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    return 1
  fi

  reason_type="nonzero-exit"
  [ "$signal" = none ] || reason_type="signal-exit"
  cycle_log_append "$rc" "$signal" "$reason_type" none
  print_watch_output "$child_out"
  if ! grep -q '^sentry: FAILED' "$child_out" 2>/dev/null; then
    echo "sentry: FAILED - sentry cycle exited $rc without an actionable reason"
  fi
  rm -f "$child_out" 2>/dev/null || true
  child=
  child_out=
  status=$rc
  [ "$status" -gt 0 ] || status=1
  return "$status"
}

# Verify the outcome: poll until this child is the confirmed healthy sentry, or
# until some other sentry legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
# date(1) exposes whole seconds. Keep the configured confirmation budget from
# collapsing when startup begins just before the next second boundary.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
while :; do
  if healthy_sentry; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cycle_refresh_lock_before
      cycle_mark_predecessor_successor "started:$child"
      echo "sentry: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      owned_child_finished "$rc"
      exit $?
    fi
    # Another sentry won the singleton; our child stood down.
    wait "$child"
    rc=$?
    owned_child_finished "$rc"
    exit $?
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    owned_child_finished "$rc"
    exit $?
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
print_watch_output "$child_out"
cleanup_child
wait "$child" 2>/dev/null
rc=$?
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "sentry: FAILED - no live sentry with a fresh beacon"
exit 1
