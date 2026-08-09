#!/usr/bin/env bash
# sq-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <XO-id>
#
# It runs bin/sq-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/sq-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# SQUAD_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
SQUAD_REMOTE_READINESS_OUT=

fm_remote_readiness_ensure() { # <bin-dir> <XO-id>
  local bin_dir=$1 id=$2 out rc

  out=$("$bin_dir/sq-on.sh" "$id" sq-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  SQUAD_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/sq-on.sh" "$id" sq-remote-doctor.sh --fix < /dev/null 2>&1)
  rc=$?
  SQUAD_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/sq-on.sh" "$id" sq-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  SQUAD_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
