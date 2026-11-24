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
#
# Durable receipt (`state/.afk-receipt` + `state/.afk-receipt.ack`): the rendered
# summary is landed in an outbox record carrying one identity BEFORE the ledger it
# was built from is cleared, and that identity is acknowledged once the bytes have
# been presented. A crash between building and presenting therefore replays the
# stored bytes under the same identity instead of losing the summary, and a crash
# after presenting replays the identical body (same content, same identity) instead
# of a second record.
#
# Bounded presentation: the away-mode ledger is counted in one streaming awk pass
# and only the first SQUAD_AFK_SUMMARY_MAX_EVENTS_DEFAULT entries per class reach the
# shell's per-row work, so a pathological ledger terminates quickly instead of
# walking tens of thousands of rows. The summary always states the retained window
# it counted and how many entries it counted but did not list.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
GATE="$STATE/.afk-return-catchup"
LOCK="$STATE/.afk-return-catchup.lock"
RECEIPT="$STATE/.afk-receipt"
RECEIPT_ACK="$STATE/.afk-receipt.ack"
# Hard bound on ledger entries presented per class; see the header.
SUMMARY_MAX_EVENTS_DEFAULT=${SQUAD_AFK_SUMMARY_MAX_EVENTS_DEFAULT:-200}

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

append_evidence() {  # <kind> <text> <file>
  local kind=$1 text=$2 file=$3 line clean record
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    clean=$(printf '%s' "$line" | clean_field) || return 1
    record=$(printf 'evidence\t%s\t%s' "$kind" "$clean") || return 1
    grep -Fqx "$record" "$file" 2>/dev/null || printf '%s\n' "$record" >> "$file" || return 1
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

# Test seam only: a named point after which the return path stops without
# acknowledging, so the crash-and-replay regression can prove the receipt both
# survives and stays single. Unset in production, where it costs one comparison.
crash_point() {  # <point>
  [ "${SQUAD_AFK_RETURN_CRASH:-}" = "$1" ] || return 0
  printf 'sq-afk-return: simulated crash at %s\n' "$1" >&2
  exit 9
}

# select_ledger <out-file>
# One streaming pass over the retained away-mode ledger: counts every row, and
# copies at most SUMMARY_MAX_EVENTS_DEFAULT rows per class into <out-file>. Prints
# the totals line the summary reports:
# "rows=<n> escalation=<n> routine=<n> listed=<n> oldest=<epoch> newest=<epoch>".
select_ledger() {  # <out-file>
  local out=$1 files=()
  [ -s "$STATE/.subsuper-routine" ] && files+=("$STATE/.subsuper-routine")
  [ -s "$STATE/.subsuper-escalations" ] && files+=("$STATE/.subsuper-escalations")
  if [ "${#files[@]}" -eq 0 ]; then
    printf 'rows=0 escalation=0 routine=0 listed=0 oldest= newest=\n'
    return 0
  fi
  awk -F'|' -v max="$SUMMARY_MAX_EVENTS_DEFAULT" -v out="$out" '
    $0 == "" { next }
    {
      rows++
      ts = ""; cls = "escalation"
      if (NF >= 3 && $1 ~ /^[0-9]+$/) { ts = $1; cls = $2 }
      if (cls == "routine") routine++
      else { cls = "escalation"; escalation++ }
      if (ts != "") {
        if (oldest == "" || ts + 0 < oldest + 0) oldest = ts
        if (newest == "" || ts + 0 > newest + 0) newest = ts
      }
      if (cls == "routine") { if (kept_routine < max) { print > out; kept_routine++; listed++ } }
      else if (kept_escalation < max) { print > out; kept_escalation++; listed++ }
    }
    END {
      if (listed && close(out) != 0) exit 1
      printf "rows=%d escalation=%d routine=%d listed=%d oldest=%s newest=%s\n", \
        rows, escalation, routine, listed, oldest, newest
    }
  ' "${files[@]}"
}

# dropped_accounting: entries the daemon discarded at origin, as "class=count"
# pairs. A repeated notification about a window whose task already finished names
# no new work, so it is counted there and never written to the ledger; reporting
# the count keeps that decision visible instead of silently shrinking the window.
dropped_accounting() {
  local f cls n out=''
  for f in "$STATE"/.subsuper-dropped-*; do
    [ -f "$f" ] || continue
    cls=${f##*.subsuper-dropped-}
    n=$(cat "$f" 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt 0 ] || continue
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

# receipt_pending: a built receipt exists whose identity is not acknowledged yet.
receipt_pending() {
  local id
  [ -s "$RECEIPT" ] || return 1
  id=$(receipt_identity)
  [ -n "$id" ] || return 1
  [ "$(receipt_ack_identity)" = "$id" ] && return 1
  return 0
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
  printf '%s-%s' "$base" "${hash:-nohash}"
}

receipt_write() {  # <identity> <body-file>; lands the outbox record atomically
  local id=$1 body=$2 pending
  pending=$(mktemp "$STATE/.afk-receipt.pending.XXXXXX") || return 1
  {
    printf 'schema\tsq-afk-receipt.v1\n'
    printf 'id\t%s\n' "$id"
    printf 'created\t%s\n' "$(date +%s)"
    printf 'body\n'
    cat "$body"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$RECEIPT"
}

receipt_body() {
  awk 'seen { print } /^body$/ { seen = 1 }' "$RECEIPT" 2>/dev/null
}

receipt_present() {  # <identity>; prints the stored bytes, then acknowledges them
  local id=$1 pending
  receipt_body
  pending=$(mktemp "$STATE/.afk-receipt-ack.pending.XXXXXX") || return 1
  {
    printf 'schema\tsq-afk-receipt.v1\n'
    printf 'ack\t%s\n' "$id"
    printf 'acknowledged\t%s\n' "$(date +%s)"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$RECEIPT_ACK"
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
  local rows_total=0 listed=0 oldest='' newest='' skipped span drops max
  re='^[0-9]+ [0-9]+ (signal|stale|check|heartbeat) '
  afk_re='^([0-9]+) [0-9]+ check afk-[A-Za-z0-9._-]+ (.*)$'
  max=$SUMMARY_MAX_EVENTS_DEFAULT
  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] || continue
    case "$kind" in
      ledger-totals)
        # Totals of the retained ledger, counted in one streaming pass when the
        # ledger was merged in. They describe the whole retained window, so the
        # counts stay honest even when the presentation itself is bounded.
        for item in $text; do
          case "$item" in
            rows=*) rows_total=${item#rows=} ;;
            escalation=*) escalated=${item#escalation=} ;;
            routine=*) routine=${item#routine=} ;;
            listed=*) listed=${item#listed=} ;;
            oldest=*) oldest=${item#oldest=} ;;
            newest=*) newest=${item#newest=} ;;
          esac
        done
        ;;
      escalation)
        ts='' cls='' item=$text
        if [[ $text == *'|'* ]]; then
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
  drops=$(dropped_accounting)
  if [ $((escalated + routine + notice)) -eq 0 ] && [ -z "$drops" ]; then
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
  span=''
  if [ -n "$oldest" ] && [ -n "$newest" ]; then
    span=" $(fmt_epoch "$oldest") to $(fmt_epoch "$newest")"
  fi
  printf '  coverage: these counts cover only the retained away-mode window%s, never the whole absence\n' "$span"
  skipped=$(( rows_total - listed ))
  if [ "$skipped" -gt 0 ]; then
    printf '  presentation bound: %d of %d retained ledger entries listed, %d counted but not listed (limit %d per class)\n' \
      "$listed" "$rows_total" "$skipped" "$max"
  fi
  drops=$(dropped_accounting)
  [ -z "$drops" ] || printf '  dropped before the ledger: %s (repeats naming no new work)\n' "$drops"
  [ -z "$events" ] || printf '  events in order:\n%s' "$events"
  locators=$(printf '%s\n' "$urls" | sed '/^$/d' | sort -u | sed 's/^/    /')
  statuses=$(printf '%s\n' "$statuses" | sed '/^$/d' | sort -u | sed 's#^#    state/#')
  absence=$(find "$SQUAD_BASE/data" -maxdepth 1 -name 'absence-*.md' 2>/dev/null | sort | tail -1 || true)
  if [ -n "$locators$statuses$absence" ]; then
    printf '  links and paths:\n'
    [ -z "$locators" ] || printf '%s\n' "$locators"
    [ -z "$statuses" ] || printf '%s\n' "$statuses"
    [ -z "$absence" ] || printf '    %s\n' "$absence"
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
    "$STATE/.subsuper-inject-wedged" \
    "$STATE"/.subsuper-dropped-* \
    "$RECEIPT" "$RECEIPT_ACK"
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
  if receipt_pending; then
    printf 'sq-afk-return: a return summary is built and not yet presented; run bin/sq-afk-return.sh to present it before ordinary commander work\n' >&2
    return 3
  fi
  return 0
}

return_reconcile() {
  local evidence blockers drained wedge ledger_sample ledger_rows ledger_totals lifecycle_ok=1
  local body id ack_id replayed=0
  evidence=$(mktemp "$STATE/.afk-return-evidence.XXXXXX") || return 1
  blockers=$(mktemp "$STATE/.afk-return-blockers.XXXXXX") || { rm -f "$evidence"; return 1; }
  # A receipt left unacknowledged by a crash is presented here, under its own
  # stored identity, before any new evidence exists: the commander sees the same
  # receipt once instead of losing it or accumulating a second one.
  if receipt_pending; then
    receipt_present "$(receipt_identity)"
    crash_point presented
    replayed=1
  fi
  ack_id=$(receipt_ack_identity)
  preserve_evidence "$evidence"

  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ]; then
    if ! "$SCRIPT_DIR/sq-afk-launch.sh" stop; then
      lifecycle_ok=0
      append_evidence lifecycle 'away-mode shutdown failed; lifecycle state preserved for retry' "$evidence"
    fi
  fi

  if [ -s "$STATE/.subsuper-routine" ] || [ -s "$STATE/.subsuper-escalations" ]; then
    if ! ledger_sample=$(mktemp "$STATE/.afk-return-ledger.XXXXXX") ||
       ! ledger_totals=$(select_ledger "$ledger_sample") ||
       ! ledger_rows=$(cat "$ledger_sample") ||
       ! append_evidence ledger-totals "$ledger_totals" "$evidence" ||
       ! append_evidence escalation "$ledger_rows" "$evidence"; then
      printf 'sq-afk-return: could not collect the away-mode ledger; catch-up remains pending\n' >&2
      rm -f "$ledger_sample" "$evidence" "$blockers"
      return 1
    fi
    rm -f "$ledger_sample"
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

  if [ "$replayed" -eq 0 ]; then
    body=$(mktemp "$STATE/.afk-return-summary.XXXXXX") || { rm -f "$evidence" "$blockers"; return 1; }
    print_summary "$evidence" > "$body"
    if [ -s "$body" ]; then
      id=$(receipt_id "$body")
      if [ "$id" = "$ack_id" ]; then
        # This exact receipt was already presented and acknowledged before a crash;
        # presenting it again is the duplicate the outbox exists to prevent.
        printf 'sq-afk-return: the return summary was already presented as %s\n' "$id" >&2
      elif receipt_write "$id" "$body"; then
        crash_point receipt
        receipt_present "$id"
        crash_point presented
      else
        # The outbox could not be landed, so nothing may be cleared: present the
        # summary now and keep the ledger for the next run instead of losing it.
        cat "$body"
        printf 'sq-afk-return: the durable return receipt could not be written; the away-mode ledger is kept for the next run\n' >&2
        rm -f "$body" "$evidence" "$blockers"
        return 1
      fi
    fi
    rm -f "$body"
  fi
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
