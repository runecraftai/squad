#!/usr/bin/env bash
# sq-afk-return.sh - deterministic away-mode return catch-up gate.
#
# Usage:
#   sq-afk-return.sh          Stop away mode, drain catch-up, and open/check gate.
#   sq-afk-return.sh begin    Same as the default command.
#   sq-afk-return.sh check    Re-drain and close the gate only after blockers resolve.
#   sq-afk-return.sh guard    Read-only refusal while away or catch-up is pending.
#
# A gate that could not finish is resumed with `check`. `check` and `guard` both
# name the phase the gate was found in and why it could not advance.
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
# Gate phases and supported recovery. The gate names the phase it is in, and each
# phase has exactly one supported recovery, so no state file is ever removed by
# hand:
#   stopping-and-draining  MUTATING seed written before any lifecycle change. A
#                          gate still in this phase means the run that wrote it
#                          never reached the end of the reconcile - it was
#                          interrupted, killed, or is still running. Recovery is
#                          `check`, which resumes the drain and reports the phase it
#                          found and why it could not advance.
#   blocked                The reconcile finished with Squad-actionable blockers.
#                          Recovery is to remediate or durably reclassify each
#                          listed blocker and run `check`.
# `guard` reports the same phase and reason read-only. A run that cannot even
# acquire the catch-up lock reports that instead of spinning.
#
# Bounds. The return path must always terminate for the commander, so every step
# is bounded: the catch-up lock wait is bounded by SQUAD_AFK_RETURN_LOCK_SECS
# (default 30), the evidence merge and the summary each make one linear pass over
# the evidence file instead of one filesystem scan per line, and the routine class
# - the one a repeating wake can inflate - is presented at most
# SQUAD_AFK_RETURN_MAX_ROUTINE_EVENTS (default 200) times, with the remainder
# reported as a count. Escalation and daemon-notice events are never truncated.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
GATE="$STATE/.afk-return-catchup"
LOCK="$STATE/.afk-return-catchup.lock"
decimal_setting() {
  local value=$1 fallback=$2
  case "$value" in ''|*[!0123456789]*) printf '%s\n' "$fallback"; return ;; esac
  value=${value#"${value%%[!0]*}"}
  if [ "${#value}" -le 9 ]; then
    printf '%s\n' "${value:-0}"
  else
    printf '%s\n' "$fallback"
  fi
}

MAX_ROUTINE_EVENTS=$(decimal_setting "${SQUAD_AFK_RETURN_MAX_ROUTINE_EVENTS:-}" 200)
LOCK_WAIT_SECS=$(decimal_setting "${SQUAD_AFK_RETURN_LOCK_SECS:-}" 30)
# The field separator, resolved once: a `while IFS="$(printf '\t')" read` re-runs
# its command substitution on every iteration, which is a process per line.
TAB=$(printf '\t')

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

# evidence_records: render <text>'s lines as evidence records on stdout. One awk
# pass for the whole text: the previous per-line `printf | tr` forked a subshell
# and a process for every candidate record, which dominates the cost on a large
# ledger.
evidence_records() {  # <kind> <text>
  local kind=$1 text=$2
  [ -n "$text" ] || return 0
  printf '%s\n' "$text" | LC_ALL=C awk -v kind="$kind" '
    { gsub(/[\t\r\n]/, " "); if ($0 == "") next; printf "evidence\t%s\t%s\n", kind, $0 }'
}

# evidence_dedup: keep the first occurrence of each distinct record, preserving
# order, in one linear pass. The earlier per-line `grep -Fqx` rescanned the whole
# growing file for every candidate record, which is quadratic in an unbounded
# ledger and was the shape that made a return run outlive the commander's
# patience. A non-regular destination (write_pending_seed streams to /dev/stdout)
# is left alone.
evidence_dedup() {  # <file>
  local file=$1 pending
  [ -f "$file" ] || return 0
  [ -s "$file" ] || return 0
  pending=$(mktemp "$STATE/.afk-evidence.XXXXXX") || return 1
  if ! awk '!seen[$0]++' "$file" > "$pending"; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$file"
}

