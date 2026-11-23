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

merge_evidence() {
  local source
  local -a sources=("$GATE" kind=wake) ledgers=()
  for source in "$STATE"/.afk-return-drain.*/{raw,output}; do
    [ ! -f "$source" ] || sources+=("$source")
  done
  if [ -f "$STATE/.subsuper-inject-wedged" ]; then
    sources+=(kind=wedge "$STATE/.subsuper-inject-wedged")
  fi
  for source in "$STATE"/.subsuper-{routine,escalations}; do
    [ ! -f "$source" ] || ledgers+=("$source")
  done
  (
    set -o pipefail
    if [ -n "${ledgers[0]:-}" ]; then
      sort -s -t'|' -k1,1n "${ledgers[@]}"
    fi | LC_ALL=C awk -F '\t' '
      kind == "" { if ($1 == "evidence" && !seen[$0]++) print; next }
      { gsub(/[\t\r]/, " "); if ($0 == "") next
        row = "evidence\t" kind "\t" $0
        if (!seen[row]++) print row }
    ' "${sources[@]}" kind=escalation -
  )
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
    printf 'schema\tsq-afk-return.v1\nstarted\t%s\nphase\tstopping-and-draining\n' "$started" &&
      { [ ! -f "$GATE" ] || awk -F '\t' '$1 == "evidence"' "$GATE"; }
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

write_gate() {  # <blockers-file> <phase>
  local blockers=$1 phase=$2 pending started
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  {
    printf 'schema\tsq-afk-return.v1\nstarted\t%s\nphase\t%s\n' "$started" "$phase" &&
      merge_evidence && cat "$blockers"
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
summary_evidence() {
  LC_ALL=C awk -F '\t' '
    function identity(text) {
      if (sub(/^check: away-mode ledger could not record: /, "", text) ||
          sub(/^away-mode ledger undeliverable as of [^ ]+: /, "", text)) return "u:" text
      if (text ~ /s past max-defer/ &&
          sub(/^(check: away-mode escalations|away-mode ledger) held /, "", text)) {
        sub(/s past max-defer.*/, "", text)
        return "p:" text
      }
      return "x:" text
    }
    $1 != "evidence" { next }
    $2 == "wake" && $3 ~ /^[0-9]+ [0-9]+ check afk-[A-Za-z0-9._-]+ / {
      item = $3
      sub(/^[^ ]+ [^ ]+ check [^ ]+ /, "", item)
      key = identity(item)
      if (!render) { queued[key] = 1; next }
      if (seen[key]++) next
    }
    render && $2 == "wedge" {
      key = identity($3)
      if (queued[key] || seen[key]++) next
    }
    render { print }
  ' "$1" render=1 "$1"
}

format_summary_times() {
  perl -MPOSIX=strftime -pe '
    s/^([0-9]+)(?=\t)/$1 == 0 ? "0" : (eval { strftime("%m-%d %H:%M", localtime($1)) } || $1)/e;
  '
}

print_summary() {  # <evidence-file>
  local file=$1 tag kind text ts cls item label when re afk_re seq=0 absence locators status_lines
  local escalated=0 routine=0 notice=0 queued=0 suppressed=0
  local notices='' display_rows filtered builtin_time=0
  filtered=$(summary_evidence "$file") || return 1
  local -a rows=() wedges=() events=() urls=() statuses=()
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
        elif [[ $text =~ $re ]]; then
          queued=$((queued + 1))
        else
          case "$text" in 'wake annotation:'*|'') ;; *) notices="${notices}  ${text}"$'\n' ;; esac
        fi
        ;;
      wedge)
        notice=$((notice + 1))
        wedges+=("0"$'\t'"daemon-notice"$'\t'"${text}")
        ;;
    esac
  done <<< "$filtered"
  rows+=( ${wedges[@]+"${wedges[@]}"} )
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
    sorted_rows=$(printf '%s\n' "${rows[@]}" | sort -s -t "$TAB" -k1,1n) || return 1
  fi
  display_rows=$sorted_rows
  if printf -v when '%(%m-%d %H:%M)T' 0 2>/dev/null; then
    builtin_time=1
  elif [ -n "$sorted_rows" ] && command -v perl >/dev/null 2>&1; then
    display_rows=$(format_summary_times <<< "$sorted_rows") || return 1
  fi
  while IFS="$TAB" read -r ts label item; do
    [ -n "$label" ] || continue
    seq=$((seq + 1))
    when=''
    if [ "$ts" != 0 ]; then
      when="$ts "
      if [ "$builtin_time" -eq 1 ]; then
        printf -v when '%(%m-%d %H:%M)T ' "$ts" 2>/dev/null || when="$ts "
      fi
    fi
    events+=("  ${seq}. ${when}[${label}] ${item}")
  done <<< "$display_rows"
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

gate_reason() {  # <phase>
  case "$1" in
    stopping-and-draining)
      printf 'a previous return run stopped before it could finish (interrupted, killed, or still running), so the gate never advanced past the drain' ;;
    shutdown-failed)
      printf 'away-mode shutdown failed; lifecycle state was preserved for retry' ;;
    drain-failed)
      printf 'durable wake drain failed or its queue lock did not become available' ;;
    presenting)
      printf 'catch-up evidence was recorded but presentation or cleanup did not finish' ;;
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
  if [ "$phase" = blocked ]; then
    printf 'sq-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason\n'
  fi
  printf 'sq-afk-return: recovery is bin/sq-afk-return.sh check; no state file needs to be removed by hand\n'
}

