#!/usr/bin/env bash
# sq-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set SQUAD_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound and relays its stdout and stderr. Exit
#       status is the command's own, or 124: 124 means the bound was hit
#       (GNU timeout's convention, reproduced by the perl and bash fallbacks) and
#       is also returned when the contained path cannot establish the command's
#       own status at all. The concrete reason is printed on stderr, so 124 is
#       never a silent answer.
#
#   fm_containment_mode
#       Prints the containment mechanism this host will use: "systemd" when
#       SQUAD_OP_CONTAINMENT=systemd, otherwise "legacy".
#
#   fm_run_contained <seconds> <command> [args...]
#       Runs the command with the same bound and streams as fm_run_timed, inside
#       its own systemd user transient service (bin/sq-op-contain.sh), so
#       descendants that change session or process group stay in one kernel-owned
#       cgroup. This is the richer contract: besides the command's own status and
#       124, it returns 125 for an unknown outcome or a group that stayed
#       populated, 126 when the runner refused before launching, and 78 when
#       strict mode cannot be honoured on this host. fm_run_timed collapses each
#       of those to 124 rather than exposing them to its callers.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# The legacy mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound on those paths. GNU/BSD
# `timeout` does this by default because it does not run the command in the
# foreground process group; the perl fallback does it explicitly with setpgrp
# plus a negative pid, and the bash fallback uses monitor mode to give the
# bounded child its own process group before signaling its negative pid.
#
# That group is not a containment domain: a descendant that starts a second group
# inside the session, or its own session, escapes a negative-pid kill entirely.
# Closing that gap needs a kernel-owned membership domain, which is what
# fm_run_contained provides. Squad's containment-backed path is opt-in per
# SQUAD_OP_CONTAINMENT=systemd until the away-mode migration proves it on a base;
# until then the legacy group kill is what runs, and its limit is real.
set -u

fm_timeout_mechanism() {
  if [ "${SQUAD_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

fm_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/sq-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/sq-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  if "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137) return 124 ;;
    *) return "$runner_rc" ;;
  esac
}

fm_containment_mode() {
  if [ "${SQUAD_OP_CONTAINMENT:-}" = systemd ]; then
    printf 'systemd\n'
  else
    printf 'legacy\n'
  fi
}

fm_op_contain() {
  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$script_dir/sq-op-contain.sh" --stop-grace "${SQUAD_OP_STOP_GRACE:-2}" "$@"
}

fm_run_contained() {  # <seconds> <command...>
  local seconds=$1 rc previous
  shift
  [ "$seconds" -gt 0 ] 2>/dev/null || return 124
  previous=${SQUAD_OP_CONTAINMENT_ACTIVE:-}
  SQUAD_OP_CONTAINMENT_ACTIVE=1
  export SQUAD_OP_CONTAINMENT_ACTIVE
  fm_op_contain "$seconds" "$@"
  rc=$?
  if [ -n "$previous" ]; then
    SQUAD_OP_CONTAINMENT_ACTIVE=$previous
  else
    unset SQUAD_OP_CONTAINMENT_ACTIVE
  fi
  return "$rc"
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1 rc state_file state
  shift
  if [ "${SQUAD_OP_CONTAINMENT_ACTIVE:-}" != 1 ] && [ "$(fm_containment_mode)" = systemd ]; then
    # fm_run_timed promises only the command's own status or 124. A completed or
    # timed-out operation had a status of its own; every other outcome means the
    # contained path could not establish one, which callers already treat as a
    # bound. The reported state says which, so a command that really exited 125
    # is not mistaken for an unestablished result.
    state_file=$(mktemp "${TMPDIR:-/tmp}/sq-op-state.XXXXXX" 2>/dev/null) || state_file=
    if [ -n "$state_file" ]; then
      SQUAD_OP_REPORT_STATE=$state_file fm_run_contained "$seconds" "$@"
      rc=$?
      state=$(cat "$state_file" 2>/dev/null || true)
      rm -f "$state_file" 2>/dev/null || true
      case "$state" in
        completed|timeout) return "$rc" ;;
        *) return 124 ;;
      esac
    fi
    fm_run_contained "$seconds" "$@"
    rc=$?
    case "$rc" in
      78|125|126) return 124 ;;
      *) return "$rc" ;;
    esac
  fi
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl)
      perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
        "$seconds" "$@"
      ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}