append_evidence() {  # <kind> <text> <file>
  local kind=$1 text=$2 file=$3
  [ -n "$text" ] || return 0
  evidence_records "$kind" "$text" >> "$file" || return 1
  evidence_dedup "$file"
}

preserve_evidence() {  # <destination>
  local destination=$1
  [ -f "$GATE" ] || return 0
  grep '^evidence'"$TAB" "$GATE" >> "$destination" 2>/dev/null || true
}

scan_open_blockers() {  # -> tab-separated blocker rows
  local meta id status key verb summary clean_summary
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    status="$STATE/$id.status"
    [ -f "$status" ] || continue
    while IFS="$TAB" read -r key verb summary; do
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

fmt_epoch() {  # <epoch> -> local "MM-DD HH:MM" (bash builtin, then GNU date, then BSD date)
  local ts=$1 out=''
  # The builtin keeps a long summary fork-free; the date fallbacks cover a shell
  # without printf %()T.
  printf -v out '%(%m-%d %H:%M)T' "$ts" 2>/dev/null && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  date -d "@$ts" '+%m-%d %H:%M' 2>/dev/null || date -r "$ts" '+%m-%d %H:%M' 2>/dev/null || printf '%s' "$ts"
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
  local file=$1 tag kind text ts cls item label when re afk_re seq=0 absence locators status_lines
  local escalated=0 routine=0 notice=0 queued=0 suppressed=0
  local afk_keys='' wedges='' notices=''
  local -a rows=() events=() urls=() statuses=()
  re='^[0-9]+ [0-9]+ (signal|stale|check|heartbeat) '
  afk_re='^([0-9]+) [0-9]+ check afk-[A-Za-z0-9._-]+ (.*)$'
  # One linear pass. Rows are collected in arrays, never by re-concatenating a
  # growing string per event, because that copy-per-event shape is quadratic in
  # the evidence file and is what made a large ledger take minutes.
  while IFS="$TAB" read -r tag kind text; do
    [ "$tag" = evidence ] || continue
    case "$kind" in
      escalation)
        ts='' cls='' item=$text
        if [[ $text == *'|'* ]]; then
          IFS='|' read -r ts cls item <<< "$text"
        fi
        case "$ts" in ''|*[!0-9]*) ts='' cls=escalation item=$text ;; esac
        if [ "$cls" = routine ]; then
          routine=$((routine + 1))
          if [ "$routine" -le "$MAX_ROUTINE_EVENTS" ]; then
            rows+=("${ts:-0}"$'\t'"routine"$'\t'"${item}")
          fi
        else
          escalated=$((escalated + 1))
          rows+=("${ts:-0}"$'\t'"escalation"$'\t'"${item}")
        fi
        ;;
      wake)
        if [[ $text =~ $afk_re ]]; then
          notice=$((notice + 1))
          rows+=("${BASH_REMATCH[1]}"$'\t'"daemon-notice"$'\t'"${BASH_REMATCH[2]}")
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
      rows+=("0"$'\t'"daemon-notice"$'\t'"${item}")
    done <<< "$wedges"
  fi
  # Bound the one class a repeating wake can inflate. Each distinct routine event
  # still occupies the ledger and is still counted below, but presentation stops
  # at the documented limit so a pathological ledger cannot stall the return.
  # Escalations and daemon notices are never truncated: they are the contract.
  if [ "$routine" -gt "$MAX_ROUTINE_EVENTS" ]; then
    suppressed=$(( routine - MAX_ROUTINE_EVENTS ))
  fi
  [ "$queued" -eq 0 ] || notices="  queued wake records drained: ${queued}"$'\n'"${notices}"
  if [ $((escalated + routine + notice)) -eq 0 ]; then
    # No away-mode events: only live open items remain, shown without the absence
    # summary header so a re-run never presents the summary again.
    [ -z "$notices" ] || printf 'catch-up open items (still open at return):\n%s' "$notices"
    return 0
  fi
  local sorted_rows=''
  if [ -n "${rows[0]:-}" ]; then
    sorted_rows=$(printf '%s\n' "${rows[@]}" | sort -s -t "$TAB" -k1,1n)
  fi
  while IFS="$TAB" read -r ts label item; do
    [ -n "$label" ] || continue
    seq=$((seq + 1))
    when=''
    if [ "$ts" != 0 ]; then
      # Builtin first so a long summary never forks once per row.
      printf -v when '%(%m-%d %H:%M)T ' "$ts" 2>/dev/null || when=''
      [ -n "$when" ] || when="$(fmt_epoch "$ts") "
    fi
    events+=("  ${seq}. ${when}[${label}] ${item}")
  done <<< "$sorted_rows"
  # One scan for every link and status path the summary lists, rather than a pair
  # of greps per event row.
  if [ -n "$sorted_rows" ]; then
    while IFS= read -r locator; do
      [ -n "$locator" ] && urls+=("$locator")
    done <<< "$(printf '%s\n' "$sorted_rows" | grep -Eo 'https://[^[:space:]]+' || true)"
    while IFS= read -r status_ref; do
      [ -n "$status_ref" ] && statuses+=("$status_ref")
    done <<< "$(printf '%s\n' "$sorted_rows" | grep -Eo '[A-Za-z0-9._-]+\.status' || true)"
  fi
  printf 'catch-up summary (one presentation for this absence)\n'
  printf '  counts: escalation=%d routine=%d daemon-notice=%d\n' "$escalated" "$routine" "$notice"
  if [ "$suppressed" -gt 0 ]; then
    printf '  routine entries past the first %d are counted but not listed; lower or raise the limit with SQUAD_AFK_RETURN_MAX_ROUTINE_EVENTS\n' "$MAX_ROUTINE_EVENTS"
  fi
  [ -z "${events[0]:-}" ] || printf '  events in order:\n%s\n' "$(printf '%s\n' "${events[@]}")"
  locators=''
  if [ -n "${urls[0]:-}" ]; then
    locators=$(printf '%s\n' "${urls[@]}" | sed '/^$/d' | sort -u | sed 's/^/    /')
  fi
  status_lines=''
  if [ -n "${statuses[0]:-}" ]; then
    status_lines=$(printf '%s\n' "${statuses[@]}" | sed '/^$/d' | sort -u | sed 's#^#    state/#')
  fi
  absence=$(find "$SQUAD_BASE/data" -maxdepth 1 -name 'absence-*.md' 2>/dev/null | sort | tail -1 || true)
  if [ -n "$locators$status_lines$absence" ]; then
    printf '  links and paths:\n'
    [ -z "$locators" ] || printf '%s\n' "$locators"
    [ -z "$status_lines" ] || printf '%s\n' "$status_lines"
    [ -z "$absence" ] || printf '    %s\n' "$absence"
  fi
  printf '  never executed while you were away: any merge outside the grant quoted in the absence record, destructive or irreversible actions, security-sensitive choices, and anything outside the accepted scope of the judge; each waits for you.\n'
  [ -z "$notices" ] || printf '  open items at return:\n%s' "$notices"
}

