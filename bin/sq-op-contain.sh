#!/usr/bin/env bash
# sq-op-contain.sh - the single owner of containment-backed bounded execution.
#
# Usage:
#   sq-op-contain.sh [--state-dir <dir>] [--stop-grace <seconds>] \
#                    <bound-seconds> <command> [args...]
#
# Runs one external operation inside its own systemd user transient service and
# reports whether it stayed contained. This is what closes the shell containment
# gap: a descendant that changes session or process group stays in the unit's
# cgroup, and the unit's own kill mode takes it, so a TERM-resistant helper
# cannot outlive the bound. Shell process-group kills cannot do that, which is
# why this path is systemd-owned rather than reimplemented in shell.
#
# Exit status preserves bin/sq-timeout-lib.sh's contract so callers do not have
# to change:
#   0-122  the command's own status
#   124    the bound was reached and the operation's whole group was stopped
#   125    the outcome is unknown or its group was still populated (never success)
#   78     strict Linux mode was requested and can never be honoured on this host
#
# Honest limits, by design rather than omission:
#   - Containment covers local descendants that stay in the cgroup. It is not a
#     sandbox against a same-user process that moves itself out, a privileged
#     process, or an already-running shared backend server.
#   - Killing a client cannot undo a request a backend or remote host already
#     accepted. Those need exact-target reconciliation, not a retry.
#   - An unavailable user manager, uninterruptible kernel I/O, or a dead storage
#     device cannot yield a wall-clock guarantee. Strict mode refuses instead of
#     pretending otherwise.
#
# The binary is resolved from SQUAD_SUPERVISOR_BIN, then PATH, then a repo-local
# build under .git. A missing binary under strict mode is a refusal, never a
# silent fall back to a weaker guarantee.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

STATE_DIR=
STOP_GRACE=2
bound=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-dir) STATE_DIR=${2:?--state-dir requires a value}; shift 2 ;;
    --stop-grace) STOP_GRACE=${2:?--stop-grace requires a value}; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --) shift; break ;;
    *)
      if [ -z "$bound" ]; then
        bound=$1
        shift
        continue
      fi
      break
      ;;
  esac
done

[ -n "$bound" ] || {
  printf 'sq-op-contain.sh: a positive bound in seconds is required\n' >&2
  exit 2
}
case "$bound" in
  ''|*[!0-9]*|0)
    printf 'sq-op-contain.sh: bound %q is not a positive integer\n' "$bound" >&2
    exit 2
    ;;
esac
[ "$#" -gt 0 ] || {
  printf 'sq-op-contain.sh: a command is required\n' >&2
  exit 2
}

resolve_binary() {
  if [ -n "${SQUAD_SUPERVISOR_BIN:-}" ]; then
    [ -x "$SQUAD_SUPERVISOR_BIN" ] || return 1
    printf '%s\n' "$SQUAD_SUPERVISOR_BIN"
    return 0
  fi
  if command -v sq-supervisor >/dev/null 2>&1; then
    command -v sq-supervisor
    return 0
  fi
  local local_build="$SQUAD_ROOT/.git/sq-supervisor/sq-supervisor"
  if [ -x "$local_build" ]; then
    printf '%s\n' "$local_build"
    return 0
  fi
  return 1
}

binary=$(resolve_binary) || {
  printf 'sq-op-contain.sh: strict Linux mode needs the sq-supervisor binary; run bin/sq-install-supervisor.sh <dir> or set SQUAD_SUPERVISOR_BIN\n' >&2
  exit 78
}

if [ -z "$STATE_DIR" ]; then
  STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sq-op-containment.XXXXXX") || {
    printf 'sq-op-contain.sh: cannot create an operation record directory\n' >&2
    exit 125
  }
  trap 'rm -rf "$STATE_DIR"' EXIT
fi
case "$STATE_DIR" in
  /*) ;;
  *) STATE_DIR="$PWD/$STATE_DIR" ;;
esac

operation_id="op-$(date +%s)-$$-$(printf '%s' "$bound $*" | cksum | cut -d' ' -f1)"
outcome=$(mktemp "${TMPDIR:-/tmp}/sq-op-outcome.XXXXXX") || exit 125
stdout_path="$STATE_DIR/$operation_id.stdout"
stderr_path="$STATE_DIR/$operation_id.stderr"
diagnostic_path="$STATE_DIR/$operation_id.diagnostic"

status=0
"$binary" run \
  --operation-id "$operation_id" \
  --state-dir "$STATE_DIR" \
  --deadline "${bound}s" \
  --stop-grace "${STOP_GRACE}s" \
  --stdout "$stdout_path" \
  --stderr "$stderr_path" \
  -- "$@" > "$outcome" 2>"$diagnostic_path" || status=$?

report_state() {
  # One line, only when the caller must not treat this as success.
  awk '
    { line = line $0 }
    END {
      state = "unknown-result"
      if (match(line, /"state":"[^"]*"/)) {
        state = substr(line, RSTART + 9, RLENGTH - 10)
      }
      detail = ""
      if (match(line, /"detail":"[^"]*"/)) {
        detail = substr(line, RSTART + 10, RLENGTH - 11)
      }
      printf "sq-op-contain.sh: operation %s%s\n", state, (detail == "" ? "" : ": " detail)
    }
  ' "$outcome" >&2
  if [ -s "$diagnostic_path" ]; then
    sed 's/^/sq-op-contain.sh: /' "$diagnostic_path" >&2
  fi
}

# Relay the operation's own streams. This is what keeps fm_run_timed's contract
# intact when it delegates here: callers capture stdout with $(...), and a unit
# writes to its own file rather than inheriting the caller's pipe. That also
# removes the inherited-descriptor leak, because a descendant holding the
# operation's output open can no longer hold the caller open.
relay_streams() {
  [ ! -s "$stdout_path" ] || cat "$stdout_path"
  [ ! -s "$stderr_path" ] || cat "$stderr_path" >&2
}

relay_streams

case "$status" in
  0)
    exit_code=$(awk '{ line = line $0 } END { if (match(line, /"exit_code":[0-9]+/)) print substr(line, RSTART + 12, RLENGTH - 12) }' "$outcome")
    rm -f "$outcome"
    exit "${exit_code:-0}"
    ;;
  3)
    report_state
    rm -f "$outcome"
    exit 124
    ;;
  4|5)
    report_state
    rm -f "$outcome"
    exit 125
    ;;
  78)
    report_state
    rm -f "$outcome"
    exit 78
    ;;
  2)
    printf 'sq-op-contain.sh: usage error\n' >&2
    rm -f "$outcome"
    exit 2
    ;;
  *)
    report_state
    rm -f "$outcome"
    exit 125
    ;;
esac
