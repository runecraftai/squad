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
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound. GNU/BSD `timeout` does
# this by default because it does not run the command in the foreground process
# group; the perl fallback does it explicitly with setpgrp plus a negative pid,
# and the bash fallback uses monitor mode to give the bounded child its own
# process group before signaling its negative pid.
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

fm_timeout_signal_backends() {
  local signal=$1 registry=$2 entry
  [ -n "$registry" ] || return 0
  for entry in "$registry"/[1-9]*; do
    case "${entry##*/}" in *[!0-9]*) continue ;; esac
    [ -f "$entry" ] || continue
    kill -s "$signal" -- "-${entry##*/}" 2>/dev/null || true
  done
}

fm_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  local registry=''
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/sq-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  if [ "${fm_timeout_clean_group:-0}" = 1 ]; then
    registry="${command_status}.backends"
    if ! mkdir -m 700 -- "$registry"; then
      rm -f -- "$command_status"
      return 124
    fi
    deadline_status="$registry.expired"
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    export SQ_TIMEOUT_BACKEND_REGISTRY="$registry"
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
    if [ "${fm_timeout_clean_group:-0}" = 1 ]; then
      fm_timeout_signal_backends TERM "$registry"
      sleep 0.5
    else
      sleep 0.2
    fi
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    fm_timeout_signal_backends KILL "$registry"
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
  if [ -n "$registry" ]; then
    : > "$deadline_status"
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    fm_timeout_signal_backends KILL "$registry"
    rm -rf -- "$registry"
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_timed_in_group() {
  perl -MErrno=ESRCH -MFile::Temp=tempfile -MFile::Copy=copy \
    -MPOSIX=setsid,WNOHANG -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC,sleep -e '
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + shift;
    my $registry = $ENV{SQ_TIMEOUT_BACKEND_REGISTRY} // "";
    my $cancelled = 0;
    local $SIG{TERM} = sub { $cancelled = 1 };
    my ($out, $out_path) = tempfile(UNLINK => 1);
    my ($err, $err_path) = tempfile(UNLINK => 1);
    unlink($out_path, $err_path) == 2 or exit 125;
    exit 124 if $cancelled;
    my $pid = fork;
    exit 125 unless defined $pid;
    if (!$pid) {
      defined(setsid()) or POSIX::_exit(125);
      $SIG{TERM} = "DEFAULT";
      open(STDOUT, ">&", $out) && open(STDERR, ">&", $err) or POSIX::_exit(125);
      if (length $registry) {
        open(my $entry, ">", "$registry/$$") or POSIX::_exit(125);
        close($entry) or POSIX::_exit(125);
        POSIX::_exit(124) if -e "$registry.expired" || !-d $registry;
      }
      exec @ARGV or POSIX::_exit(125);
    }
    my $status;
    while (!$cancelled && clock_gettime(CLOCK_MONOTONIC) < $deadline) {
      $status = $? if !defined($status) && waitpid($pid, WNOHANG) == $pid;
      if (defined($status) && !kill(0, $pid) && $! == ESRCH && !kill(0, -$pid) && $! == ESRCH) {
        unlink "$registry/$pid" if length $registry;
        exit 124 if $cancelled;
        seek($out, 0, 0) && seek($err, 0, 0) or exit 125;
        copy($out, \*STDOUT) && copy($err, \*STDERR) or exit 125;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
      }
      sleep 0.02;
    }
    kill "TERM", -$pid;
    kill "TERM", $pid unless defined $status;
    my $grace = clock_gettime(CLOCK_MONOTONIC) + 0.2;
    while ((my $remaining = $grace - clock_gettime(CLOCK_MONOTONIC)) > 0) {
      sleep $remaining;
    }
    kill "KILL", -$pid;
    kill "KILL", $pid unless defined $status;
    kill "KILL", -$pid unless defined $status;
    waitpid($pid, WNOHANG) unless defined $status;
    exit 124;
  ' "$@" </dev/null
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

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
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
