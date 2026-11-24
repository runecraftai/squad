#!/usr/bin/env bash
# sq-afk-return.sh - deterministic away-mode return catch-up gate.
#
# Usage:
#   sq-afk-return.sh          Stop away mode, drain catch-up, and open/check gate.
#   sq-afk-return.sh begin    Same as the default command.
#   sq-afk-return.sh check    Re-drain and close the gate only after blockers resolve.
#   sq-afk-return.sh guard    Read-only refusal while away or catch-up is pending.
#
# `blocked:` is the operator protocol's Squad-actionable verb. A live task's
# open blocked event must be remediated and closed with `resolved [key=...]`, or
# explicitly reclassified in the status stream with a durable reason, before an
# ordinary commander request may proceed. `needs-decision:` belongs to the
# configured approval authority and is deliberately not part of this blocker
# gate; normal reporting routes it through the AGENTS.md section 7 contract.
#
# The durable state/.afk-return-catchup file is written BEFORE daemon shutdown,
# so a crash between stopping, draining, and blocker handling fails closed. It
# retains the drained wake, buffered-escalation, and wedge-marker evidence until
# every live open blocker is closed and `check` succeeds. Repeated begin/check
# calls are idempotent. `guard` never mutates state and is suitable for ordinary
# read entrypoints such as sq-sitrep-snapshot.sh. The away-mode ledger is presented
# once, as one summary, on the run that clears the gate; a re-run after a clean
# return finds nothing left to present and prints no summary again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
GATE="$STATE/.afk-return-catchup"
LOCK="$STATE/.afk-return-catchup.lock"

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

append_evidence() {  # <kind> <text> <file>
  local kind=$1 text=$2 file=$3 clean record
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    clean=$(printf '%s' "$line" | clean_field)
    record=$(printf 'evidence\t%s\t%s' "$kind" "$clean")
    grep -Fqx "$record" "$file" 2>/dev/null || printf '%s\n' "$record" >> "$file"
  done <<EOF
$text
EOF
}

preserve_evidence() {  # <destination>
  local destination=$1
  [ -f "$GATE" ] || return 0
  grep '^evidence'"$(printf '\t')" "$GATE" >> "$destination" 2>/dev/null || true
}

scan_open_blockers() {  # -> tab-separated blocker rows
  local meta id status key verb summary clean_summary
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    status="$STATE/$id.status"
    [ -f "$status" ] || continue
    while IFS="$(printf '\t')" read -r key verb summary; do
      [ "$verb" = blocked ] || continue
      clean_summary=$(printf '%s' "$summary" | clean_field)
      printf 'blocker\t%s\t%s\t%s\n' "$id" "$key" "$clean_summary"
    done <<EOF
$(status_open_decisions "$status")
EOF
  done
}

