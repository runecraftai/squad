#!/usr/bin/env bash
# Incident fixture integrity for the away-mode supervision migration.
#
# This test proves the pinned evidence is intact and internally consistent, so a
# later state-owner step can measure a different result against the same input.
# It deliberately does not assert today's duplicate ledger as expected behaviour:
# that would turn the defect into a contract.
#
# When the preserved return log is present on this host, the pinned notice is
# also compared byte for byte with its line in that log. That comparison is
# local evidence, so a host without the log reports it as skipped rather than
# silently passing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIXTURES="$ROOT/tests/fixtures/supervision-out-of-shell"
NOTICE_FILE="$FIXTURES/closed-window-notice.txt"
LOG=${SQUAD_INCIDENT_LOG:-/tmp/pi-bg/34545-bg23.log}

[ -f "$NOTICE_FILE" ] || fail "the pinned closed-window notice is missing"
[ -f "$FIXTURES/README.md" ] || fail "the fixture provenance record is missing"

notice=$(cat "$NOTICE_FILE")
[ -n "$notice" ] || fail "the pinned notice is empty"
[ "$(printf '%s\n' "$notice" | wc -l | tr -d ' ')" = 1 ] \
  || fail "the pinned notice must be exactly one line"
pass "the closed-window notice fixture is present and single-line"

# The daemon's ledger format is "<epoch>|<class>|<one-line description>". The
# pinned file is the description, so the fixture must be usable as that field
# without carrying a delimiter of its own.
case "$notice" in
  *'|'*) fail "the pinned notice contains a ledger field delimiter" ;;
esac
case "$notice" in
  'stale: '*'-> task already finished: done: PR '*) ;;
  *) fail "the pinned notice is not the closed-window shape: $notice" ;;
esac
pass "the pinned notice matches the closed-window ledger shape"

# Parsed evidence. The README is the pinned record for this step, so the counts
# asserted below are read out of it rather than restated as constants here: a
# record that stops adding up, or a notice that stops matching its own row, must
# fail rather than agree with itself.
read -r pinned_routine pinned_escalation <<< "$(awk '
  /^counts: / {
    if (match($0, /routine=[0-9]+/)) routine = substr($0, RSTART + 8, RLENGTH - 8)
    if (match($0, /escalation=[0-9]+/)) escalation = substr($0, RSTART + 11, RLENGTH - 11)
  }
  END { printf "%s %s\n", routine, escalation }
' "$FIXTURES/README.md")"
case "$pinned_routine" in ''|*[!0-9]*) fail "the pinned record no longer states its routine count" ;; esac
case "$pinned_escalation" in ''|*[!0-9]*) fail "the pinned record no longer states its escalation count" ;; esac

routine_rows=$(awk '
  /^\| Occurrences \| Routine body \|/ { in_table = 1; next }
  in_table && /^\|/ {
    line = $0
    gsub(/^\| /, "", line)
    gsub(/ \|$/, "", line)
    n = split(line, parts, /[[:space:]]*\|[[:space:]]*/)
    if (n >= 2 && parts[1] ~ /^[0-9]+$/) printf "%s\t%s\n", parts[1], parts[2]
    next
  }
  in_table && NF > 0 { in_table = 0 }
' "$FIXTURES/README.md")
[ -n "$routine_rows" ] || fail "the pinned record no longer partitions the routine ledger into distinct bodies"

routine_sum=0
repeated=
largest=0
while IFS=$'\t' read -r count body; do
  [ -n "$count" ] || continue
  routine_sum=$((routine_sum + count))
  [ "$count" -gt "$largest" ] && largest=$count
  case "$body" in
    *closed-window*) repeated=$count ;;
  esac
done <<< "$routine_rows"
[ -n "$repeated" ] || fail "no pinned row describes the repeated closed-window notice"
[ "$routine_sum" -eq "$pinned_routine" ] \
  || fail "the pinned bodies sum to $routine_sum, not the recorded routine total $pinned_routine"
[ "$repeated" -eq "$largest" ] \
  || fail "the closed-window notice is no longer the largest pinned routine body"
duplicate_per_mille=$((repeated * 1000 / pinned_routine))
[ "$duplicate_per_mille" -ge 995 ] \
  || fail "the pinned duplicate share ($duplicate_per_mille per mille) no longer describes the incident"
printf 'ok - the incident ledger is %d rows: %d the same closed-window notice (%.1f%%), %d other routine, %d escalation\n' \
  "$((pinned_routine + pinned_escalation))" "$repeated" \
  "$(awk -v p="$duplicate_per_mille" 'BEGIN{printf "%.1f", p/10}')" \
  "$((pinned_routine - repeated))" "$pinned_escalation"

if [ -f "$LOG" ]; then
  from_log=$(grep -m1 'task already finished' "$LOG" 2>/dev/null | sed 's/^ *[0-9]*\. [0-9-]* [0-9:]* \[routine\] //')
  [ "$from_log" = "$notice" ] \
    || fail "the pinned notice differs from the preserved log line: '${from_log}' != '${notice}'"
  pass "the pinned notice is byte-identical to the preserved log line"
  logged_occurrences=$(awk -v notice="$notice" '
    {
      line = $0
      sub(/^ *[0-9]+\. [0-9-]+ [0-9:]+ \[routine\] /, "", line)
      if (line == notice) count++
    }
    END { print count + 0 }
  ' "$LOG")
  [ "$logged_occurrences" -eq "$repeated" ] \
    || fail "the log repeats the notice $logged_occurrences times, not the pinned $repeated"
  pass "the pinned occurrence count matches the preserved log"
else
  printf 'skip: preserved incident log not present at %s\n' "$LOG"
fi

# The fixture matrix is the step's coverage record: every adversarial case must
# carry an owner and a pinned/not-pinned state, every pinned test reference must
# exist, and the record must still be honest about what is not pinned yet.
matrix_rows=$(awk '
  /^\| Case \| Pinned now \| Owner \|/ { in_table = 1; next }
  in_table && /^\|/ {
    line = $0
    gsub(/^\| /, "", line)
    gsub(/ \|$/, "", line)
    n = split(line, parts, /[[:space:]]*\|[[:space:]]*/)
    if (n >= 3 && parts[1] != "" && parts[1] !~ /^-+$/) printf "%s\t%s\t%s\n", parts[1], parts[2], parts[3]
    next
  }
  in_table && NF > 0 { in_table = 0 }
' "$FIXTURES/README.md")
[ -n "$matrix_rows" ] || fail "the fixture record no longer carries a case matrix"

matrix_cases=0
unpinned=0
while IFS=$'\t' read -r case pinned owner; do
  [ -n "$case" ] || continue
  matrix_cases=$((matrix_cases + 1))
  [ -n "$owner" ] || fail "fixture matrix case '$case' has no owner"
  [ -n "$pinned" ] || fail "fixture matrix case '$case' has no pinned state"
  case "$pinned" in
    'not pinned') unpinned=$((unpinned + 1)) ;;
  esac
  for ref in $(printf '%s\n' "$pinned" | grep -oE 'tests/[A-Za-z0-9._/-]+' | sort -u); do
    [ -f "$ROOT/$ref" ] || fail "fixture matrix case '$case' points at missing $ref"
  done
done <<< "$matrix_rows"
[ "$matrix_cases" -ge 5 ] || fail "the fixture matrix shrank to $matrix_cases cases"
[ "$unpinned" -ge 1 ] \
  || fail "the fixture matrix must still name the cases that are not pinned"
pass "the fixture matrix names $matrix_cases owned cases, $unpinned still unpinned"
