#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"
export SQUAD_STATE_OVERRIDE="$STATE"
export SQUAD_BASE="$TMP"
EXEC="$ROOT/bin/sq-exec-state.sh"
STALL="$ROOT/bin/sq-stall-detect.sh"

assert_eq() { [ "$1" = "$2" ] || { printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }; }
assert_contains() { printf '%s\n' "$1" | grep -F "$2" >/dev/null || { printf 'missing <%s>\n' "$2" >&2; exit 1; }; }

# The retry schedule is exponential and capped.
# shellcheck source=../bin/sq-stall-detect.sh disable=SC1090,SC1091
. "$STALL"
assert_eq "$(stall_backoff_seconds 0)" 10
assert_eq "$(stall_backoff_seconds 1)" 20
assert_eq "$(stall_backoff_seconds 2)" 40
assert_eq "$(stall_backoff_seconds 8)" 300

# A conclusive dead endpoint is interrupted and queued without touching the workspace.
"$EXEC" claim stalled >/dev/null
"$EXEC" running stalled >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/stalled.exec"
printf 'worktree=/preserve/me\n' >"$STATE/stalled.meta"
printf 'exec_backend=tmux\n' >>"$STATE/stalled.exec"
printf 'exec_max_retries=3\n' >>"$STATE/stalled.exec"
cat >"$TMP/interrupt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$TMP/interrupt.log"
EOF
# The fixture command expands TMP through the exported shell environment.
export TMP
chmod +x "$TMP/interrupt"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get stalled)" retry_queued
[ -d /preserve/me ] || : # only the recorded path must remain in the sidecar
assert_contains "$(cat "$STATE/stalled.exec")" 'exec_next_retry_at='
[ "$(cat "$TMP/interrupt.log")" = stalled ]

# Active phase is positive evidence and is not interrupted.
"$EXEC" claim working >/dev/null
"$EXEC" running working >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/working.exec"
printf 'exec_phase=working\n' >>"$STATE/working.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=alive SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get working)" running

# A deliberate pause outranks a stale running sidecar. The detector must not
# append `working:` or interrupt the worker after the pause event.
"$EXEC" claim paused >/dev/null
"$EXEC" running paused >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/paused.exec"
printf 'paused: waiting for upstream\n' >"$STATE/paused.status"
cat >"$TMP/no-interrupt" <<'EOF'
#!/usr/bin/env bash
printf interrupted >"$TMP/paused-interrupted"
EOF
chmod +x "$TMP/no-interrupt"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/no-interrupt" "$STALL"
assert_eq "$($EXEC get paused)" running
assert_eq "$(cat "$STATE/paused.status")" 'paused: waiting for upstream'
[ ! -e "$TMP/paused-interrupted" ] || { printf 'paused worker was interrupted\n' >&2; exit 1; }

# Exhausted retries are queued for retry_run_claim to release. The stall
# detect always transitions to retry_queued to keep the attempt supervised.
"$EXEC" claim exhausted >/dev/null
"$EXEC" running exhausted >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/exhausted.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=3/' "$STATE/exhausted.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get exhausted)" retry_queued
assert_contains "$(cat "$STATE/exhausted.exec")" 'exec_error=stall_timeout'

# Ambiguous evidence is surfaced for technical recovery and not killed.
"$EXEC" claim ambiguous >/dev/null
"$EXEC" running ambiguous >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/ambiguous.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=ambiguous SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get ambiguous)" running
assert_contains "$(cat "$STATE/ambiguous.status")" 'stuck-operator-recovery'