write_pending_seed() {  # Fail-closed marker before any lifecycle mutation.
  local pending started
  mkdir -p "$STATE" || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  {
    printf 'schema\tsq-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tstopping-and-draining\n'
    preserve_evidence /dev/stdout
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

write_gate() {  # <evidence-file> <blockers-file>
  local evidence=$1 blockers=$2 pending started
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  {
    printf 'schema\tsq-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tblocked\n'
    cat "$evidence" 2>/dev/null || true
    cat "$blockers" 2>/dev/null || true
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

fmt_epoch() {  # <epoch> -> local "MM-DD HH:MM" (GNU date, then BSD date)
  date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# print_summary: the one away-mode presentation. Escalation evidence is the away
# ledger, one "<epoch>|<class>|<text>" per entry; a bare line from before the ledger
# format is presented as an unclassed escalation. A drained afk-* check record is the
# daemon's own durable notice (a parked ledger or an item the ledger could not
# record) and is presented as an event; each wedge marker line is presented unless
# a drained record already carries the same notice. Other queued wake records and drain sections (open
# decisions, pending teardown, guard notices) are open items, not away-mode events.
# Prints nothing when there is nothing to present.
notice_key() {  # <notice text> -> identity shared by a queued afk-* record and its marker line
  local text=$1 rest
  case "$text" in
    'check: away-mode ledger could not record: '*)
      printf 'u:%s' "${text#check: away-mode ledger could not record: }" ;;
    'away-mode ledger undeliverable as of '*': '*)
      rest=${text#away-mode ledger undeliverable as of }
      printf 'u:%s' "${rest#*: }" ;;
    'check: away-mode escalations held '*'s past max-defer'*)
      rest=${text#check: away-mode escalations held }
      printf 'p:%s' "${rest%%s past max-defer*}" ;;
    'away-mode ledger held '*'s past max-defer'*)
      rest=${text#away-mode ledger held }
      printf 'p:%s' "${rest%%s past max-defer*}" ;;
    *) printf 'x:%s' "$text" ;;
  esac
}

print_summary() {  # <evidence-file>
  local file=$1 tag kind text ts cls item label when re afk_re seq=0 absence locators record receipt
  local data="${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}"
  local escalated=0 routine=0 notice=0 queued=0 rows='' afk_keys='' wedges='' notices='' urls='' statuses='' events=''
  re='^[0-9]+ [0-9]+ (signal|stale|check|heartbeat) '
  afk_re='^([0-9]+) [0-9]+ check afk-[A-Za-z0-9._-]+ (.*)$'
  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] || continue
    case "$kind" in
      escalation)
        ts='' cls='' item=$text
        if [[ $text == *'|'* ]]; then
          IFS='|' read -r ts cls item <<< "$text"
        fi
        case "$ts" in ''|*[!0-9]*) ts='' cls=escalation item=$text ;; esac
        if [ "$cls" = routine ]; then
          routine=$((routine + 1)); label=routine
        else
          escalated=$((escalated + 1)); label=escalation
        fi
        rows="${rows}${ts:-0}"$'\t'"${label}"$'\t'"${item}"$'\n'
        ;;
      wake)
        if [[ $text =~ $afk_re ]]; then
          notice=$((notice + 1))
          rows="${rows}${BASH_REMATCH[1]}"$'\t'"daemon-notice"$'\t'"${BASH_REMATCH[2]}"$'\n'
          afk_keys="${afk_keys}$(notice_key "${BASH_REMATCH[2]}")"$'\n'
        elif [[ $text =~ $re ]]; then
          queued=$((queued + 1))
        else
          case "$text" in 'wake annotation:'*|'') ;; *) notices="${notices}  ${text}"$'\n' ;; esac
        fi
        ;;
      wedge)
        wedges="${wedges}${text}"$'\n'
        ;;
    esac
  done < "$file"
  if [ -n "$wedges" ]; then
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      printf '%s' "$afk_keys" | grep -Fqx -- "$(notice_key "$item")" && continue
      notice=$((notice + 1))
      rows="${rows}0"$'\t'"daemon-notice"$'\t'"${item}"$'\n'
    done <<< "$wedges"
  fi
  [ "$queued" -eq 0 ] || notices="  queued wake records drained: ${queued}"$'\n'"${notices}"
  if [ $((escalated + routine + notice)) -eq 0 ]; then
    # No away-mode events: only live open items remain, shown without the absence
    # summary header so a re-run never presents the summary again.
    [ -z "$notices" ] || printf 'catch-up open items (still open at return):\n%s' "$notices"
    return 0
  fi
  while IFS="$(printf '\t')" read -r ts label item; do
    [ -n "$label" ] || continue
    seq=$((seq + 1))
    when=''
    [ "$ts" = 0 ] || when="$(fmt_epoch "$ts") "
    events="${events}  ${seq}. ${when}[${label}] ${item}"$'\n'
    urls="${urls}$(printf '%s\n' "$item" | grep -Eo 'https://[^[:space:]]+' || true)"$'\n'
    statuses="${statuses}$(printf '%s\n' "$item" | grep -Eo '[A-Za-z0-9._-]+\.status' || true)"$'\n'
  done <<< "$(printf '%s' "$rows" | sort -s -t "$(printf '\t')" -k1,1n)"
  printf 'catch-up summary (one presentation for this absence)\n'
  printf '  counts: escalation=%d routine=%d daemon-notice=%d\n' "$escalated" "$routine" "$notice"
  [ -z "$events" ] || printf '  events in order:\n%s' "$events"
  locators=$(printf '%s\n' "$urls" | sed '/^$/d' | sort -u | sed 's/^/    /')
  statuses=$(printf '%s\n' "$statuses" | sed '/^$/d' | sort -u | sed 's#^#    state/#')
  record=$(open_absence_records "$data")
  case "$record" in ''|*$'\n'*) record='' ;; esac
  if [ -n "$record" ]; then
    absence="$data/$record"
  else
    absence=$(find "$data" -maxdepth 1 -name 'absence-*.md' 2>/dev/null | sort | tail -1 || true)
  fi
  if [ -n "$locators$statuses$absence" ]; then
    printf '  links and paths:\n'
    [ -z "$locators" ] || printf '%s\n' "$locators"
    [ -z "$statuses" ] || printf '%s\n' "$statuses"
    [ -z "$absence" ] || printf '    %s\n' "$absence"
  fi
  # The opt-in queue pilot's durable receipt: when it dispatched, it names the
  # exact task and the verification, whether or not the daemon survived long
  # enough to ledger that outcome.
  if [ -n "$record" ] && [ -f "$STATE/queue-pilot.intent" ]; then
    receipt=$(awk -v generation="${record%.md}" '
      $0 == ("absence_generation=" generation) { matches = 1 }
      /^(task|outcome|detail)=/ { fields = fields "    " $0 "\n" }
      END { if (matches) printf "%s", fields }
    ' "$STATE/queue-pilot.intent" 2>/dev/null) || receipt=''
    [ -z "$receipt" ] || printf '  queue pilot receipt:\n    %s\n%s\n' "$STATE/queue-pilot.intent" "$receipt"
  fi
  printf '  never executed while you were away: any merge outside the grant quoted in the absence record, destructive or irreversible actions, security-sensitive choices, and anything outside the accepted scope of the judge; each waits for you.\n'
  [ -z "$notices" ] || printf '  open items at return:\n%s' "$notices"
}

