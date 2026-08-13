#!/usr/bin/env bash
# Durable new-session handoff queue for a Squad primary base.
#
# At a milestone close - a merged milestone PR or a drained flight queue -
# Squad records the event here with `add`, so a hook surface can present the
# new-session handoff card exactly once per milestone. The commander owns the
# /new decision; this queue only makes the suggestion deterministic instead of
# ad hoc. See docs/handoff-request.md for the mechanism and the
# session-handoff skill for the operating contract.
#
# Wire format, one record per line, TAB separated:
#   ts<TAB>seq<TAB>kind<TAB>key<TAB>state<TAB>payload
#   ts      epoch seconds when the record was written
#   seq     monotonic per-base counter, never reused
#   kind    pr-merged | queue-drained (the milestone-close reason)
#   key     unique milestone key; add never creates a second record for it
#   state   pending -> surfaced -> resolved
#   payload milestone context (tabs, newlines, and carriage returns collapse
#           to spaces, so the TAB wire format can never be broken)
#
# CLI:
#   sq-handoff-request.sh add <kind> <key> <payload...>
#   sq-handoff-request.sh resolve <key>
#   sq-handoff-request.sh list [--all|--pending|--surfaced|--open]
#   sq-handoff-request.sh --help
#
# add     writes a pending record. Idempotent by kind+key: when a record with
#         the same kind and key already exists in ANY state, add leaves it
#         untouched, prints nothing, and exits 0, so the once-per-milestone
#         guarantee holds at the source and a retried write cannot duplicate.
# resolve marks the record for <key> resolved. Squad runs this after the
#         commander answers the handoff question.
# list    prints matching records, newest first. The default --open filter
#         shows everything not yet resolved (pending and surfaced), which is
#         the still-actionable set a session start must see.
# --help  prints usage.
#
# Every successful data command prints exactly what the command owns and no
# diagnostics. Exit 0 on success, 1 when a requested record is absent, 2 on
# invalid use. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"

# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"

SQUAD_HANDOFF_KINDS='pr-merged queue-drained'
SQUAD_HANDOFF_QUEUE="$STATE/.handoff-queue"
SQUAD_HANDOFF_LOCK="$STATE/.handoff-queue.lock"
SQUAD_HANDOFF_SEQ="$STATE/.handoff-queue.seq"

fm_handoff_kind_valid() {  # <kind>
  case " $SQUAD_HANDOFF_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_handoff_key_valid() {  # <key>
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

fm_handoff_sanitize_payload() {  # <payload> <result-var>
  local value=${1-} result_var=$2
  value=$(printf '%s' "$value" | tr '\t\r\n' '   ')
  printf -v "$result_var" '%s' "$value"
}

# All queue mutations run under the shared handoff lock so a concurrent
# surfaver (the session-start digest and the Pi turn-end extension can race)
# can never observe or double-mark a partial transition.

fm_handoff_next_seq() {  # <result-var>; caller must hold the lock
  local result_var=$1 next=0
  [ -f "$SQUAD_HANDOFF_SEQ" ] && next=$(cat "$SQUAD_HANDOFF_SEQ" 2>/dev/null || printf '0')
  case "$next" in ''|*[!0-9]*) next=0 ;; esac
  next=$((next + 1))
  printf '%s\n' "$next" > "$SQUAD_HANDOFF_SEQ.tmp.$$" 2>/dev/null || return 1
  mv -f "$SQUAD_HANDOFF_SEQ.tmp.$$" "$SQUAD_HANDOFF_SEQ" 2>/dev/null || return 1
  printf -v "$result_var" '%s' "$next"
}

fm_handoff_record_exists() {  # <kind> <key>; caller must hold the lock
  local kind=$1 key=$2 rkind rkey
  [ -f "$SQUAD_HANDOFF_QUEUE" ] || return 1
  while IFS=$'\t' read -r _ts _seq rkind rkey _state _payload || [ -n "$rkey" ]; do
    [ -n "$rkey" ] || continue
    [ "$rkind" = "$kind" ] && [ "$rkey" = "$key" ] && return 0
  done < "$SQUAD_HANDOFF_QUEUE"
  return 1
}

