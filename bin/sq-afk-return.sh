#!/usr/bin/env bash
# sq-afk-return.sh - deterministic away-mode return catch-up gate.
#
# Usage:
#   sq-afk-return.sh          Stop away mode, drain catch-up, and open/check gate.
#   sq-afk-return.sh begin    Same as the default command.
#   sq-afk-return.sh check    Re-drain after blockers resolve.
#   sq-afk-return.sh ack ID   Confirm consumption and close the gate.
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
# every live open blocker is closed and the receipt is acknowledged.
# `guard` never mutates state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
GATE="$STATE/.afk-return-catchup"
LOCK="$STATE/.afk-return-catchup.lock"
RECEIPT="$STATE/.afk-receipt"
RECEIPT_ACK="$STATE/.afk-receipt.ack"
bounded_limit() {
  local value=$1 ceiling=$2
  if [[ $value =~ ^[1-9][0-9]{0,3}$ ]] && [ "$value" -le "$ceiling" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$ceiling"
  fi
}

SUMMARY_MAX_EVENTS=$(bounded_limit "${SQUAD_AFK_SUMMARY_MAX_EVENTS_DEFAULT:-200}" 200)
SUMMARY_MAX_ROWS=$(bounded_limit "${SQUAD_AFK_SUMMARY_MAX_LEDGER_ROWS:-2000}" 2000)

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

append_evidence() {  # <kind> <file>
  LC_ALL=C awk -v kind="$1" '
    { gsub(/[\t\r]/, " ") }
    NF && !seen[$0]++ { printf "evidence\t%s\t%s\n", kind, $0 }
  ' "$2"
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
  [ ! -e "$GATE" ] || { [ -f "$GATE" ]; return; }
  started=$(date +%s) || return 1
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  if ! printf 'schema\tsq-afk-return.v1\nstarted\t%s\nphase\tstopping-and-draining\n' "$started" > "$pending" ||
     ! mv "$pending" "$GATE"; then
    rm -f "$pending"
    return 1
  fi
}

write_gate() {  # <evidence-file> <blockers-file>
  local evidence=$1 blockers=$2 pending started
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  {
    printf 'schema\tsq-afk-return.v1\nstarted\t%s\nphase\tblocked\n' "$started" &&
      awk -F '\t' '$1 == "evidence"' "$evidence" && cat "$blockers"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

fmt_epoch() {  # <epoch> -> local "MM-DD HH:MM" (GNU date, then BSD date)
  date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# Test seam only: a named point after which the return path stops without
# acknowledging, so the crash-and-replay regression can prove the receipt both
# survives and stays single. Unset in production, where it costs one comparison.
crash_point() {  # <point>
  [ "${SQUAD_AFK_RETURN_CRASH:-}" = "$1" ] || return 0
  printf 'sq-afk-return: simulated crash at %s\n' "$1" >&2
  exit 9
}

select_ledger() {
  local file lines retained=0 files=()
  for file in "$STATE/.subsuper-escalations" "$STATE/.subsuper-routine"; do
    [ -e "$file" ] || continue
    [ -f "$file" ] || return 1
    lines=$(LC_ALL=C wc -l < "$file") || return 1
    retained=$((retained + lines))
    files+=("$file")
  done
  LC_ALL=C awk -F'|' -v max="$SUMMARY_MAX_EVENTS" -v budget="$SUMMARY_MAX_ROWS" -v retained="$retained" '
    {
      if ($0 != "") {
        ts = ""; cls = "escalation"
        if (NF >= 3 && $1 ~ /^[0-9]+$/) { ts = $1; if ($2 == "routine") cls = $2 }
        counts[cls]++
        if (ts != "") {
          if (oldest == "" || ts + 0 < oldest + 0) oldest = ts
          if (newest == "" || ts + 0 > newest + 0) newest = ts
        }
        gsub(/[\t\r]/, " ")
        if (seen[$0]++) duplicates++
        else if (kept[cls] < max) {
          printf "evidence\tescalation\t%s\n", $0
          kept[cls]++
        } else capped++
      } else blank++
      if (NR >= budget) exit
    }
    END {
      printf "evidence\tledger-totals\trows=%d read=%d escalation=%d routine=%d duplicates=%d capped=%d blank=%d oldest=%s newest=%s\n", \
        (retained > NR ? retained : NR), NR, counts["escalation"], counts["routine"], duplicates, capped, blank, oldest, newest
    }
  ' "${files[@]+"${files[@]}"}" </dev/null
}

# dropped_accounting: entries the daemon discarded at origin, as "class=count"
# pairs. A repeated notification about a window whose task already finished names
# no new work, so it is counted there and never written to the ledger; reporting
# the count keeps that decision visible instead of silently shrinking the window.
dropped_accounting() {
  local f cls n out=''
  for f in "$STATE"/.subsuper-dropped-* "$STATE"/.sentry-dropped-*; do
    [ -f "$f" ] || continue
    cls=${f##*/.}
    cls=${cls#subsuper-dropped-}
    cls=${cls/#sentry-dropped-/sentry-}
    n=$(cat "$f") || return 1
    [[ $n =~ ^[1-9][0-9]*$ ]] || continue
    out="${out}${out:+, }${cls}=${n}"
  done
  printf '%s' "$out"
}

receipt_identity() {
  awk -F'\t' '$1 == "id" { print $2; exit }' "$RECEIPT" 2>/dev/null || true
}

receipt_ack_identity() {
  awk -F'\t' '$1 == "ack" { print $2; exit }' "$RECEIPT_ACK" 2>/dev/null || true
}

receipt_id() {  # <body-file> -> one identity for one absence and one exact body
  local body=$1 absence base hash
  absence=$(find "$SQUAD_BASE/data" -maxdepth 1 -name 'absence-*.md' 2>/dev/null | sort | tail -1 || true)
  base=${absence:+$(basename "$absence" .md)}
  if [ -z "$base" ]; then
    base=$(awk -F'\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
    base="catchup-${base:-unknown}"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(sha256sum "$body" 2>/dev/null | cut -c1-12)
  else
    hash=$(shasum -a 256 "$body" 2>/dev/null | cut -c1-12)
  fi
  printf '%s-%s-%s' "$base" "${hash:-nohash}" "${body##*.}"
}

receipt_write() {  # <identity> <body-file>; lands the outbox record atomically
  local id=$1 body=$2 pending
  pending=$(mktemp "$STATE/.afk-receipt.pending.XXXXXX") || return 1
  {
    printf 'schema\tsq-afk-receipt.v1\nid\t%s\ncreated\t%s\nbody\n' "$id" "$(date +%s)" && cat "$body"
  } > "$pending" || { rm -f "$pending"; return 1; }
  { [ ! -d "$RECEIPT" ] && mv "$pending" "$RECEIPT"; } || { rm -f "$pending"; return 1; }
}

receipt_show() {
  local line
  {
    while IFS= read -r line; do
      if [ "$line" = body ]; then
        cat
        return $?
      fi
    done
    return 1
  } < "$RECEIPT"
}

receipt_present() {
  receipt_show && printf 'Receipt %s: bin/sq-afk-return.sh ack %s confirms consumption.\n' "$1" "$1"
}

receipt_ack() {
  local id=$1 pending
  pending=$(mktemp "$STATE/.afk-receipt-ack.pending.XXXXXX") || return 1
  {
    printf 'schema\tsq-afk-receipt.v1\nack\t%s\nacknowledged\t%s\n' "$id" "$(date +%s)"
  } > "$pending" || { rm -f "$pending"; return 1; }
  { [ ! -d "$RECEIPT_ACK" ] && mv "$pending" "$RECEIPT_ACK"; } || { rm -f "$pending"; return 1; }
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
  local file=$1 tag kind text ts cls item label when re afk_re seq=0 absence locators
  local escalated=0 routine=0 notice=0 queued=0 rows='' afk_keys='' wedges='' notices='' urls='' statuses='' events=''
  local rows_total=0 rows_read=0 listed=0 duplicates=0 capped=0 blank=0 oldest='' newest='' span drops=''
  re='^[0-9]+ [0-9]+ (signal|stale|check|heartbeat) '
  afk_re='^([0-9]+) [0-9]+ check afk-[A-Za-z0-9._-]+ (.*)$'
  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] || continue
    case "$kind" in
      ledger-totals)
        for item in $text; do
          case "$item" in
            rows=*) rows_total=${item#rows=} ;;
            escalation=*) escalated=${item#escalation=} ;;
            routine=*) routine=${item#routine=} ;;
            read=*) rows_read=${item#read=} ;;
            duplicates=*) duplicates=${item#duplicates=} ;;
            capped=*) capped=${item#capped=} ;;
            blank=*) blank=${item#blank=} ;;
            oldest=*) oldest=${item#oldest=} ;;
            newest=*) newest=${item#newest=} ;;
          esac
        done
        ;;
      drops) drops=$text ;;
      escalation)
        listed=$((listed + 1))
        ts='' cls='' item=$text
        if [[ $text == *'|'*'|'* ]]; then
          IFS='|' read -r ts cls item <<< "$text"
        fi
        case "$ts" in ''|*[!0-9]*) ts='' cls=escalation item=$text ;; esac
        if [ "$cls" = routine ]; then label=routine; else label=escalation; fi
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
  if [ $((rows_total + notice)) -eq 0 ] && [ -z "$drops" ]; then
    # No away-mode events: only live open items remain, shown without the absence
    # summary header so a re-run never presents the summary again.
    [ -z "$notices" ] || printf 'catch-up open items (still open at return):\n%s' "$notices"
    return $?
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
  printf 'catch-up summary\n  counts: escalation=%d routine=%d daemon-notice=%d\n' "$escalated" "$routine" "$notice" || return 1
  span=''
  if [ -n "$oldest" ] && [ -n "$newest" ]; then
    span=" $(fmt_epoch "$oldest") to $(fmt_epoch "$newest")"
  fi
  printf '  coverage: these counts cover only the retained away-mode window%s, never the whole absence\n' "$span" || return 1
  printf '  ledger: %d rows counted, %d read, %d not read (class counts are for rows read)\n' \
    "$rows_total" "$rows_read" "$((rows_total - rows_read))" || return 1
  printf '  presentation: %d listed, %d duplicate collapses, %d cap omissions, %d blank rows\n' \
    "$listed" "$duplicates" "$capped" "$blank" || return 1
  [ -z "$drops" ] || printf '  dropped before the ledger: %s (repeats naming no new work)\n' "$drops" || return 1
  [ -z "$events" ] || printf '  events in order:\n%s' "$events" || return 1
  locators=$(printf '%s\n' "$urls" | sed '/^$/d' | sort -u | sed 's/^/    /')
  statuses=$(printf '%s\n' "$statuses" | sed '/^$/d' | sort -u | sed 's#^#    state/#')
  absence=$(find "$SQUAD_BASE/data" -maxdepth 1 -name 'absence-*.md' 2>/dev/null | sort | tail -1 || true)
  if [ -n "$locators$statuses$absence" ]; then
    printf '  links and paths:\n' || return 1
    [ -z "$locators" ] || printf '%s\n' "$locators" || return 1
    [ -z "$statuses" ] || printf '%s\n' "$statuses" || return 1
    [ -z "$absence" ] || printf '    %s\n' "$absence" || return 1
  fi
  printf '  never executed while you were away: any merge outside the grant quoted in the absence record, destructive or irreversible actions, security-sensitive choices, and anything outside the accepted scope of the judge; each waits for you.\n' || return 1
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
    "$STATE/.subsuper-inject-wedged" \
    "$STATE"/.subsuper-dropped-* \
    "$STATE"/.sentry-dropped-* &&
    rm -f "$GATE" && rm -f "$RECEIPT" && rm -f "$RECEIPT_ACK"
}

return_guard() {
  if [ -e "$STATE/.afk" ]; then
    printf 'sq-afk-return: away mode is still active; run bin/sq-afk-return.sh before ordinary commander work\n' >&2
    return 3
  fi
  if [ -e "$RECEIPT" ]; then
    printf 'sq-afk-return: return receipt is pending; run bin/sq-afk-return.sh, then acknowledge consumption before ordinary commander work\n' >&2
    return 3
  fi
  if [ -e "$GATE" ]; then
    printf 'sq-afk-return: return catch-up is pending; remediate or durably reclassify every listed blocker, then run bin/sq-afk-return.sh check\n' >&2
    print_blockers "$GATE" >&2
    return 3
  fi
  return 0
}

collect_ledger() {
  local pending drops wedge="$STATE/.subsuper-inject-wedged"
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  if ! {
    awk -F '\t' '$1 != "evidence" || $2 !~ /^(ledger-totals|escalation|wedge|drops)$/' "$GATE" &&
      select_ledger &&
      { [ ! -e "$wedge" ] || append_evidence wedge "$wedge"; } &&
      drops=$(dropped_accounting) &&
      { [ -z "$drops" ] || printf 'evidence\tdrops\t%s\n' "$drops"; }
  } > "$pending" || ! mv "$pending" "$GATE"; then
    rm -f "$pending"
    return 1
  fi
}

return_reconcile() {
  local blockers body id collected=0
  write_pending_seed || return 1
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ]; then
    if ! "$SCRIPT_DIR/sq-afk-launch.sh" stop; then
      printf 'sq-afk-return: away-mode shutdown failed; lifecycle state preserved for retry\n' >&2
      return 3
    fi
  fi

  if ! grep -q $'^evidence\tledger-totals\t.*read=' "$GATE"; then
    fm_lock_acquire_wait "$SQUAD_WAKE_QUEUE_LOCK"
    collect_ledger || collected=$?
    fm_lock_release "$SQUAD_WAKE_QUEUE_LOCK"
    if [ "$collected" -ne 0 ]; then
      printf 'sq-afk-return: could not collect the away-mode ledger; catch-up remains pending\n' >&2
      return 1
    fi
  fi

  if ! "$SCRIPT_DIR/sq-stand-to-drain.sh" --afk-return; then
    printf 'sq-afk-return: durable wake drain failed; retry catch-up before ordinary work\n' >&2
    return 3
  fi
  crash_point drained

  blockers=$(mktemp "$STATE/.afk-return-blockers.XXXXXX") || return 1
  scan_open_blockers > "$blockers" || { rm -f "$blockers"; return 1; }
  if [ -s "$blockers" ]; then
    write_gate "$GATE" "$blockers" || { rm -f "$blockers"; return 1; }
    printf 'sq-afk-return: catch-up must finish before the commander request\n' >&2
    printf 'sq-afk-return: %s away-mode event(s) are held in the catch-up record; one summary is presented once the blockers clear\n' "$(grep -c "^evidence"$'\t'"escalation"$'\t' "$GATE" 2>/dev/null || true)" >&2
    print_blockers "$GATE" >&2
    printf 'sq-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason, then run bin/sq-afk-return.sh check\n' >&2
    rm -f "$blockers"
    return 3
  fi
  rm -f "$blockers"

  body=$(mktemp "$STATE/.afk-return-summary.XXXXXX") || return 1
  print_summary "$GATE" > "$body" || { rm -f "$body"; return 1; }
  if [ -s "$body" ]; then
    id=$(receipt_id "$body")
    if ! receipt_write "$id" "$body"; then
      printf 'sq-afk-return: could not publish receipt at %s; catch-up inputs remain pending\n' "$RECEIPT" >&2
      rm -f "$body"
      return 1
    fi
    rm -f "$body"
    crash_point receipt
    receipt_present "$id"
    return $?
  fi
  rm -f "$body"
  finish_return
}

finish_return() {
  clear_delivery_artifacts || return 1
  printf 'sq-afk-return: catch-up clear; ordinary commander work may proceed\n'
}

return_dispatch() {
  local mode=$1 requested_id=$2 id
  if [ -f "$RECEIPT" ]; then
    id=$(receipt_identity)
    if [ -z "$id" ]; then
      printf 'sq-afk-return: could not read the pending receipt identity\n' >&2
      return 1
    fi
    if [ "$mode" = ack ] && [ "$requested_id" != "$id" ]; then
      printf 'sq-afk-return: acknowledgement must name pending receipt %s\n' "$id" >&2
      return 1
    fi
    if [ "$(receipt_ack_identity)" = "$id" ]; then
      finish_return
    elif [ "$mode" = ack ]; then
      receipt_ack "$id" || return 1
      crash_point acknowledged
      finish_return
    else
      receipt_present "$id"
    fi
  elif [ "$mode" = ack ]; then
    printf 'sq-afk-return: no receipt is pending\n' >&2
    return 1
  else
    return_reconcile
  fi
}

main() {
  local mode=${1:-begin} rc
  case "$mode" in
    begin|check) ;;
    ack) [ "$#" -eq 2 ] || { usage >&2; return 2; } ;;
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

  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$LOCK"
  trap 'fm_lock_release "$LOCK"' EXIT
  return_dispatch "$mode" "${2:-}"
  rc=$?
  fm_lock_release "$LOCK"
  trap - EXIT
  return "$rc"
}

main "$@"