print_blockers() {  # <file>
  local file=$1 tag id key summary
  while IFS="$(printf '\t')" read -r tag id key summary; do
    [ "$tag" = blocker ] || continue
    printf 'Squad-actionable blocker: %s [key=%s] %s\n' "$id" "$key" "$summary"
  done < "$file"
}

clear_delivery_artifacts() {
  rm -f \
    "$STATE/.subsuper-escalations" \
    "$STATE/.subsuper-escalations.since" \
    "$STATE/.subsuper-routine" \
    "$STATE/.subsuper-parked-notified" \
    "$STATE/.subsuper-inject-wedged"
}

return_guard() {
  if [ -e "$STATE/.afk" ]; then
    printf 'sq-afk-return: away mode is still active; run bin/sq-afk-return.sh before ordinary commander work\n' >&2
    return 3
  fi
  if [ -e "$GATE" ]; then
    printf 'sq-afk-return: return catch-up is pending; remediate or durably reclassify every listed blocker, then run bin/sq-afk-return.sh check\n' >&2
    print_blockers "$GATE" >&2
    return 3
  fi
  return 0
}

return_reconcile() {
  local evidence blockers drained wedge escalations lifecycle_ok=1
  evidence=$(mktemp "$STATE/.afk-return-evidence.XXXXXX") || return 1
  blockers=$(mktemp "$STATE/.afk-return-blockers.XXXXXX") || { rm -f "$evidence"; return 1; }
  preserve_evidence "$evidence"

  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ]; then
    if ! "$SCRIPT_DIR/sq-afk-launch.sh" stop; then
      lifecycle_ok=0
      append_evidence lifecycle 'away-mode shutdown failed; lifecycle state preserved for retry' "$evidence"
    fi
  fi

  drained=$("$SCRIPT_DIR/sq-stand-to-drain.sh") || {
    append_evidence lifecycle 'durable wake drain failed; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
    drained=""
  }
  append_evidence wake "$drained" "$evidence"

  if [ -s "$STATE/.subsuper-inject-wedged" ]; then
    wedge=$(cat "$STATE/.subsuper-inject-wedged" 2>/dev/null || true)
    append_evidence wedge "$wedge" "$evidence"
  fi
  if [ -s "$STATE/.subsuper-escalations" ] || [ -s "$STATE/.subsuper-routine" ]; then
    escalations=$(cat "$STATE/.subsuper-routine" "$STATE/.subsuper-escalations" 2>/dev/null | sort -s -t'|' -k1,1n || true)
    append_evidence escalation "$escalations" "$evidence"
  fi

  scan_open_blockers > "$blockers"
  if [ "$lifecycle_ok" -ne 1 ] || [ -s "$blockers" ]; then
    write_gate "$evidence" "$blockers" || { rm -f "$evidence" "$blockers"; return 1; }
    printf 'sq-afk-return: catch-up must finish before the commander request\n' >&2
    printf 'sq-afk-return: %s away-mode event(s) are held in the catch-up record; one summary is presented once the blockers clear\n' "$(grep -c "^evidence"$'\t'"escalation"$'\t' "$GATE" 2>/dev/null || true)" >&2
    print_blockers "$GATE" >&2
    printf 'sq-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason, then run bin/sq-afk-return.sh check\n' >&2
    rm -f "$evidence" "$blockers"
    return 3
  fi

  print_summary "$evidence"
  rm -f "$GATE"
  clear_delivery_artifacts
  rm -f "$evidence" "$blockers"
  printf 'sq-afk-return: catch-up clear; ordinary commander work may proceed\n'
  return 0
}

main() {
  local mode=${1:-begin} rc
  case "$mode" in
    begin|check) ;;
    guard) return_guard; return ;;
    -h|--help|help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac

  # The mutating begin/check paths need locks and the keyed status fold.
  # `guard` returned above without sourcing sq-stand-to-lib.sh, whose initialization
  # creates the state directory, so the advertised read-only guard is literal.
  # shellcheck source=bin/sq-stand-to-lib.sh
  . "$SCRIPT_DIR/sq-stand-to-lib.sh"
  # shellcheck source=bin/sq-classify-lib.sh
  . "$SCRIPT_DIR/sq-classify-lib.sh"
  # shellcheck source=bin/sq-absence-lib.sh
  . "$SCRIPT_DIR/sq-absence-lib.sh"

  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$LOCK"
  trap 'fm_lock_release "$LOCK"' EXIT
  write_pending_seed || { fm_lock_release "$LOCK"; trap - EXIT; return 1; }
  return_reconcile
  rc=$?
  fm_lock_release "$LOCK"
  trap - EXIT
  return "$rc"
}

main "$@"