print_blockers() {  # <file>
  local file=$1 tag id key summary
  while IFS="$TAB" read -r tag id key summary; do
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

gate_field() {  # <key> -> value of a keyed gate line, or nothing
  [ -f "$GATE" ] || return 0
  awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$GATE" 2>/dev/null || true
}

gate_evidence_count() {  # -> number of evidence records the gate holds
  [ -f "$GATE" ] || { printf '0'; return 0; }
  awk -F '\t' '$1 == "evidence" { n++ } END { print n + 0 }' "$GATE" 2>/dev/null || printf '0'
}

# The reason a gate could not advance, derived from the phase it is stuck in.
# Only the two phases this script writes are known: stopping-and-draining is the
# fail-closed seed written before any lifecycle mutation, and blocked is written
# once the reconcile finished with blockers. A gate still in the seed phase means
# the run that wrote it never reached the end of the reconcile, so the gate names
# that instead of guessing at a blocker.
gate_reason() {  # <phase>
  case "$1" in
    stopping-and-draining)
      printf 'a previous return run stopped before it could finish (interrupted, killed, or still running), so the gate never advanced past the drain' ;;
    blocked)
      printf 'the catch-up finished with Squad-actionable blockers that are still open' ;;
    *) printf 'the gate holds a phase this script does not recognise' ;;
  esac
}