fm_handoff_add() {  # <kind> <key> <payload>
  local kind=$1 key=$2 payload=$3 seq ts
  fm_handoff_kind_valid "$kind" || return 2
  fm_handoff_key_valid "$key" || return 2
  fm_lock_try_acquire "$SQUAD_HANDOFF_LOCK" || return 1
  if fm_handoff_record_exists "$kind" "$key"; then
    fm_lock_release "$SQUAD_HANDOFF_LOCK"
    return 0
  fi
  if ! fm_handoff_next_seq seq; then
    fm_lock_release "$SQUAD_HANDOFF_LOCK"
    return 1
  fi
  ts=$(date +%s 2>/dev/null || printf '0')
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$seq" "$kind" "$key" pending "$payload" >> "$SQUAD_HANDOFF_QUEUE"; then
    fm_lock_release "$SQUAD_HANDOFF_LOCK"
    return 1
  fi
  fm_lock_release "$SQUAD_HANDOFF_LOCK"
  return 0
}

fm_handoff_resolve() {  # <key>
  local key=$1 found=0 write_ok=1 tmp ts seq kind rkey state payload
  fm_handoff_key_valid "$key" || return 2
  fm_lock_try_acquire "$SQUAD_HANDOFF_LOCK" || return 1
  tmp=$(mktemp "$STATE/.handoff-queue.XXXXXX") || {
    fm_lock_release "$SQUAD_HANDOFF_LOCK"
    return 1
  }
  while IFS=$'\t' read -r ts seq kind rkey state payload || [ -n "$rkey" ]; do
    [ -n "$rkey" ] || continue
    if [ "$rkey" = "$key" ] && [ "$state" != resolved ]; then
      state=resolved
      found=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$seq" "$kind" "$rkey" "$state" "$payload" >> "$tmp" || write_ok=0
  done < "$SQUAD_HANDOFF_QUEUE"
  if [ "$write_ok" -eq 0 ]; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$SQUAD_HANDOFF_LOCK"
    return 1
  fi
  if [ "$found" -eq 1 ]; then
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
  [ "$found" -eq 1 ] || return 1
  return 0
}

fm_handoff_list() {  # <filter: all|pending|surfaced|open>
  local filter=$1 ts seq kind key state payload
  [ -f "$SQUAD_HANDOFF_QUEUE" ] || return 0
  sort -t $'\t' -k2,2 -rn "$SQUAD_HANDOFF_QUEUE" 2>/dev/null | while IFS=$'\t' read -r ts seq kind key state payload || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    case "$filter" in
      pending) [ "$state" = pending ] || continue ;;
      surfaced) [ "$state" = surfaced ] || continue ;;
      open) [ "$state" = resolved ] && continue ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$seq" "$kind" "$key" "$state" "$payload"
  done
}

fm_handoff_usage() {
  cat <<'EOF'
Usage:
  bin/sq-handoff-request.sh add <kind> <key> <payload...>
  bin/sq-handoff-request.sh resolve <key>
  bin/sq-handoff-request.sh list [--all|--pending|--surfaced|--open]
  bin/sq-handoff-request.sh --help

Kinds: pr-merged queue-drained
State: pending -> surfaced -> resolved
EOF
}

fm_handoff_main() {
  local command=${1-} kind key payload filter
  case "$command" in
    -h|--help|help)
      fm_handoff_usage
      ;;
    add)
      [ "$#" -ge 4 ] || { fm_handoff_usage >&2; return 2; }
      kind=$2
      key=$3
      shift 3
      payload=$*
      fm_handoff_sanitize_payload "$payload" payload
      fm_handoff_add "$kind" "$key" "$payload"
      ;;
    resolve)
      [ "$#" -eq 2 ] || { fm_handoff_usage >&2; return 2; }
      fm_handoff_resolve "$2"
      ;;
    list)
      filter=open
      [ "$#" -ge 1 ] || { fm_handoff_usage >&2; return 2; }
      if [ "$#" -ge 2 ]; then
        case "$2" in
          --all) filter=all ;;
          --pending) filter=pending ;;
          --surfaced) filter=surfaced ;;
          --open) filter=open ;;
          *) fm_handoff_usage >&2; return 2 ;;
        esac
        [ "$#" -eq 2 ] || { fm_handoff_usage >&2; return 2; }
      fi
      fm_handoff_list "$filter"
      ;;
    *)
      fm_handoff_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_handoff_main "$@"
  exit $?
fi