# --- Open-decision tests: an open needs-decision or blocked must not be interrupted ---
# Clean up stale exec files from earlier tests to avoid cross-contamination
# when the stall detector processes all .exec files in a single run.
rm -f "$STATE"/*.exec "$STATE"/*.meta "$STATE"/*.status
cat >"$TMP/decision-interrupt" <<'EOF'
#!/usr/bin/env bash
printf interrupted >"$TMP/decision-interrupted"
EOF
chmod +x "$TMP/decision-interrupt"

# An open needs-decision means the operator is legitimately stopped. The detector
# must not interrupt it for inactivity.
"$EXEC" claim open-decision >/dev/null
"$EXEC" running open-decision >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/open-decision.exec"
printf 'needs-decision [key=test-choice]: what to do\n' >"$STATE/open-decision.status"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/decision-interrupt" "$STALL"
assert_eq "$("$EXEC" get open-decision)" running
assert_contains "$(cat "$STATE/open-decision.status")" 'needs-decision'
[ ! -e "$TMP/decision-interrupted" ] || { printf 'open-decision worker was interrupted\n' >&2; exit 1; }

# An open blocked: means the operator is waiting for Squad help. The detector
# must not interrupt it for inactivity.
rm -f "$STATE"/*.exec "$STATE"/*.status
"$EXEC" claim open-blocked >/dev/null
"$EXEC" running open-blocked >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/open-blocked.exec"
printf 'blocked: waiting for credential\n' >"$STATE/open-blocked.status"
rm -f "$TMP/decision-interrupted"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/decision-interrupt" "$STALL"
assert_eq "$("$EXEC" get open-blocked)" running
assert_contains "$(cat "$STATE/open-blocked.status")" 'blocked:'
[ ! -e "$TMP/decision-interrupted" ] || { printf 'open-blocked worker was interrupted\n' >&2; exit 1; }

# A resolved decision means the operator is no longer waiting. A subsequent stall
# IS interrupted - the resolution clears the gate.
rm -f "$STATE"/*.exec "$STATE"/*.status
"$EXEC" claim resolved-decision >/dev/null
"$EXEC" running resolved-decision >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/resolved-decision.exec"
printf 'needs-decision [key=old-choice]: what to do\n' >"$STATE/resolved-decision.status"
printf 'resolved [key=old-choice]: commander decided\n' >>"$STATE/resolved-decision.status"
rm -f "$TMP/decision-interrupted"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/decision-interrupt" "$STALL"
assert_eq "$("$EXEC" get resolved-decision)" retry_queued
assert_contains "$(cat "$STATE/resolved-decision.status")" 'stall interrupted'

# --- retry_queued supervision tests ---

# If completion lands after the retry scan but before claim/running finishes,
# the locked claim recheck and caller must leave the terminal event untouched.
"$EXEC" claim interleaved >/dev/null
"$EXEC" running interleaved >/dev/null
"$EXEC" retry interleaved >/dev/null
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=1/' "$STATE/interleaved.exec"
printf 'exec_retry_count=0\n' >> "$STATE/interleaved.exec"
REAL_DATE=$(command -v date)
export REAL_DATE STATE TMP
mkdir -p "$TMP/datebin"
cat > "$TMP/datebin/date" <<'EOF'
#!/usr/bin/env bash
count=0
[ ! -f "$TMP/date-count" ] || count=$(cat "$TMP/date-count")
count=$((count + 1))
printf '%s\n' "$count" > "$TMP/date-count"
if [ "$count" -eq 1 ]; then
  printf 'done: PR checks green\n' >> "$STATE/interleaved.status"
fi
exec "$REAL_DATE" "$@"
EOF
chmod +x "$TMP/datebin/date"
PATH="$TMP/datebin:$PATH" retry_run_claim
assert_eq "$("$EXEC" get interleaved)" released
assert_eq "$(grep '^exec_attempt=' "$STATE/interleaved.exec" | cut -d= -f2)" 1
assert_eq "$(tail -1 "$STATE/interleaved.status")" 'done: PR checks green'

# A completed task queued for retry is released without re-engagement,
# including when retries are exhausted (which must not overwrite done with failed).
"$EXEC" claim retry-terminal-done >/dev/null
"$EXEC" running retry-terminal-done >/dev/null
"$EXEC" retry retry-terminal-done >/dev/null
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=1/' "$STATE/retry-terminal-done.exec"
printf 'exec_retry_count=3\nexec_max_retries=3\n' >> "$STATE/retry-terminal-done.exec"
printf 'done: work verified\n' >> "$STATE/retry-terminal-done.status"
retry_run_claim
assert_eq "$("$EXEC" get retry-terminal-done)" released
assert_eq "$(grep '^exec_attempt=' "$STATE/retry-terminal-done.exec" | cut -d= -f2)" 1
assert_eq "$(tail -1 "$STATE/retry-terminal-done.status")" 'done: work verified'

# A retry_queued task whose scheduled moment has arrived is claimed and
# returns to running, keeping it within supervision.
"$EXEC" claim retry-ready >/dev/null
"$EXEC" running retry-ready >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/retry-ready.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=0/' "$STATE/retry-ready.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get retry-ready)" retry_queued
# Set next_retry_at well in the past so retry_run_claim picks it up.
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=1/' "$STATE/retry-ready.exec"
retry_run_claim
assert_eq "$("$EXEC" get retry-ready)" running

# Backoff enforcement: a retry_queued task with a future next_retry_at is
# NOT claimed before its moment, and IS claimed after it.
"$EXEC" claim retry-backoff >/dev/null
"$EXEC" running retry-backoff >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/retry-backoff.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=0/' "$STATE/retry-backoff.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get retry-backoff)" retry_queued
# Set next_retry_at 60 seconds in the future.
future_ts=$(( $(date +%s) + 60 ))
sed -i "s/^exec_next_retry_at=.*/exec_next_retry_at=$future_ts/" "$STATE/retry-backoff.exec"
retry_run_claim
assert_eq "$("$EXEC" get retry-backoff)" retry_queued
# Now set next_retry_at to the past so retry_run_claim picks it up.
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=1/' "$STATE/retry-backoff.exec"
retry_run_claim
assert_eq "$("$EXEC" get retry-backoff)" running

