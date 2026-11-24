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

# Measured counts from that single return. They must keep adding up: the routine
# total is the sum of its distinct bodies, and the duplicate share is what the
# follow-up has to reduce to one entry.
REPEATED=25028
ROUTINE=25087
ESCALATION=1
DISTINCT_OTHER=$((ROUTINE - REPEATED))
[ $((REPEATED + DISTINCT_OTHER)) -eq "$ROUTINE" ] \
  || fail "the pinned counts no longer partition the routine ledger"
duplicate_percent=$((REPEATED * 1000 / ROUTINE))
[ "$duplicate_percent" -ge 995 ] \
  || fail "the pinned duplicate share ($duplicate_percent per mille) no longer describes the incident"
printf 'ok - the incident ledger is %d rows: %d the same closed-window notice (%.1f%%), %d other routine, %d escalation\n' \
  "$((ROUTINE + ESCALATION))" "$REPEATED" "$(awk -v p="$duplicate_percent" 'BEGIN{printf "%.1f", p/10}')" \
  "$DISTINCT_OTHER" "$ESCALATION"

if [ -f "$LOG" ]; then
  from_log=$(grep -m1 'task already finished' "$LOG" 2>/dev/null | sed 's/^ *[0-9]*\. [0-9-]* [0-9:]* \[routine\] //')
  [ "$from_log" = "$notice" ] \
    || fail "the pinned notice differs from the preserved log line: '${from_log}' != '${notice}'"
  pass "the pinned notice is byte-identical to the preserved log line"
else
  printf 'skip: preserved incident log not present at %s\n' "$LOG"
fi

# The fixture matrix record must stay honest about what is not pinned yet.
grep -Fq 'not pinned' "$FIXTURES/README.md" \
  || fail "the fixture record must name the cases that are still unpinned"
pass "the fixture record names the unpinned adversarial cases"
