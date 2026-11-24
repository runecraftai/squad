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
# The operation is a drop-in for the command itself: it runs in the caller's
# working directory, with the caller's environment, with the caller's stdin, and
# its stdout and stderr are the caller's own streams. The environment is relayed
# through a 0600 file the unit reads before it execs the command, so no value is
# visible in a process command line. Nothing here copies or replays the
# operation's output.
#
# Exit status:
#   A completed operation's own status is passed through verbatim, including a
#   status that collides with one of the runner's codes below. These codes
#   describe the runner's own outcomes and are only returned when the operation
#   did not complete:
#   78     strict Linux mode was requested and can never be honoured on this host
#   124    the bound was reached and the operation's whole group was stopped
#   125    the outcome is unknown or its group was still populated (never success)
#   126    this script or the runner refused before launching the operation
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
#   - A user manager older than systemd 254 cannot disable argument expansion, so
#     `$VAR` text inside the command's own arguments is expanded by the manager
#     before the command sees it on those hosts. Newer managers get
#     --expand-environment=no.
#   - Without --state-dir the intent and outcome records live in a temporary
#     directory removed on exit, so a caller that must reconcile them later has
#     to pass a durable --state-dir.
#
# SQUAD_OP_REPORT_STATE=<file> is an internal seam for bin/sq-timeout-lib.sh:
# when set, the outcome state (completed, timeout, unknown-result,
# cleanup-pending, manager-unavailable, refused) is written to <file>, so a
# caller can tell an unestablished status apart from a status the command chose.
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
      sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
  exit 126
}
case "$bound" in
  ''|*[!0-9]*|0)
    printf 'sq-op-contain.sh: bound %q is not a positive integer\n' "$bound" >&2
    exit 126
    ;;
esac
[ "$#" -gt 0 ] || {
  printf 'sq-op-contain.sh: a command is required\n' >&2
  exit 126
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
    exit 126
  }
  trap 'rm -rf "$STATE_DIR"' EXIT
fi
case "$STATE_DIR" in
  /*) ;;
  *) STATE_DIR="$PWD/$STATE_DIR" ;;
esac

operation_id="op-$(date +%s)-$$-$(printf '%s' "$bound $*" | cksum | cut -d' ' -f1)"
outcome_record="$STATE_DIR/$operation_id.outcome.json"
# SQUAD_OP_REPORT_STATE is the seam fm_run_timed uses to tell a non-completion
# apart from a command that really chose that status. It is consumed here and
# never handed to the operation.
report_state_path=${SQUAD_OP_REPORT_STATE:-}
unset SQUAD_OP_REPORT_STATE

status=0
"$binary" run \
  --operation-id "$operation_id" \
  --state-dir "$STATE_DIR" \
  --deadline "${bound}s" \
  --stop-grace "${STOP_GRACE}s" \
  -- "$@" || status=$?

# The durable outcome record is the runner's own report of what happened. The
# operation's output is not in it and is not replayed here.
json_field() {  # <key>
  [ -s "$outcome_record" ] || return 0
  awk -v key="\"$1\":" '
    {
      at = index($0, key)
      if (at == 0) next
      value = substr($0, at + length(key))
      sub(/^[[:space:]]+/, "", value)
      sub(/,$/, "", value)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "$outcome_record"
}

report_state() {
  local state detail
  state=$(json_field state)
  detail=$(json_field detail)
  [ -n "$state" ] || state=unknown-result
  printf 'sq-op-contain.sh: operation %s%s\n' "$state" "${detail:+: $detail}" >&2
}

report_outcome_state() {  # <state>
  [ -n "$report_state_path" ] || return 0
  printf '%s\n' "$1" > "$report_state_path" 2>/dev/null || true
}

case "$status" in
  0)
    exit_code=$(json_field exit_code)
    case "$exit_code" in
      ''|*[!0-9]*)
        report_outcome_state unknown-result
        printf 'sq-op-contain.sh: the completed operation did not record its exit status\n' >&2
        exit 126
        ;;
    esac
    report_outcome_state completed
    exit "$exit_code"
    ;;
  3)
    report_outcome_state timeout
    report_state
    exit 124
    ;;
  4|5)
    report_outcome_state "$(json_field state)"
    report_state
    exit 125
    ;;
  78)
    report_outcome_state manager-unavailable
    report_state
    exit 78
    ;;
  2)
    report_outcome_state refused
    printf 'sq-op-contain.sh: the runner rejected the operation; see the message above\n' >&2
    exit 126
    ;;
  *)
    report_outcome_state unknown-result
    report_state
    exit 125
    ;;
esac