# A retry_queued task that has exhausted retries is released by retry_run_claim.
# The stall detect always transitions to retry_queued; the claim step handles
# the limit, keeping the attempt within supervision until its moment arrives.
"$EXEC" claim retry-exhausted >/dev/null
"$EXEC" running retry-exhausted >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/retry-exhausted.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=3/' "$STATE/retry-exhausted.exec"
sed -i 's/^exec_max_retries=.*/exec_max_retries=3/' "$STATE/retry-exhausted.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get retry-exhausted)" retry_queued
# Set next_retry_at well in the past so retry_run_claim picks it up.
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=1/' "$STATE/retry-exhausted.exec"
retry_run_claim
assert_eq "$("$EXEC" get retry-exhausted)" released
assert_contains "$(cat "$STATE/retry-exhausted.exec")" 'exec_error=retry_limit_reached'
assert_contains "$(cat "$STATE/retry-exhausted.status")" 'retry limit reached'

# A retry_queued task whose moment has not arrived yet stays queued.
"$EXEC" claim retry-pending >/dev/null
"$EXEC" running retry-pending >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/retry-pending.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=0/' "$STATE/retry-pending.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get retry-pending)" retry_queued
# Set next_retry_at to far future so retry_run_claim skips it.
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=9999999999/' "$STATE/retry-pending.exec"
retry_run_claim
assert_eq "$("$EXEC" get retry-pending)" retry_queued

# A failed claim surfaces a blocked status instead of being silently swallowed.
"$EXEC" claim retry-claim-fail >/dev/null
"$EXEC" running retry-claim-fail >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/retry-claim-fail.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=0/' "$STATE/retry-claim-fail.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get retry-claim-fail)" retry_queued
# Set next_retry_at well in the past.
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=1/' "$STATE/retry-claim-fail.exec"
# Hold the lock so claim fails with a lock conflict.
mkdir "$STATE/.exec-retry-claim-fail.lock"
retry_run_claim
# The task should have a blocked status from the failed claim attempt.
assert_contains "$(cat "$STATE/retry-claim-fail.status")" 'retry claim failed'
assert_eq "$("$EXEC" get retry-claim-fail)" retry_queued
# Clean up the lock.
rmdir "$STATE/.exec-retry-claim-fail.lock"

# A successful claim does not append a spurious failure status.
"$EXEC" claim retry-claim-ok >/dev/null
"$EXEC" running retry-claim-ok >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/retry-claim-ok.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=0/' "$STATE/retry-claim-ok.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get retry-claim-ok)" retry_queued
sed -i 's/^exec_next_retry_at=.*/exec_next_retry_at=1/' "$STATE/retry-claim-ok.exec"
retry_run_claim
assert_eq "$("$EXEC" get retry-claim-ok)" running
# No failure status should be appended.
grep -q 'retry claim failed' "$STATE/retry-claim-ok.status" && exit 1

printf 'test-sq-stall-detect: ok\n'
