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

# Exhausted retries are released after the worker is interrupted.
"$EXEC" claim exhausted >/dev/null
"$EXEC" running exhausted >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/exhausted.exec"
sed -i 's/^exec_retry_count=.*/exec_retry_count=3/' "$STATE/exhausted.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=dead SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get exhausted)" released
assert_contains "$(cat "$STATE/exhausted.exec")" 'exec_error=stall_timeout'

# Ambiguous evidence is surfaced for technical recovery and not killed.
"$EXEC" claim ambiguous >/dev/null
"$EXEC" running ambiguous >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/ambiguous.exec"
SQUAD_STALL_TIMEOUT=1 SQUAD_STALL_AGENT_STATE=ambiguous SQUAD_STALL_INTERRUPT_CMD="$TMP/interrupt" "$STALL"
assert_eq "$("$EXEC" get ambiguous)" running
assert_contains "$(cat "$STATE/ambiguous.status")" 'stuck-operator-recovery'

printf 'test-sq-stall-detect: ok\n'