return_guard() {
  if [ -e "$GATE" ]; then
    printf 'sq-afk-return: return catch-up is pending\n' >&2
    report_gate_phase >&2
    print_blockers "$GATE" >&2
    return 3
  fi
  if [ -e "$STATE/.afk" ]; then
    printf 'sq-afk-return: away mode is still active; run bin/sq-afk-return.sh before ordinary commander work\n' >&2
    return 3
  fi
  return 0
}

return_reconcile() {
  local blockers=$1 deadline=$2 phase='' spool remaining
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ]; then
    "$SCRIPT_DIR/sq-afk-launch.sh" stop || phase=shutdown-failed
  fi
  if [ -z "$phase" ]; then
    spool=$(mktemp -d "$STATE/.afk-return-drain.XXXXXX") || return 1
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -ge 0 ] || remaining=0
    SQUAD_WAKE_DRAIN_LOCK_SECS=$remaining SQUAD_WAKE_DRAIN_CHECKPOINT="$spool/raw" \
      "$SCRIPT_DIR/sq-stand-to-drain.sh" > "$spool/output" || phase=drain-failed
  fi

  scan_open_blockers > "$blockers" || return 1
  if [ -z "$phase" ] && [ -s "$blockers" ]; then
    phase=blocked
  fi
  write_gate "$blockers" "${phase:-presenting}" || return 1
  rm -rf -- "$STATE"/.afk-return-drain.*/ || return 1
  if [ -n "$phase" ]; then
    printf 'sq-afk-return: catch-up must finish before the commander request\n' >&2
    printf 'sq-afk-return: %s away-mode event(s) are held in the catch-up record; one summary is presented once the blockers clear\n' "$(grep -c "^evidence"$'\t'"escalation"$'\t' "$GATE" 2>/dev/null || true)" >&2
    report_gate_phase >&2
    print_blockers "$GATE" >&2
    return 3
  fi

  print_summary "$GATE" || return 1
  clear_delivery_artifacts && rm -f "$GATE" || return 1
  printf 'sq-afk-return: catch-up clear; ordinary commander work may proceed\n'
  return 0
}

main() {
  local mode=${1:-begin} rc resumed deadline scratch
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
  deadline=$(( $(date +%s) + LOCK_WAIT_SECS ))
  if ! fm_lock_acquire_wait_bounded "$LOCK" "$LOCK_WAIT_SECS"; then
    printf 'sq-afk-return: catch-up did not start: the return catch-up lock is still held after %ss\n' "$LOCK_WAIT_SECS" >&2
    report_gate_phase >&2
    printf 'sq-afk-return: retry bin/sq-afk-return.sh check once the run holding it has exited\n' >&2
    return 3
  fi
  trap 'fm_lock_release "$LOCK"' EXIT
  resumed=$(gate_field phase)
  if [ -n "$resumed" ] && [ "$resumed" != blocked ]; then
    printf 'sq-afk-return: resuming a catch-up found in phase %s: %s\n' "$resumed" "$(gate_reason "$resumed")" >&2
  fi
  write_pending_seed || return 1
  scratch=$(mktemp -d "$STATE/.afk-return-work.XXXXXX") || return 1
  return_reconcile "$scratch/blockers" "$deadline"
  rc=$?
  rm -rf -- "$scratch"
  if [ "$rc" -eq 1 ]; then
    printf 'sq-afk-return: catch-up did not commit; retry bin/sq-afk-return.sh check\n' >&2
  fi
  return "$rc"
}

main "$@"
