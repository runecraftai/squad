#!/usr/bin/env bash
# tests/sq-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's silent-absence contract. While away mode is on, nothing the daemon
# handles reaches the commander's pane; it is held in the away-mode ledger and
# presented once, as one summary, by bin/sq-afk-return.sh on return.
#
#   Scenario A (silent routine and escalation): a routine wake and a
#     commander-relevant escalation each produce ZERO submitted lines in the
#     supervisor pane and exactly one ledger entry of their class. The return
#     prints one summary carrying both, and a re-run never repeats it.
#
#   Scenario B (max-defer notice): an escalation parked past SQUAD_MAX_DEFER_SECS
#     raises exactly one durable supervision escalation on the stand-to queue,
#     still with ZERO pane output, and does not repeat within the absence.
#
# Isolation: all test tmux runs on a dedicated socket (tmux -L afk-e2e-<pid>).
# A tmux shim first on PATH redirects the daemon's bare `tmux` calls to the
# private socket. The daemon points at a throwaway state dir (SQUAD_STATE_OVERRIDE)
# and the test pane (SQUAD_SUPERVISOR_TARGET). Nothing touches the live unit.
# SQUAD_SUPERVISOR_BACKEND=tmux is passed explicitly (not left to auto-detection):
# this test's own process may itself be running inside herdr (HERDR_ENV=1 is
# inherited by every process herdr manages a pane for), which would otherwise
# leak into the spawned daemon subprocess and misdetect backend=herdr against
# what is actually a tmux pane on the private socket.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/sq-supervise-daemon.sh"
RETURN="$ROOT/bin/sq-afk-return.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sq-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get SQUAD_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). Any line in the log is pane output
# the commander would have seen, so Scenario A requires the log to stay empty.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
redraw() {
  printf '\r\033[K%s' "$_buf"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1  # let the loop start and settle

# tmux shim: redirects bare `tmux` to the private socket.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sq-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake operator window (the sentry lists sq-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n sq-fake-c1 -t supervisor

start_daemon() {  # <max-defer-secs>
  PATH="$TMUX_SHIM_DIR:$PATH" \
  SQUAD_STATE_OVERRIDE="$STATE_DIR" \
  SQUAD_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  SQUAD_SUPERVISOR_BACKEND=tmux \
  SQUAD_ESCALATE_BATCH_SECS=0 \
  SQUAD_HOUSEKEEPING_TICK=1 \
  SQUAD_POLL=1 \
  SQUAD_SIGNAL_GRACE=1 \
  SQUAD_HEARTBEAT=999999 \
  SQUAD_CHECK_INTERVAL=999999 \
  SQUAD_STALE_ESCALATE_SECS=999999 \
  SQUAD_MAX_DEFER_SECS="$1" \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and sentry state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/*.meta \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.stand-to-queue* \
         "$STATE_DIR"/.sentry.lock* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.afk-return-catchup* \
         2>/dev/null || true
  # The scenarios model a live operator task: its status signals only reach the
  # sentry when the task record exists. A meta without window= adds no stale
  # supervision, so this only marks the task as live.
  printf 'id=fake-c1\n' > "$STATE_DIR/fake-c1.meta"
  : > "$LOG_FILE"
}

# wait_for_ledger <class> <count>: poll until the ledger holds <count> entries of
# that class, bounded at about 30 seconds.
wait_for_ledger() {
  local i=0 n
  while [ "$i" -lt 150 ]; do
    n=$(cat "$STATE_DIR/.subsuper-escalations" "$STATE_DIR/.subsuper-routine" 2>/dev/null | grep -c "|$1|" || true)
    [ "${n:-0}" -ge "$2" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# --- Scenario A: silent routine wake and escalation, one summary on return ---

test_scenario_a() {
  local out count
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon 300

  echo "working: step one" > "$STATE_DIR/fake-c1.status"
  wait_for_ledger routine 1 || fail "Scenario A: routine wake was not ledgered"

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  wait_for_ledger escalation 1 || fail "Scenario A: escalation was not ledgered"
  sleep 3  # let housekeeping and any late wake land before judging silence

  [ ! -s "$LOG_FILE" ] \
    || fail "Scenario A: away mode wrote to the supervisor pane: $(cat "$LOG_FILE")"

  count=$(grep -c '|routine|' "$STATE_DIR/.subsuper-routine")
  [ "$count" -eq 1 ] || fail "Scenario A: expected exactly one routine entry, got $count"
  count=$(grep -c '|escalation|' "$STATE_DIR/.subsuper-escalations")
  [ "$count" -eq 1 ] || fail "Scenario A: expected exactly one escalation entry, got $count"

  stop_daemon
  afk_exit "$STATE_DIR"

  out=$(PATH="$TMUX_SHIM_DIR:$PATH" SQUAD_BASE="$STATE_DIR" SQUAD_STATE_OVERRIDE="$STATE_DIR" \
    "$RETURN" 2>&1) || fail "Scenario A: return catch-up failed: $out"
  count=$(printf '%s\n' "$out" | grep -c 'catch-up summary' || true)
  [ "$count" -eq 1 ] || fail "Scenario A: return printed the summary $count times: $out"
  printf '%s\n' "$out" | grep -F 'counts: escalation=1 routine=1' >/dev/null \
    || fail "Scenario A: summary did not count one escalation and one routine: $out"
  printf '%s\n' "$out" | grep -F 'https://example.test/pr/300' >/dev/null \
    || fail "Scenario A: summary did not carry the PR link: $out"
  printf '%s\n' "$out" | grep -F 'fake-c1.status' >/dev/null \
    || fail "Scenario A: summary did not list the routine wake in order: $out"

  out=$(PATH="$TMUX_SHIM_DIR:$PATH" SQUAD_BASE="$STATE_DIR" SQUAD_STATE_OVERRIDE="$STATE_DIR" \
    "$RETURN" 2>&1) || fail "Scenario A: re-run of the catch-up failed: $out"
  count=$(printf '%s\n' "$out" | grep -c 'catch-up summary' || true)
  [ "$count" -eq 0 ] || fail "Scenario A: re-run duplicated the summary: $out"

  [ ! -s "$LOG_FILE" ] || fail "Scenario A: return or re-run wrote to the supervisor pane"
  pass "Scenario A: a routine wake and an escalation are silent in the pane, one ledger entry each, and the return presents one summary that a re-run never repeats"
}

# --- Scenario B: max-defer notice is durable and silent ----------------------

test_scenario_b() {
  local count i=0
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon 2

  echo "done: PR https://example.test/pr/301" > "$STATE_DIR/fake-c1.status"
  wait_for_ledger escalation 1 || fail "Scenario B: escalation was not ledgered"

  while [ "$i" -lt 150 ]; do
    grep -q 'afk-parked-escalations' "$STATE_DIR/.stand-to-queue" 2>/dev/null && break
    sleep 0.2
    i=$((i + 1))
  done
  grep -q 'afk-parked-escalations' "$STATE_DIR/.stand-to-queue" 2>/dev/null \
    || fail "Scenario B: parked escalation did not reach the durable stand-to queue"
  [ -e "$STATE_DIR/.subsuper-inject-wedged" ] \
    || fail "Scenario B: max-defer notice left no marker"
  grep -F $'\tcheck\tafk-parked-escalations\t' "$STATE_DIR/.stand-to-queue" >/dev/null \
    || fail "Scenario B: the durable record is not a check escalation"

  sleep 3  # the notice must not repeat within the same absence
  count=$(grep -c 'afk-parked-escalations' "$STATE_DIR/.stand-to-queue" || true)
  [ "$count" -eq 1 ] || fail "Scenario B: max-defer notice repeated ($count records)"

  [ ! -s "$LOG_FILE" ] \
    || fail "Scenario B: max-defer path wrote to the supervisor pane: $(cat "$LOG_FILE")"

  stop_daemon
  pass "Scenario B: a parked escalation raises one durable stand-to escalation with zero pane output"
}

test_scenario_a
test_scenario_b

echo "all afk silent-absence e2e tests passed"