# report_gate_phase: the read-only diagnosis, on stderr, of a gate that is in the
# way. Names the phase, why it could not advance, what it holds, and the one
# supported recovery. Returns 1 when there is no gate to describe.
report_gate_phase() {
  local phase started count age
  [ -f "$GATE" ] || return 1
  phase=$(gate_field phase)
  [ -n "$phase" ] || phase=unknown
  started=$(gate_field started)
  count=$(gate_evidence_count)
  printf 'sq-afk-return: return catch-up gate phase: %s\n' "$phase"
  printf 'sq-afk-return: why it could not advance: %s\n' "$(gate_reason "$phase")"
  case "$started" in
    ''|*[!0-9]*) ;;
    *)
      age=$(( $(date +%s) - started ))
      [ "$age" -ge 0 ] || age=0
      printf 'sq-afk-return: gate opened %s (%ss ago) holding %s evidence record(s)\n' \
        "$(fmt_epoch "$started")" "$age" "$count" ;;
  esac
  printf 'sq-afk-return: recovery is bin/sq-afk-return.sh check; no state file needs to be removed by hand\n'
}

return_guard() {
  if [ -e "$STATE/.afk" ]; then
    printf 'sq-afk-return: away mode is still active; run bin/sq-afk-return.sh before ordinary commander work\n' >&2
    return 3
  fi
  if [ -e "$GATE" ]; then
    printf 'sq-afk-return: return catch-up is pending; remediate or durably reclassify every listed blocker, then run bin/sq-afk-return.sh check\n' >&2
    report_gate_phase >&2
    print_blockers "$GATE" >&2
    return 3
  fi
  return 0
}

return_reconcile() {
  local evidence blockers drained wedge escalations lifecycle_ok=1 resumed
  evidence=$(mktemp "$STATE/.afk-return-evidence.XXXXXX") || return 1
  blockers=$(mktemp "$STATE/.afk-return-blockers.XXXXXX") || { rm -f "$evidence"; return 1; }
  # Resuming a seed-phase gate is normal recovery, not a failure: say out loud
  # which phase was found and why it was still there, so a commander sees the
  # reason their return had not completed instead of an unexplained refusal.
  resumed=$(gate_field phase)
  if [ "$resumed" = stopping-and-draining ]; then
    printf 'sq-afk-return: resuming a catch-up found in phase stopping-and-draining: %s\n' \
      "$(gate_reason stopping-and-draining)" >&2
  fi
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

  evidence_dedup "$evidence"
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

  mkdir -p "$STATE" || return 1
  # A bounded wait, not an unbounded spin: a lock left behind by a killed run must
  # report itself to the commander instead of hanging the return.
  if ! fm_lock_acquire_wait_bounded "$LOCK" "$LOCK_WAIT_SECS"; then
    printf 'sq-afk-return: catch-up did not start: the return catch-up lock is still held after %ss\n' "$LOCK_WAIT_SECS" >&2
    report_gate_phase >&2
    printf 'sq-afk-return: retry bin/sq-afk-return.sh check once the run holding it has exited\n' >&2
    return 3
  fi
  trap 'fm_lock_release "$LOCK"' EXIT
  write_pending_seed || { fm_lock_release "$LOCK"; trap - EXIT; return 1; }
  return_reconcile
  rc=$?
  fm_lock_release "$LOCK"
  trap - EXIT
  return "$rc"
}

main "$@"
